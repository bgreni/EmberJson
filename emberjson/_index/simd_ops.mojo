"""Stage-1 SIMD primitives: building blocks for the indexer.

Ported from simdjson's stage 1 (Langdale &
Lemire, arXiv:1902.08318). Two layers:

  * A portable layer with no `llvm_intrinsic` calls that lowers to decent
    NEON/AVX and, critically, interprets cleanly in Mojo's comptime
    interpreter (`comptime x = try_parse(...)` is a supported emberjson
    feature).
  * A NEON fast layer (`has_neon()` targets) guarded by
    `__is_run_in_comptime_interpreter`: the interpreter only ever
    evaluates the taken (portable) branch, so intrinsics and comptime
    parsing coexist. PMULL replaces the six-step shift-XOR scan and an
    ADDP reduction tree replaces `pack_bits` for movemasks (simdjson's
    aarch64 kernel formulations).

  * `SimdInput` wraps the 64-byte logical chunk, abstracting the hardware
    SIMD width, and exposes `load`, `eq`, and `lteq` that produce 64-bit
    per-byte masks.
  * `prefix_xor` is the inclusive XOR-scan of a 64-bit mask, used to
    propagate in-string state across a quote mask.
"""

from std.memory import pack_bits
from std.memory.unsafe import bitcast
from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic
from .portable import prefix_xor_portable

comptime _NEON = CompilationTarget.has_neon()

comptime _Chunk16 = SIMD[DType.uint8, 16]
comptime _Bool16 = SIMD[DType.bool, 16]


@always_inline("nodebug")
def prefix_xor(bitmask: UInt64) -> UInt64:
    """Computes the prefix XOR (inclusive XOR-scan) of a 64-bit mask.

    out[i] = bitmask[0] ^ ... ^ bitmask[i]; each 1-bit flips the polarity
    of all subsequent bits, which propagates in-string state across a
    64-bit quote mask. NEON: one PMULL against all-ones (carryless
    multiply spreads the XOR prefix — simdjson's PCLMULQDQ trick).
    Portable/comptime: six shift-XOR steps (Hillis-Steele); bit-identical.
    """
    comptime if _NEON:
        if not __is_run_in_comptime_interpreter:
            var prod = llvm_intrinsic["llvm.aarch64.neon.pmull64", _Chunk16](
                bitmask, UInt64.MAX
            )
            return bitcast[DType.uint64, 2](prod)[0]
    return prefix_xor_portable(bitmask)


@always_inline("nodebug")
def _addp(a: _Chunk16, b: _Chunk16) -> _Chunk16:
    return llvm_intrinsic["llvm.aarch64.neon.addp.v16i8", _Chunk16](a, b)


@always_inline("nodebug")
def movemask64(a: _Bool16, b: _Bool16, c: _Bool16, d: _Bool16) -> UInt64:
    """Packs four 16-lane bool vectors into one 64-bit mask (bit i = lane i).

    NEON path: per-lane bit weights + a three-level ADDP pairwise-add tree
    (simdjson's `neon::to_bitmask`) — much cheaper than `pack_bits`'s
    horizontal reduction on aarch64. Portable/comptime path: `pack_bits`.
    """
    comptime if _NEON:
        if not __is_run_in_comptime_interpreter:
            comptime BITS = _Chunk16(
                1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128
            )
            comptime ZERO = _Chunk16(0)
            var s0 = _addp(a.select(BITS, ZERO), b.select(BITS, ZERO))
            var s1 = _addp(c.select(BITS, ZERO), d.select(BITS, ZERO))
            var s2 = _addp(s0, s1)
            var s3 = _addp(s2, s2)
            return bitcast[DType.uint64, 2](s3)[0]
    var m0 = UInt64(pack_bits(a))
    var m1 = UInt64(pack_bits(b))
    var m2 = UInt64(pack_bits(c))
    var m3 = UInt64(pack_bits(d))
    return m0 | m1 << 16 | m2 << 32 | m3 << 48


@fieldwise_init
struct SimdInput(Copyable, Movable):
    """64 bytes loaded into four 16-byte registers, abstracting SIMD width."""

    var chunks: InlineArray[_Chunk16, 4]

    @always_inline("nodebug")
    @staticmethod
    def load(ptr: UnsafePointer[UInt8, _]) -> SimdInput:
        """Loads 64 bytes from ptr (unaligned)."""
        var result = SimdInput(
            chunks=InlineArray[_Chunk16, 4](fill=_Chunk16(0))
        )
        result.chunks[0] = ptr.load[width=16]()
        result.chunks[1] = (ptr + 16).load[width=16]()
        result.chunks[2] = (ptr + 32).load[width=16]()
        result.chunks[3] = (ptr + 48).load[width=16]()
        return result^

    @always_inline("nodebug")
    def eq(self, target: UInt8) -> UInt64:
        """Returns a 64-bit mask: bit i set if byte i == target."""
        var splat = _Chunk16(target)
        return movemask64(
            self.chunks[0].eq(splat),
            self.chunks[1].eq(splat),
            self.chunks[2].eq(splat),
            self.chunks[3].eq(splat),
        )

    @always_inline("nodebug")
    def lteq(self, target: UInt8) -> UInt64:
        """Returns a 64-bit mask: bit i set if byte i <= target (unsigned)."""
        var splat = _Chunk16(target)
        return movemask64(
            self.chunks[0].le(splat),
            self.chunks[1].le(splat),
            self.chunks[2].le(splat),
            self.chunks[3].le(splat),
        )
