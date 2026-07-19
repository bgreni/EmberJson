"""Cross-vendor GPU capability probe.

Launches one tiny kernel per construct, catching pipeline-creation
failures, and prints a SUPPORTED / BROKEN / UNSUPPORTED matrix:

  SUPPORTED    compiles, runs, produces correct results
  BROKEN       compiles and runs but produces WRONG results (silent
               miscompile — the dangerous class)
  UNSUPPORTED  the backend rejects it (raises at launch)

This matrix decides the comptime fast-path dispatch in `emberjson/_gpu`
(see NVIDIA_GPU_PLAN.md). Known result on Apple/Metal (M3 Pro):
pack_bits, dynamic_shuffle, UInt128, and comptime StackArray tables are
UNSUPPORTED; misaligned typed loads/stores and multi-exit runtime loops
are BROKEN; everything else SUPPORTED. On NVIDIA everything is expected
SUPPORTED — verify, don't assume.

Note: UNSUPPORTED probes on Metal each take several seconds (the
runtime retries pipeline creation before giving up). Run time ~1 min.

Usage: pixi run mojo tools/gpu_probe.mojo
"""

from emberjson._deserialize.tables import POWER_OF_FIVE_128, full_multiplication
from emberjson.utils import StackArray, lut
from std.memory import UnsafePointer, alloc, pack_bits, stack_allocation
from std.sys import has_accelerator
from std.atomic import Atomic
from std.gpu import barrier, global_idx, thread_idx
from std.gpu.host import DeviceBuffer, DeviceContext
from std.gpu.memory import AddressSpace

comptime _C16 = SIMD[DType.uint8, 16]
comptime _TBL = _C16(3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3)
comptime _SA_TABLE: StackArray[UInt64, 8] = [11, 22, 33, 44, 55, 66, 77, 88]


def k_basic(outp: UnsafePointer[UInt64, MutAnyOrigin]):
    var t = global_idx.x
    if t < 32:
        outp[t] = UInt64(t) * 3 + 1


def k_pack_bits(
    inp: UnsafePointer[UInt8, MutAnyOrigin],
    outp: UnsafePointer[UInt64, MutAnyOrigin],
):
    var t = global_idx.x
    if t < 32:
        var v = (inp + t * 16).load[width=16]()
        outp[t] = UInt64(pack_bits(v.eq(_C16(0x22))))


def k_dyn_shuffle(
    inp: UnsafePointer[UInt8, MutAnyOrigin],
    outp: UnsafePointer[UInt64, MutAnyOrigin],
):
    var t = global_idx.x
    if t < 32:
        var v = (inp + t * 16).load[width=16]()
        var looked = _TBL._dynamic_shuffle(v & 0xF)
        var s: UInt64 = 0
        comptime for i in range(16):
            s += UInt64(looked[i])
        outp[t] = s


def k_u128(
    inp: UnsafePointer[UInt64, MutAnyOrigin],
    outp: UnsafePointer[UInt64, MutAnyOrigin],
):
    var t = global_idx.x
    if t < 32:
        var p = full_multiplication(inp[t], inp[t] ^ 0x9E3779B97F4A7C15)
        outp[t] = UInt64(p >> 64) ^ UInt64(p)


def k_misaligned_load(
    inp: UnsafePointer[UInt8, MutAnyOrigin],
    outp: UnsafePointer[UInt64, MutAnyOrigin],
):
    """u64 typed load at byte offset 6 — BROKEN backends round the
    address down instead of faulting or handling it."""
    var t = global_idx.x
    if t == 0:
        outp[0] = (inp + 6).bitcast[UInt64]().load()


def k_misaligned_store(
    outp8: UnsafePointer[UInt8, MutAnyOrigin],
):
    """u32 typed store at byte offset 6."""
    var t = global_idx.x
    if t == 0:
        (outp8 + 6).bitcast[UInt32]().store(UInt32(0xAABBCCDD))


def k_stack_array_table(
    inp: UnsafePointer[UInt64, MutAnyOrigin],
    outp: UnsafePointer[UInt64, MutAnyOrigin],
):
    """comptime StackArray global referenced from a kernel — fails to
    link on Metal ("Undefined symbols: global_constant")."""
    var t = global_idx.x
    if t < 8:
        outp[t] = lut[_SA_TABLE](Int(inp[t] % 8))


