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
  * An x86 fast layer (`has_avx2()` targets, which implies SSSE3) with
    the same guard: PCLMULQDQ replaces the shift-XOR scan (simdjson's
    westmere/haswell formulation) and the 64-byte chunk ops recombine
    the four 16-byte registers into two 32-byte vectors so compares and
    movemasks run at AVX2 width (VPCMPEQB + VPMOVMSKB, simdjson's
    haswell kernel shape).

  Each layer is gated on the target feature its instructions actually
  require, which is not always the arch-family flag — see `_PMULL` and
  `_PCLMUL` below.

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
# Every AVX2 CPU (Haswell+/Zen+) also has SSSE3 PSHUFB, so this flag
# gates the shuffle and movemask fast paths.
comptime _AVX2 = CompilationTarget.has_avx2()

# The carryless-multiply intrinsics need their own gates: PMULL64 lives
# in the aarch64 crypto extension (+aes), not baseline NEON, and
# PCLMULQDQ needs +pclmul, not merely +avx2. Every CPU we care about
# ships both, but instruction selection consults the *target feature
# set*, not the silicon: a build for a generic CPU — which is what
# conda/rattler packaging does so one artifact runs on any machine of
# the arch — gets +neon without +aes, and emitting PMULL there is a hard
# "Cannot select" backend crash rather than a slow path. Falling back to
# the portable scan keeps such builds working (and it is bit-identical).
# The arch conjunction is load-bearing: `aes` is also a valid x86
# feature name (AES-NI), so the feature query alone would not keep the
# aarch64 intrinsic off an x86 target.
comptime _PMULL = _NEON and CompilationTarget._has_feature["aes"]()
comptime _PCLMUL = _AVX2 and CompilationTarget._has_feature["pclmul"]()

comptime _Chunk16 = SIMD[DType.uint8, 16]
comptime _Bool16 = SIMD[DType.bool, 16]
comptime _Chunk32 = SIMD[DType.uint8, 32]


@always_inline("nodebug")
def lookup16(table: _Chunk16, idx: _Chunk16) -> _Chunk16:
    """16-entry byte shuffle-table lookup; every idx lane must be < 16.

    `_dynamic_shuffle` lowers to one TBL1 on NEON and one PSHUFB on x86
    (verified against the raw intrinsics), and carries its own fallback
    on targets with neither, so this is safe to call at runtime on any
    target. Not comptime-interpretable — callers keep their
    `__is_run_in_comptime_interpreter` guards.
    """
    return table._dynamic_shuffle(idx)


@always_inline("nodebug")
def lookup16_x2(table: _Chunk16, idx: _Chunk32) -> _Chunk32:
    """`lookup16` at 32-byte width. Duplicating the 16-entry table into
    both halves makes the full 32-entry lookup per-128-bit-lane safe, so
    on AVX2 this compiles to a single VPSHUFB YMM (verified)."""
    return table.join(table)._dynamic_shuffle(idx)


@always_inline("nodebug")
def prefix_xor(bitmask: UInt64) -> UInt64:
    """Computes the prefix XOR (inclusive XOR-scan) of a 64-bit mask.

    out[i] = bitmask[0] ^ ... ^ bitmask[i]; each 1-bit flips the polarity
    of all subsequent bits, which propagates in-string state across a
    64-bit quote mask. NEON: one PMULL against all-ones (carryless
    multiply spreads the XOR prefix — simdjson's PCLMULQDQ trick).
    Portable/comptime: six shift-XOR steps (Hillis-Steele); bit-identical.

    Verified from --emit=asm that both intrinsics earn their keep: the
    shift-XOR chain is 17 dependent insns on x86 (no shifted-operand ALU)
    vs 5 for PCLMULQDQ, and 7 vs 5 on aarch64. Both are gated on the
    exact target feature they need (`_PMULL`/`_PCLMUL`, see above) rather
    than on the arch family, so a generic-CPU build degrades to the
    portable scan instead of failing instruction selection.
    """
    comptime if _PMULL:
        if not __is_run_in_comptime_interpreter:
            var prod = llvm_intrinsic["llvm.aarch64.neon.pmull64", _Chunk16](
                bitmask, UInt64.MAX
            )
            return bitcast[DType.uint64, 2](prod)[0]
    comptime if _PCLMUL:
        if not __is_run_in_comptime_interpreter:
            # PCLMULQDQ against all-ones: the carryless product's low half
            # is exactly the inclusive XOR-scan (simdjson's x86 kernels).
            var prod = llvm_intrinsic[
                "llvm.x86.pclmulqdq", SIMD[DType.uint64, 2]
            ](
                SIMD[DType.uint64, 2](bitmask, 0),
                SIMD[DType.uint64, 2](UInt64.MAX, 0),
                Int8(0),
            )
            return prod[0]
    return prefix_xor_portable(bitmask)


