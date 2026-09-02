"""Bulk UTF-8 validation (RFC 3629).

Two layers, following the pattern of `_index/simd_ops.mojo`:

  * A scalar range-check validator that interprets cleanly at compile
    time and doubles as the differential-test reference.
  * A SIMD lookup path, taken at runtime only on targets that have a
    byte-shuffle instruction (`HAS_BYTE_SHUFFLE`), implementing the
    Keiser-Lemire algorithm ("Validating UTF-8 In Less Than One
    Instruction Per Byte", the simdjson `utf8_validation` kernel): three
    nibble-table lookups on a byte and its predecessor (TBL1 on NEON,
    PSHUFB/VPSHUFB on x86, via `simd.lookup`) classify every illegal
    sequence class (overlongs, surrogates, out-of-range, wrong
    continuation counts), with a saturating-subtract check pairing
    3/4-byte leads with their required continuations. Guarded by
    `__is_run_in_comptime_interpreter` so comptime evaluation takes the
    scalar path.
  * A no-shuffle path for every other target (baseline SSE2, generic
    builds). A shuffle emulated on such a target is not slow, it is a
    byte-by-byte gather -- ~695 instructions per chunk -- so the lookup
    kernel is never instantiated there. Instead the ASCII prefix is
    vector-scanned (compare + movemask, which baseline SSE2 has) and the
    remainder handed to the scalar validator, so a pure-ASCII document
    never touches a scalar loop.

The kernel is width-generic: it runs at `KERNEL_WIDTH`, the width at
which the target actually has a byte shuffle, which is not the same
quantity as the register width (see `emberjson/simd.mojo`).

The `error` accumulator is only reduced at the end: the whole input is
processed branch-free except for an all-ASCII fast path per chunk (where
only a dangling-lead check from the previous chunk is needed).
"""

from emberjson.simd import (
    HAS_BYTE_SHUFFLE,
    KERNEL_WIDTH,
    lookup,
    SIMD8,
    SIMD8_WIDTH,
)
from std.memory import unsafe_memcpy
from std.collections import Array
from std.sys.intrinsics import llvm_intrinsic

comptime _C16 = SIMD[DType.uint8, 16]

comptime TOO_SHORT: UInt8 = 1 << 0
comptime TOO_LONG: UInt8 = 1 << 1
comptime OVERLONG_3: UInt8 = 1 << 2
comptime TOO_LARGE: UInt8 = 1 << 3
comptime SURROGATE: UInt8 = 1 << 4
comptime OVERLONG_2: UInt8 = 1 << 5
comptime TOO_LARGE_1000: UInt8 = 1 << 6
comptime OVERLONG_4: UInt8 = 1 << 6
comptime TWO_CONTS: UInt8 = 1 << 7
comptime CARRY: UInt8 = TOO_SHORT | TOO_LONG | TWO_CONTS

# fmt: off
comptime _BYTE_1_HIGH = _C16(
    TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG,
    TOO_LONG, TOO_LONG, TOO_LONG, TOO_LONG,
    TWO_CONTS, TWO_CONTS, TWO_CONTS, TWO_CONTS,
    TOO_SHORT | OVERLONG_2,
    TOO_SHORT,
    TOO_SHORT | OVERLONG_3 | SURROGATE,
    TOO_SHORT | TOO_LARGE | TOO_LARGE_1000 | OVERLONG_4,
)
comptime _BYTE_1_LOW = _C16(
    CARRY | OVERLONG_3 | OVERLONG_2 | OVERLONG_4,
    CARRY | OVERLONG_2,
    CARRY, CARRY,
    CARRY | TOO_LARGE,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000 | SURROGATE,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
    CARRY | TOO_LARGE | TOO_LARGE_1000,
)
comptime _BYTE_2_HIGH = _C16(
    TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
    TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE_1000 | OVERLONG_4,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | OVERLONG_3 | TOO_LARGE,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE | TOO_LARGE,
    TOO_LONG | OVERLONG_2 | TWO_CONTS | SURROGATE | TOO_LARGE,
    TOO_SHORT, TOO_SHORT, TOO_SHORT, TOO_SHORT,
)
# fmt: on