@always_inline
def _multi_exit_pass(
    src: UnsafePointer[UInt8, MutAnyOrigin], n: Int
) -> Tuple[Int, Bool]:
    """The control-flow shape that miscompiles on Metal: early return +
    continue inside a runtime-bounded loop, inlined more than once."""
    var i = 0
    var w = 0
    while i < n:
        var c = src[i]
        if c < 0x20:
            return (0, False)
        if c != UInt8(0x5C):
            w += 1
            i += 1
            continue
        w += 2
        i += 2
    return (w, True)


def k_multi_exit(
    inp: UnsafePointer[UInt8, MutAnyOrigin],
    lens: UnsafePointer[UInt64, MutAnyOrigin],
    outp: UnsafePointer[UInt64, MutAnyOrigin],
):
    """Two inlined instances with runtime args — on Metal, one instance
    silently corrupts (which one varies with surrounding code)."""
    var t = global_idx.x
    if t != 0:
        return
    var n1 = Int(lens[0])
    var r1 = _multi_exit_pass(inp + Int(lens[1]), n1)
    outp[0] = UInt64(r1[0])
    outp[1] = UInt64(1) if r1[1] else UInt64(0)
    var sp = inp + Int(lens[1])
    var nn = n1
    var r2 = _multi_exit_pass(sp, nn)
    outp[2] = UInt64(r2[0])
    outp[3] = UInt64(1) if r2[1] else UInt64(0)


def k_shared_atomics(
    inp: UnsafePointer[UInt32, MutAnyOrigin],
    outp: UnsafePointer[UInt32, MutAnyOrigin],
):
    var tid = thread_idx.x
    var shared = stack_allocation[
        64, UInt32, address_space=AddressSpace.SHARED
    ]()
    if tid < 64:
        shared[tid] = 0
    barrier()
    _ = Atomic.fetch_add(
        shared.address_space_cast[AddressSpace.SHARED]() + Int(inp[tid] % 64),
        UInt32(1),
    )
    barrier()
    if tid < 64:
        outp[tid] = shared[tid]


def _verdict(name: String, ok: Bool, correct: Bool):
    if not ok:
        print("  ", name, ": UNSUPPORTED (backend rejected)")
    elif not correct:
        print("  ", name, ": BROKEN (silent wrong results)")
    else:
        print("  ", name, ": SUPPORTED")