@always_inline("nodebug")
def _addp(a: _Chunk16, b: _Chunk16) -> _Chunk16:
    return llvm_intrinsic["llvm.aarch64.neon.addp.v16i8", _Chunk16](a, b)


@always_inline("nodebug")
def movemask64(a: _Bool16, b: _Bool16, c: _Bool16, d: _Bool16) -> UInt64:
    """Packs four 16-lane bool vectors into one 64-bit mask (bit i = lane i).

    NEON path: per-lane bit weights + a three-level ADDP pairwise-add tree
    (simdjson's `neon::to_bitmask`) — much cheaper than `pack_bits`'s
    horizontal reduction on aarch64 (verified from --emit=asm: 19 insns
    for the whole compare+mask kernel vs 34 via pack_bits).
    Portable/comptime path: `pack_bits` (on x86 it lowers to PMOVMSKB
    and needs no help).
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
    def load(ptr: Pointer[UInt8, _]) -> SimdInput:
        """Loads 64 bytes from ptr (unaligned)."""
        var result = SimdInput(
            chunks=InlineArray[_Chunk16, 4](fill=_Chunk16(0))
        )
        result.chunks[0] = ptr.unsafe_load[width=16]()
        result.chunks[1] = (ptr.unsafe_offset(16)).unsafe_load[width=16]()
        result.chunks[2] = (ptr.unsafe_offset(32)).unsafe_load[width=16]()
        result.chunks[3] = (ptr.unsafe_offset(48)).unsafe_load[width=16]()
        return result^

    @always_inline("nodebug")
    def lo32(self) -> _Chunk32:
        """Bytes 0-31 as one 32-byte vector (x86: a VINSERTI128 the
        backend usually folds into a single 32-byte load)."""
        return self.chunks[0].join(self.chunks[1])

    @always_inline("nodebug")
    def hi32(self) -> _Chunk32:
        """Bytes 32-63 as one 32-byte vector."""
        return self.chunks[2].join(self.chunks[3])

    @always_inline("nodebug")
    def eq(self, target: UInt8) -> UInt64:
        """Returns a 64-bit mask: bit i set if byte i == target.

        The AVX2 recombine is not redundant: LLVM does not auto-fuse
        four 16-byte compare+pack_bits into ymm ops (verified from
        --emit=asm: 15 insns stay xmm-width vs 9 via explicit 32-byte
        vectors)."""
        comptime if _AVX2:
            if not __is_run_in_comptime_interpreter:
                var splat = _Chunk32(target)
                var m0 = UInt64(pack_bits(self.lo32().eq(splat)))
                var m1 = UInt64(pack_bits(self.hi32().eq(splat)))
                return m0 | m1 << 32
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
        comptime if _AVX2:
            if not __is_run_in_comptime_interpreter:
                var splat = _Chunk32(target)
                var m0 = UInt64(pack_bits(self.lo32().le(splat)))
                var m1 = UInt64(pack_bits(self.hi32().le(splat)))
                return m0 | m1 << 32
        var splat = _Chunk16(target)
        return movemask64(
            self.chunks[0].le(splat),
            self.chunks[1].le(splat),
            self.chunks[2].le(splat),
            self.chunks[3].le(splat),
        )