@always_inline
def _make_max_value[W: Int]() -> SIMD8[W]:
    """255 everywhere except the last three lanes, which encode 'a lead
    byte here has no room for its continuations': a 4-byte lead can
    dangle in the last 3, a 3-byte lead in the last 2, any lead in the
    last 1.

    Built by per-lane assignment: `SIMD.insert` lowers to
    llvm.vector.insert, which the comptime interpreter cannot fold.
    """
    var out = SIMD8[W](255)
    out[W - 3] = 0xF0 - 1
    out[W - 2] = 0xE0 - 1
    out[W - 1] = 0xC0 - 1
    return out


@always_inline("nodebug")
def _satsub[W: Int](a: SIMD8[W], b: SIMD8[W]) -> SIMD8[W]:
    """Saturating unsigned subtract: `a - b`, clamped at zero.

    Do NOT "simplify" this to the arithmetic spelling
    `a - a.lt(b).select(a, b)`. That form looks equivalent and even
    *measures* equivalent statically -- both compile to a byte-identical
    151-instruction kernel with 5 `uqsub` on aarch64 -- but in situ it
    times at roughly half the throughput (9.5 GB/s against 18.7 GB/s on
    twitter.json, M3 Pro). Instruction counting is blind to this; only
    timing catches it. The intrinsic is the shipped form.

    The intrinsic name is built from `W`, so this stays width-generic:
    UQSUB on aarch64, PSUBUSB / VPSUBUSB on x86, at every width.

    Not comptime-interpretable, and that costs nothing: `_satsub` is
    reachable only from `_check_chunk` and `_is_valid_utf8_simd`, both of
    which sit behind `if not __is_run_in_comptime_interpreter`. Compile-
    time evaluation takes `_is_valid_utf8_scalar` and never reaches here.
    """
    return llvm_intrinsic["llvm.usub.sat.v" + String(W) + "i8", SIMD8[W]](a, b)


@always_inline("nodebug")
def _prev[n: Int, W: Int](prev_chunk: SIMD8[W], cur: SIMD8[W]) -> SIMD8[W]:
    """The chunk shifted back by `n` bytes, pulling from `prev_chunk`
    (NEON EXT / x86 palignr shape)."""
    return prev_chunk.join(cur).slice[W, offset=W - n]()


@always_inline("nodebug")
def _check_chunk[
    W: Int
](cur: SIMD8[W], prev_chunk: SIMD8[W], mut error: SIMD8[W]):
    var prev1 = _prev[1, W](prev_chunk, cur)
    var sc = (
        lookup[W](_BYTE_1_HIGH, prev1 >> 4)
        & lookup[W](_BYTE_1_LOW, prev1 & SIMD8[W](0xF))
        & lookup[W](_BYTE_2_HIGH, cur >> 4)
    )
    var prev2 = _prev[2, W](prev_chunk, cur)
    var prev3 = _prev[3, W](prev_chunk, cur)
    # High bit set exactly for 3-byte (>= 0xE0) / 4-byte (>= 0xF0) leads.
    var must23 = _satsub[W](prev2, SIMD8[W](0xE0 - 0x80)) | _satsub[W](
        prev3, SIMD8[W](0xF0 - 0x80)
    )
    error |= (must23 & SIMD8[W](0x80)) ^ sc


@always_inline("nodebug")
def _all_ascii[W: Int](cur: SIMD8[W]) -> Bool:
    """Whether no byte has its high bit set.

    `reduce_or` is the one formulation LLVM lowers optimally on both
    targets (verified from --emit=asm): PMOVMSKB + test on x86, and the
    same CMLT+ADDP sequence on aarch64 that `reduce_max` or a pack_bits
    sign-mask would produce (a naive horizontal max on x86 is a 20-insn
    shuffle tree, so don't switch this back to `reduce_max`)."""
    return (cur & SIMD8[W](0x80)).reduce_or() == 0


