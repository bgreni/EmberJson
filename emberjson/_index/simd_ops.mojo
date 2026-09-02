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
    westmere/haswell formulation).

  Each layer is gated on the target feature its instructions actually
  require, which is not always the arch-family flag — see `_PMULL` and
  `_PCLMUL` below.

  * `SimdInput` holds the 64-byte logical chunk as `_N_CHUNKS` vectors of
    `KERNEL_WIDTH` bytes -- four 16-byte registers on NEON, two 32-byte
    ones on AVX2 -- and exposes `load`, `eq`, and `lteq` that produce
    64-bit per-byte masks. Compares and movemasks therefore run at the
    target's kernel width with no hand-written recombine (on x86,
    VPCMPEQB + VPMOVMSKB, simdjson's haswell kernel shape).
  * `prefix_xor` is the inclusive XOR-scan of a 64-bit mask, used to
    propagate in-string state across a quote mask.
"""

from std.memory import pack_bits
from std.memory.unsafe import bitcast
from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic
from emberjson.simd import HAS_BYTE_SHUFFLE, KERNEL_WIDTH
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

# The stage-1 kernel width. 16 on NEON, 32 on AVX2; a 64-byte logical
# chunk is _N_CHUNKS of these regardless.
comptime _CW = KERNEL_WIDTH
comptime _N_CHUNKS = 64 // _CW
comptime _Chunk = SIMD[DType.uint8, _CW]
comptime _BoolC = SIMD[DType.bool, _CW]


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
def movemask64(m: Array[_BoolC, _N_CHUNKS]) -> UInt64:
    """Packs the chunk's lane predicates into one 64-bit mask (bit i = byte i).

    NEON path: per-lane bit weights + a three-level ADDP pairwise-add tree
    (simdjson's `neon::to_bitmask`) -- much cheaper than `pack_bits`'s
    horizontal reduction on aarch64 (verified from --emit=asm: 19 insns
    for the whole compare+mask kernel vs 34 via pack_bits).
    Portable/comptime path: `pack_bits` (on x86 it lowers to PMOVMSKB
    and needs no help).
    """
    comptime if _NEON:
        if not __is_run_in_comptime_interpreter:
            # The ADDP tree is structurally four 16-byte vectors. That
            # holds because SIMD8_WIDTH is 16 on every NEON target
            # measured (apple-m1, apple-m3, generic aarch64) -- an
            # observation, not a guarantee. An SVE target reporting wider
            # must fail the build here rather than silently run a
            # 16-byte reduction over vectors that are not 16 bytes.
            comptime assert _N_CHUNKS == 4, (
                "NEON movemask assumes four 16-byte chunks; this target"
                " reports a different KERNEL_WIDTH"
            )
            comptime BITS = _Chunk16(
                1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128
            )
            comptime ZERO = _Chunk16(0)
            var a = rebind[_Bool16](m[0])
            var b = rebind[_Bool16](m[1])
            var c = rebind[_Bool16](m[2])
            var d = rebind[_Bool16](m[3])
            var s0 = _addp(a.select(BITS, ZERO), b.select(BITS, ZERO))
            var s1 = _addp(c.select(BITS, ZERO), d.select(BITS, ZERO))
            var s2 = _addp(s0, s1)
            var s3 = _addp(s2, s2)
            return bitcast[DType.uint64, 2](s3)[0]
    var out: UInt64 = 0
    comptime for i in range(_N_CHUNKS):
        out |= UInt64(pack_bits(m[i])) << UInt64(i * _CW)
    return out


@fieldwise_init
struct SimdInput(Copyable, Movable):
    """64 bytes held as `_N_CHUNKS` vectors, abstracting SIMD width."""

    var chunks: Array[_Chunk, _N_CHUNKS]

    @always_inline("nodebug")
    @staticmethod
    def load(ptr: Pointer[UInt8, _]) -> SimdInput:
        """Loads 64 bytes from ptr (unaligned)."""
        var result = SimdInput(chunks=Array[_Chunk, _N_CHUNKS](fill=_Chunk(0)))
        comptime for i in range(_N_CHUNKS):
            result.chunks[i] = (ptr.unsafe_offset(i * _CW)).unsafe_load[
                width=_CW
            ]()
        return result^

    @always_inline("nodebug")
    def eq(self, target: UInt8) -> UInt64:
        """Returns a 64-bit mask: bit i set if byte i == target."""
        var splat = _Chunk(target)
        var m = Array[_BoolC, _N_CHUNKS](fill=_BoolC(fill=False))
        comptime for i in range(_N_CHUNKS):
            m[i] = self.chunks[i].eq(splat)
        return movemask64(m)

    @always_inline("nodebug")
    def lteq(self, target: UInt8) -> UInt64:
        """Returns a 64-bit mask: bit i set if byte i <= target (unsigned)."""
        var splat = _Chunk(target)
        var m = Array[_BoolC, _N_CHUNKS](fill=_BoolC(fill=False))
        comptime for i in range(_N_CHUNKS):
            m[i] = self.chunks[i].le(splat)
        return movemask64(m)
