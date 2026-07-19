"""GPU UTF-8 validation kernel (RFC 3629, Keiser-Lemire).

The same three-nibble-table + continuation-pairing algorithm as
`emberjson/_utf8.mojo`'s NEON path, reformulated for Metal-safe codegen:

  * table lookups via a comptime-unrolled per-lane extract
    (`_dynamic_shuffle` crashes the Metal shader compiler, like
    `pack_bits`);
  * saturating subtract as `max(a, b) - b`;
  * `prev1/2/3` byte shifts via `join`/`slice` (static shuffles, safe).

Parallel structure: one thread per 64-byte chunk, four 16-byte blocks
each. The CPU's cross-block `prev_chunk`/`prev_incomplete` carries
disappear: a thread loads its predecessor block directly (overlap read;
chunk 0 seeds zeros, matching the CPU's initial state). The caller
guarantees zero padding after the input and launches one extra
all-padding chunk so a sequence dangling at the true end of input fails
its continuation checks exactly as the CPU's staged-zero tail / post-loop
check does. Any thread observing an error bumps a global flag
(`Atomic.fetch_add`; contention only exists for invalid inputs).

Only the comptime lookup tables are imported from `_utf8.mojo`; no
NEON-guarded function from there is ever elaborated into the kernel.
"""

from emberjson._utf8 import _BYTE_1_HIGH, _BYTE_1_LOW, _BYTE_2_HIGH, _MAX_VALUE
from std.atomic import Atomic
from std.math import ceildiv
from std.memory import UnsafePointer
from std.sys import has_accelerator
from std.gpu import global_idx
from std.gpu.host import DeviceContext, DeviceBuffer

comptime _C16 = SIMD[DType.uint8, 16]
comptime _BLOCK = 256


@always_inline
def _satsub(a: _C16, b: _C16) -> _C16:
    """Per-byte saturating subtract without `llvm.usub.sat` (portable)."""
    return max(a, b) - b


@always_inline
def _tbl(table: _C16, idx: _C16) -> _C16:
    """16-entry table lookup; Metal-safe per-lane extract formulation."""
    var r = _C16(0)
    comptime for i in range(16):
        r[i] = table[Int(idx[i])]
    return r


@always_inline
def _prev_shift[n: Int](prev_chunk: _C16, cur: _C16) -> _C16:
    """The block shifted back by `n` bytes, pulling from `prev_chunk`."""
    return prev_chunk.join(cur).slice[16, offset=16 - n]()


@always_inline
def _check_block(cur: _C16, prev_chunk: _C16, mut error: _C16):
    """One 16-byte Keiser-Lemire step (see `_utf8._check_chunk`)."""
    var prev1 = _prev_shift[1](prev_chunk, cur)
    var sc = (
        _tbl(_BYTE_1_HIGH, prev1 >> 4)
        & _tbl(_BYTE_1_LOW, prev1 & 0xF)
        & _tbl(_BYTE_2_HIGH, cur >> 4)
    )
    var prev2 = _prev_shift[2](prev_chunk, cur)
    var prev3 = _prev_shift[3](prev_chunk, cur)
    # High bit set exactly for 3-byte (>= 0xE0) / 4-byte (>= 0xF0) leads.
    var must23 = _satsub(prev2, _C16(0xE0 - 0x80)) | _satsub(
        prev3, _C16(0xF0 - 0x80)
    )
    var must23_80 = must23 & 0x80
    error |= must23_80 ^ sc


def _utf8_kernel(
    inp: UnsafePointer[UInt8, MutAnyOrigin],
    err_flag: UnsafePointer[Int32, MutAnyOrigin],
    num_chunks: Int,
):
    var c = global_idx.x
    if c >= num_chunks:
        return
    var base = inp + c * 64

    var prev: _C16
    if c == 0:
        prev = _C16(0)
    else:
        prev = (base - 16).load[width=16]()

    var error = _C16(0)
    comptime for r in range(4):
        var cur = (base + r * 16).load[width=16]()
        if (cur & 0x80).reduce_max() == 0:
            # All-ASCII block: only a dangling lead in prev can be wrong.
            error |= _satsub(prev, _MAX_VALUE)
        else:
            _check_block(cur, prev, error)
        prev = cur

    if error.reduce_max() != 0:
        _ = Atomic.fetch_add(err_flag, 1)


@always_inline
def utf8_chunk_count(n: Int) -> Int:
    """Chunks to launch for `n` input bytes: every 64-byte chunk plus one
    all-padding chunk, so a lead dangling at an exact chunk-boundary end
    of input is still checked. The device buffer must hold (and zero)
    `utf8_chunk_count(n) * 64` bytes."""
    return ceildiv(n, 64) + 1


def run_utf8_validation(
    ctx: DeviceContext,
    mut input_dev: DeviceBuffer[DType.uint8],
    mut err_flag: DeviceBuffer[DType.int32],
    num_chunks: Int,
) raises:
    """Enqueues the validation kernel (no synchronize; the caller syncs).

    Contract: `input_dev` holds the input bytes followed by zeros through
    `num_chunks * 64` bytes, and `err_flag` has been zeroed this batch.
    """
    comptime if has_accelerator():
        ctx.enqueue_function[_utf8_kernel](
            input_dev.unsafe_ptr(),
            err_flag.unsafe_ptr(),
            num_chunks,
            grid_dim=ceildiv(num_chunks, _BLOCK),
            block_dim=_BLOCK,
        )
