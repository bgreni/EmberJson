"""Bulk UTF-8 validation (RFC 3629).

Two layers, following the pattern of `_index/simd_ops.mojo`:

  * A scalar range-check validator that interprets cleanly at compile
    time and doubles as the differential-test reference.
  * A SIMD path, taken at runtime on every target, implementing the
    Keiser-Lemire lookup algorithm ("Validating UTF-8 In Less Than One
    Instruction Per Byte", the simdjson `utf8_validation` kernel): three
    nibble-table lookups on a byte and its predecessor (TBL1 on NEON,
    PSHUFB on x86, via `simd_ops.lookup16`) classify every illegal
    sequence class (overlongs, surrogates, out-of-range, wrong
    continuation counts), with a saturating-subtract check pairing
    3/4-byte leads with their required continuations. Guarded by
    `__is_run_in_comptime_interpreter` so comptime evaluation takes the
    scalar path.

The `error` accumulator is only reduced at the end: the whole input is
processed branch-free except for an all-ASCII fast path per 16-byte
chunk (where only a dangling-lead check from the previous chunk is
needed).
"""

from emberjson._index.simd_ops import lookup16
from std.memory import memcpy, UnsafePointer
from std.sys.intrinsics import llvm_intrinsic
from std.collections import InlineArray

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
# A byte is an "incomplete" sequence starter if a required continuation
# would fall past the end of the chunk: only the last three lanes can
# dangle (4-byte lead in the last 3, 3-byte lead in the last 2, any lead
# in the last 1).
comptime _MAX_VALUE = _C16(
    255, 255, 255, 255, 255, 255, 255, 255,
    255, 255, 255, 255, 255,
    0xF0 - 1, 0xE0 - 1, 0xC0 - 1,
)
# fmt: on


@always_inline("nodebug")
def _satsub(a: _C16, b: _C16) -> _C16:
    return llvm_intrinsic["llvm.usub.sat.v16i8", _C16](a, b)


@always_inline("nodebug")
def _prev[n: Int](prev_chunk: _C16, cur: _C16) -> _C16:
    """The chunk shifted back by `n` bytes, pulling from `prev_chunk`
    (NEON EXT / x86 palignr shape)."""
    return prev_chunk.join(cur).slice[16, offset=16 - n]()


@always_inline("nodebug")
def _check_chunk(cur: _C16, prev_chunk: _C16, mut error: _C16):
    var prev1 = _prev[1](prev_chunk, cur)
    var sc = (
        lookup16(_BYTE_1_HIGH, prev1 >> 4)
        & lookup16(_BYTE_1_LOW, prev1 & 0xF)
        & lookup16(_BYTE_2_HIGH, cur >> 4)
    )
    var prev2 = _prev[2](prev_chunk, cur)
    var prev3 = _prev[3](prev_chunk, cur)
    # High bit set exactly for 3-byte (>= 0xE0) / 4-byte (>= 0xF0) leads.
    var must23 = _satsub(prev2, _C16(0xE0 - 0x80)) | _satsub(
        prev3, _C16(0xF0 - 0x80)
    )
    var must23_80 = must23 & 0x80
    error |= must23_80 ^ sc


@always_inline("nodebug")
def _all_ascii(cur: _C16) -> Bool:
    """Whether no byte has its high bit set.

    `reduce_or` is the one formulation LLVM lowers optimally on both
    targets (verified from --emit=asm): PMOVMSKB + test on x86, and the
    same CMLT+ADDP sequence on aarch64 that `reduce_max` or a pack_bits
    sign-mask would produce (a naive horizontal max on x86 is a 20-insn
    shuffle tree, so don't switch this back to `reduce_max`)."""
    return (cur & 0x80).reduce_or() == 0


def _is_valid_utf8_simd(ptr: UnsafePointer[UInt8, _], n: Int) -> Bool:
    var error = _C16(0)
    var prev_chunk = _C16(0)
    var prev_incomplete = _C16(0)

    var i = 0
    while i + 16 <= n:
        var cur = (ptr + i).load[width=16]()
        if _all_ascii(cur):
            # All-ASCII chunk: only a dangling multi-byte sequence from
            # the previous chunk can be wrong.
            error |= prev_incomplete
        else:
            _check_chunk(cur, prev_chunk, error)
        prev_incomplete = _satsub(cur, _MAX_VALUE)
        prev_chunk = cur
        i += 16

    if i < n:
        # Final partial chunk, staged through a zeroed buffer: the NUL
        # padding is ASCII, so any sequence left dangling at the true end
        # of input fails its continuation checks here.
        var tail = InlineArray[Byte, 16](fill=0)
        memcpy(dest=tail.unsafe_ptr(), src=ptr + i, count=n - i)
        var cur = tail.unsafe_ptr().load[width=16]()
        _check_chunk(cur, prev_chunk, error)
    else:
        # Input ended exactly on a chunk boundary: a trailing lead byte
        # has no continuation to fail against, so check it directly.
        error |= prev_incomplete

    return error.reduce_max() == 0


def _is_valid_utf8_scalar(ptr: UnsafePointer[UInt8, _], n: Int) -> Bool:
    """Reference validator: explicit RFC 3629 range checks."""
    var i = 0
    while i < n:
        var b = ptr[i]
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
        var c1 = ptr[i + 1]
        if c1 < lo or c1 > hi:
            return False
        for k in range(2, need + 1):
            var ck = ptr[i + k]
            if ck < 0x80 or ck > 0xBF:
                return False
        i += need + 1
    return True


def is_valid_utf8(s: Span[Byte, _]) -> Bool:
    """Whether `s` is valid UTF-8 (RFC 3629: no overlongs, no surrogates,
    nothing above U+10FFFF, no truncated sequences)."""
    if not __is_run_in_comptime_interpreter:
        return _is_valid_utf8_simd(s.unsafe_ptr(), len(s))
    return _is_valid_utf8_scalar(s.unsafe_ptr(), len(s))


@always_inline
def is_valid_utf8(s: StringSlice) -> Bool:
    return is_valid_utf8(s.as_bytes())