def _is_valid_utf8_simd[W: Int](ptr: Pointer[UInt8, _], n: Int) -> Bool:
    comptime MAX_VALUE = _make_max_value[W]()
    var error = SIMD8[W](0)
    var prev_chunk = SIMD8[W](0)
    var prev_incomplete = SIMD8[W](0)

    var i = 0
    while i + W <= n:
        var cur = (ptr.unsafe_offset(i)).unsafe_load[width=W]()
        if _all_ascii[W](cur):
            # All-ASCII chunk: only a dangling multi-byte sequence from
            # the previous chunk can be wrong.
            error |= prev_incomplete
        else:
            _check_chunk[W](cur, prev_chunk, error)
        prev_incomplete = _satsub[W](cur, MAX_VALUE)
        prev_chunk = cur
        i += W

    if i < n:
        # Final partial chunk, staged through a zeroed buffer: the NUL
        # padding is ASCII, so any sequence left dangling at the true end
        # of input fails its continuation checks here.
        var tail = Array[Byte, W](fill=0)
        unsafe_memcpy(
            dest=tail.unsafe_ptr(), src=ptr.unsafe_offset(i), count=n - i
        )
        var cur = tail.unsafe_ptr().unsafe_load[width=W]()
        _check_chunk[W](cur, prev_chunk, error)
    else:
        # Input ended exactly on a chunk boundary: a trailing lead byte
        # has no continuation to fail against, so check it directly.
        error |= prev_incomplete

    return error.reduce_max() == 0


def _first_non_ascii[W: Int](ptr: Pointer[UInt8, _], n: Int) -> Int:
    """Index of the first byte >= 0x80, or `n` if there is none.

    The vector scan needs no byte shuffle -- `reduce_or` lowers to
    PMOVMSKB, which baseline SSE2 has -- so this stays fast on targets
    that have no table lookup.
    """
    var i = 0
    while i + W <= n:
        var cur = (ptr.unsafe_offset(i)).unsafe_load[width=W]()
        if not _all_ascii[W](cur):
            for k in range(i, i + W):
                if ptr[unsafe_offset=k] >= 0x80:
                    return k
        i += W
    while i < n:
        if ptr[unsafe_offset=i] >= 0x80:
            return i
        i += 1
    return n


def _is_valid_utf8_no_shuffle(ptr: Pointer[UInt8, _], n: Int) -> Bool:
    """Validator for targets with no byte-shuffle instruction.

    Vector-scans the ASCII prefix and hands the rest to the scalar
    range-checker. A pure-ASCII document never reaches the scalar path,
    and the handoff point is always a valid resync point because every
    byte before it is ASCII.
    """
    var k = _first_non_ascii[SIMD8_WIDTH](ptr, n)
    if k == n:
        return True
    return _is_valid_utf8_scalar(ptr.unsafe_offset(k), n - k)


def _is_valid_utf8_scalar(ptr: Pointer[UInt8, _], n: Int) -> Bool:
    """Reference validator: explicit RFC 3629 range checks."""
    var i = 0
    while i < n:
        var b = ptr[unsafe_offset=i]
        if b < 0x80:
            i += 1
            continue
        var need: Int
        var lo: Byte = 0x80
        var hi: Byte = 0xBF
        if b >= 0xC2 and b <= 0xDF:
            need = 1
        elif b == 0xE0:
            need = 2
            lo = 0xA0
        elif b >= 0xE1 and b <= 0xEC:
            need = 2
        elif b == 0xED:
            need = 2
            hi = 0x9F  # excludes surrogates
        elif b >= 0xEE and b <= 0xEF:
            need = 2
        elif b == 0xF0:
            need = 3
            lo = 0x90
        elif b >= 0xF1 and b <= 0xF3:
            need = 3
        elif b == 0xF4:
            need = 3
            hi = 0x8F  # excludes > U+10FFFF
        else:
            # 0x80-0xC1: bare continuation or overlong lead; 0xF5-0xFF.
            return False
        if i + need >= n:
            return False
        var c1 = ptr[unsafe_offset=i + 1]
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = ptr[unsafe_offset=i + k]
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def is_valid_utf8(s: Span[Byte, _]) -> Bool:
    """Whether `s` is valid UTF-8 (RFC 3629: no overlongs, no surrogates,
    nothing above U+10FFFF, no truncated sequences)."""
    if not __is_run_in_comptime_interpreter:
        comptime if HAS_BYTE_SHUFFLE:
            return _is_valid_utf8_simd[KERNEL_WIDTH](s.unsafe_ptr(), len(s))
        else:
            return _is_valid_utf8_no_shuffle(s.unsafe_ptr(), len(s))
    return _is_valid_utf8_scalar(s.unsafe_ptr(), len(s))


@always_inline
def is_valid_utf8(s: StringSlice) -> Bool:
    return is_valid_utf8(s.as_bytes())
