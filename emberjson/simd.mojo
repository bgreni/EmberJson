"""Target-facing SIMD constants and primitives.

Two different widths matter here and confusing them is the bug this
module exists to prevent:

  * `SIMD8_WIDTH` is the *vector register* width. Correct for loads and
    compares, which every target can do at its register width.
  * `KERNEL_WIDTH` is the width the byte-table-lookup kernels run at.
    Table lookups are governed by the width at which the target has a
    byte-shuffle instruction, which is a different quantity: AVX-512
    without VBMI has 64-byte registers but only a 32-byte VPSHUFB, and
    baseline SSE2 has no byte shuffle at all.
"""

from std.sys import simd_width_of
from std.sys.info import CompilationTarget


comptime SIMD8_WIDTH = simd_width_of[Byte.dtype]()
comptime SIMD8[l: SIMDLength] = SIMD[Byte.dtype, l]
comptime SIMD8xT = SIMD8[SIMD8_WIDTH]
comptime SIMDBool[l: SIMDLength] = SIMD[DType.bool, l]


# Whether the byte-table shuffle path is taken.
#
# Deliberately narrower than "does this target have a byte shuffle".
# SSSE3-only x86 has PSHUFB and measures well (classifier: 82
# instructions vs 200 for the portable path), but no SSSE3-only machine
# is available to benchmark, so it takes the portable path until one is.
# Enabling it later is a one-token change: swap `has_avx2()` for
# `_has_feature["ssse3"]()`.
#
# AVX-512 parts are not specialized for. They have AVX2, so they run the
# identical width-32 path, measured at 14-16 instructions for the
# classifier against 312-379 for the code this replaces.
comptime HAS_BYTE_SHUFFLE = (
    CompilationTarget.has_neon() or CompilationTarget.has_avx2()
)

# The width the shuffle kernels run at, capped at 32 because that is the
# widest configuration available to benchmark (Ryzen 7 3700X, Zen 2).
#
# The cap is free for the classifier: with the recursive `lookup` below,
# width 32 is within one instruction of width 64 on every AVX-512 target
# measured (15 vs 16 on skylake-avx512, 14 vs 14 on znver4). It does
# forgo a real gain for `is_valid_utf8`, which is not pinned to a 64-byte
# chunk and would process 64 bytes per iteration for the same ~174
# instructions. Raise the cap once an AVX-512 machine is available to
# benchmark -- and test both an AVX-512BW part without VBMI
# (Skylake-SP, Cascade Lake; VPSHUFB ymm) and a VBMI part (Ice Lake,
# Zen 4/5; VPERMB), because they lower differently.
comptime KERNEL_WIDTH = 32 if SIMD8_WIDTH > 32 else SIMD8_WIDTH


@always_inline("nodebug")
def lookup[W: Int](table: SIMD8[16], idx: SIMD8[W]) -> SIMD8[W]:
    """16-entry byte-table lookup at width W.

    Every `idx` lane must be < 16; lanes >= 16 are unspecified, not
    masked. Callers mask with `& 0xF` or shift with `>> 4`.

    Written as a recursion that halves to 16-lane shuffles rather than
    one W-wide shuffle over a tiled table. That is load-bearing, not
    style: LLVM widens a computation to match whatever consumes its
    result, and a stage-1 kernel that packs two 32-lane halves into one
    64-bit mask forces 64 lanes. A 64-lane shuffle over a 32-entry table
    has no legal form, so the naive spelling scalarizes into a
    byte-by-byte gather (225 instructions, on VBMI targets too). Halved
    to 16, LLVM recognises the tiled table and emits one VPSHUFB per
    128-bit lane whatever the surrounding width becomes.

    Not comptime-interpretable: callers keep their
    `__is_run_in_comptime_interpreter` guards.
    """
    comptime assert HAS_BYTE_SHUFFLE, (
        "no byte-shuffle path on this target; guard the call site with"
        " `comptime if HAS_BYTE_SHUFFLE` and provide a portable path"
    )
    comptime assert (
        W >= 16 and W % 16 == 0
    ), "lookup width must be 16 or a multiple of it"
    comptime if W == 16:
        return rebind[SIMD8[W]](table._dynamic_shuffle(rebind[SIMD8[16]](idx)))
    comptime H = W // 2
    return rebind[SIMD8[W]](
        lookup[H](table, idx.slice[H, offset=0]()).join(
            lookup[H](table, idx.slice[H, offset=H]())
        )
    )