def main() raises:
    comptime if not has_accelerator():
        print("no accelerator on this machine")
    else:
        var ctx = DeviceContext()
        print("GPU capability matrix")
        print("=====================")

        var out64 = ctx.enqueue_create_buffer[DType.uint64](64)
        var in8 = ctx.enqueue_create_buffer[DType.uint8](1024)
        var in64 = ctx.enqueue_create_buffer[DType.uint64](64)
        var in32 = ctx.enqueue_create_buffer[DType.uint32](64)
        var out32 = ctx.enqueue_create_buffer[DType.uint32](64)
        with in8.map_to_host() as h:
            for i in range(1024):
                h[i] = UInt8(0x22) if i % 5 == 0 else UInt8(0x61)
        with in64.map_to_host() as h:
            for i in range(64):
                h[i] = UInt64(i) * 0x9E3779B97F4A7C15 + 1
        with in32.map_to_host() as h:
            for i in range(64):
                h[i] = UInt32(i)

        # basic
        var ok = True
        var correct = True
        try:
            ctx.enqueue_function[k_basic](
                out64.unsafe_ptr(), grid_dim=1, block_dim=32
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                correct = h[5] == UInt64(16)
        except:
            ok = False
        _verdict("basic kernel        ", ok, correct)

        # pack_bits
        ok = True
        correct = True
        try:
            ctx.enqueue_function[k_pack_bits](
                in8.unsafe_ptr(), out64.unsafe_ptr(), grid_dim=1, block_dim=32
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                var expect: UInt64 = 0
                for j in range(16):
                    if j % 5 == 0:
                        expect |= UInt64(1) << UInt64(j)
                correct = h[0] == expect
        except:
            ok = False
        _verdict("pack_bits (movemask)", ok, correct)

        # dynamic_shuffle
        ok = True
        correct = True
        try:
            ctx.enqueue_function[k_dyn_shuffle](
                in8.unsafe_ptr(), out64.unsafe_ptr(), grid_dim=1, block_dim=32
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                var expect: UInt64 = 0
                with in8.map_to_host() as hi:
                    for j in range(16):
                        expect += UInt64(_TBL[Int(hi[j] & 0xF)])
                correct = h[0] == expect
        except:
            ok = False
        _verdict("dynamic_shuffle     ", ok, correct)

        # u128
        ok = True
        correct = True
        try:
            ctx.enqueue_function[k_u128](
                in64.unsafe_ptr(),
                out64.unsafe_ptr(),
                grid_dim=1,
                block_dim=32,
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                with in64.map_to_host() as hi:
                    var x = hi[3]
                    var p = full_multiplication(x, x ^ 0x9E3779B97F4A7C15)
                    correct = h[3] == (UInt64(p >> 64) ^ UInt64(p))
        except:
            ok = False
        _verdict("UInt128 multiply    ", ok, correct)

        # misaligned load
        ok = True
        correct = True
        try:
            ctx.enqueue_function[k_misaligned_load](
                in8.unsafe_ptr(), out64.unsafe_ptr(), grid_dim=1, block_dim=32
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                var expect: UInt64 = 0
                with in8.map_to_host() as hi:
                    for k in range(8):
                        expect |= UInt64(hi[6 + k]) << UInt64(8 * k)
                correct = h[0] == expect
        except:
            ok = False
        _verdict("misaligned u64 load ", ok, correct)

        # misaligned store
        ok = True
        correct = True
        try:
            in8.enqueue_fill(0)
            ctx.enqueue_function[k_misaligned_store](
                in8.unsafe_ptr(), grid_dim=1, block_dim=32
            )
            ctx.synchronize()
            with in8.map_to_host() as h:
                correct = (
                    h[6] == 0xDD
                    and h[7] == 0xCC
                    and h[8] == 0xBB
                    and h[9] == 0xAA
                    and h[4] == 0
                    and h[5] == 0
                )
                # restore probe data
                for i in range(1024):
                    h[i] = UInt8(0x22) if i % 5 == 0 else UInt8(0x61)
        except:
            ok = False
        _verdict("misaligned u32 store", ok, correct)

        # comptime StackArray table
        ok = True
        correct = True
        try:
            ctx.enqueue_function[k_stack_array_table](
                in64.unsafe_ptr(),
                out64.unsafe_ptr(),
                grid_dim=1,
                block_dim=32,
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                with in64.map_to_host() as hi:
                    correct = h[2] == lut[_SA_TABLE](Int(hi[2] % 8))
        except:
            ok = False
        _verdict("comptime table link ", ok, correct)

        # multi-exit loop shape
        ok = True
        correct = True
        try:
            with in64.map_to_host() as h:
                h[0] = 3  # n
                h[1] = 1  # offset
            ctx.enqueue_function[k_multi_exit](
                in8.unsafe_ptr(),
                in64.unsafe_ptr(),
                out64.unsafe_ptr(),
                grid_dim=1,
                block_dim=32,
            )
            ctx.synchronize()
            with out64.map_to_host() as h:
                correct = h[0] == 3 and h[1] == 1 and h[2] == 3 and h[3] == 1
        except:
            ok = False
        _verdict("multi-exit rt loop  ", ok, correct)

        # shared-memory atomics
        ok = True
        correct = True
        try:
            ctx.enqueue_function[k_shared_atomics](
                in32.unsafe_ptr(),
                out32.unsafe_ptr(),
                grid_dim=1,
                block_dim=64,
            )
            ctx.synchronize()
            with out32.map_to_host() as h:
                correct = h[0] == 1 and h[63] == 1
        except:
            ok = False
        _verdict("shared-mem atomics  ", ok, correct)

        # host-pointer wrap (zero-copy aliasing)
        ok = True
        correct = True
        try:
            var host_mem = alloc[Scalar[DType.uint64]](64, alignment=16384)
            for i in range(64):
                host_mem[i] = 0xDEAD
            var wrapped = DeviceBuffer[DType.uint64](
                ctx, host_mem, 64, owning=False
            )
            ctx.enqueue_function[k_basic](
                wrapped.unsafe_ptr(), grid_dim=1, block_dim=32
            )
            ctx.synchronize()
            correct = host_mem[5] == UInt64(16)
            host_mem.free()
        except:
            ok = False
        _verdict("host-ptr zero-copy  ", ok, correct)

        print()
        print("Interpretation: see NVIDIA_GPU_PLAN.md — SUPPORTED unlocks")
        print("the corresponding fast path; BROKEN/UNSUPPORTED keeps the")
        print("portable form for this target.")
