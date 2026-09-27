"""The one JSON number parser.

Every number reader -- the `Value` and `Document` parsers and the
reflection deserializer -- is built from the scanners and conversions here,
so they accept, reject and round exactly the same tokens:

- `scan_number` scans the whole grammar into `NumberParts`, and
  `number_to_int` / `number_to_float64` convert those.
- `parse_int`, `parse_float64` and the untyped `parse_raw_number` are the
  fast paths. Their `try_` halves scan the common shape inline (at most 19
  digits, no exponent) with the pieces `scan_number` is made of; anything
  else goes to an out-of-line `scan_number` restarted from the number's
  first byte. The paths meet only in their result, never in `NumberParts`,
  so the inline conversion keeps what the compiler knows about the common
  shape (a float's power is minus its fraction digits), and the element
  loops it inlines into keep their state in registers.

Callers differ only in parameters that never change what is accepted:
`unchecked` (whether 16 bytes past any byte of the number are known to be
readable -- a `PaddedBuffer`, or the structural index -- or every wide read
must first check the distance to end-of-input), and how digits are read,
which was measured per caller.
"""

from std.bit import count_leading_zeros, count_trailing_zeros
from std.memory.unsafe import bitcast
from std.builtin.dtype import _uint_type_of_width
from std.sys.info import bit_width_of, CompilationTarget
from std.sys.intrinsics import unlikely, likely

from emberjson.constants import `-`, `+`, `0`, `1`, `9`, `.`
from emberjson.utils import BytePtr, CheckedPointer, lut, select, StackArray
from emberjson.simd import SIMD8_WIDTH
from emberserde.error import DeserializationError, DerErrorKind
from ._parser_helper import (
    at_or_nul,
    pack_into_integer,
    is_exp_char,
    isdigit,
    parse_digit,
    ptr_dist,
    significant_digits,
    smallest_power,
    largest_power,
    to_double,
    unsafe_is_made_of_eight_digits_fast,
    unsafe_parse_eight_digits,
    unsafe_is_made_of_four_digits_fast,
    unsafe_parse_four_digits,
    unsafe_parse_digit_run16,
    POW10_U64,
    _TOKEN_END_OK,
)
from .slow_float_parse import from_chars_slow
from .tables import POWER_OF_TEN, full_multiplication, POWER_OF_FIVE_128
from ._errors import (
    invalid_number,
    double_exponent_sign,
    plus_sign,
    infinite_float,
    found_float,
    found_negative,
    int_overflow,
)


# x86 reads number digits with the SSE `unsafe_parse_digit_run16`
# instead of digit loops and SWAR probes. The SWAR constants are 64-bit
# immediates, each held in a general-purpose register; inlined into an
# element loop they overflow x86's 15 GPRs and the loop state spills.
# aarch64 (31 GPRs) keeps the SWAR scan until the swap is measured there.
comptime SSE_DIGITS = CompilationTarget.has_avx2()


def _gen_number_end_table(out t: StackArray[Bool, 256]):
    t = materialize[_TOKEN_END_OK]()
    # At end of input, `at_or_nul` and a `PaddedBuffer` read NUL.
    t.unsafe_get(0) = True


comptime _NUMBER_END: StackArray[Bool, 256] = _gen_number_end_table()
"""Bytes after which the `try_` fast paths settle a number inline: those that end a scalar token, and NUL for end of input. Anything
else -- `.`, an exponent, a stray byte -- goes to the general scan, which
decides between a fraction, an error, and a token the caller's grammar
will reject."""


@fieldwise_init
struct RawNumber(TrivialRegisterPassable):
    """A parsed JSON number as kind + raw 64-bit payload, decoupled from
    `Value` so non-DOM consumers (the tape builder) can share the number
    grammar without materializing a variant."""

    comptime INT64: Byte = 0
    comptime UINT64: Byte = 1
    comptime FLOAT64: Byte = 2

    var kind: Byte
    var bits: UInt64


@fieldwise_init
struct NumberParts[origin: ImmOrigin](TrivialRegisterPassable):
    """A scanned JSON number: `-i * 10^exponent` if `neg`, else
    `i * 10^exponent`, before any rounding.

    `i` holds the integer and fraction digits as one integer. Past 19
    digits it wraps; `digit_count` (the digits in `i`, not counting the
    `.`) is how consumers detect that.
    """

    var start: BytePtr[Self.origin]
    """The number's first byte: its `-`, or its first digit."""
    var i: UInt64
    var exponent: Int64
    var digit_count: Int
    var neg: Bool
    var is_float: Bool
    """Whether the number has a fraction or an exponent."""

    @always_inline
    def digits(self) -> BytePtr[Self.origin]:
        """The first digit."""
        return self.start.unsafe_offset(Int(self.neg))


# ===----------------------------------------------------------------------===#
# Scanning
# ===----------------------------------------------------------------------===#


@always_inline
def ingest_digits[
    unchecked: Bool, sse: Bool = SSE_DIGITS
](mut p: CheckedPointer, mut i: UInt64):
    """Consumes the run of digits at `p` into `i`, which wraps past 19
    digits (callers count them).

    Parameters:
        unchecked: 16 bytes past any byte of the run are readable, so the
            wide reads need no distance check.
        sse: Read with `unsafe_parse_digit_run16` rather than SWAR probes.
            Only speed differs; see `SSE_DIGITS`.
    """
    comptime if sse:
        # The interpreter cannot run the SSE intrinsics; comptime parses
        # take the SWAR scan below.
        if not __is_run_in_comptime_interpreter:
            # The first step is peeled: nearly every run ends inside it, and
            # for an integer part (`i` still 0) its multiply folds away.
            if unchecked or p.dist() >= 16:
                if likely(_digit_run16_step(p, i)):
                    return
                while unchecked or p.dist() >= 16:
                    if _digit_run16_step(p, i):
                        return
            while parse_digit[unchecked](p, i):
                p += 1
            return
    # 8 at a time, then one 4-digit step, then singly (fast_float
    # #382/#398): canada's 15-digit fractions become 8 + 4 + 3. Unchecked,
    # the probes may read past the run, and the byte there fails them.
    while (unchecked or p.dist() >= 8) and unsafe_is_made_of_eight_digits_fast(
        p.p
    ):
        i = i * 100_000_000 + unsafe_parse_eight_digits(p.p)
        p += 8
    if (unchecked or p.dist() >= 4) and unsafe_is_made_of_four_digits_fast(p.p):
        i = i * 10_000 + unsafe_parse_four_digits(p.p)
        p += 4
    while parse_digit[unchecked](p, i):
        p += 1


@no_inline
def skip_digits[unchecked: Bool](mut p: CheckedPointer):
    """Consumes the run of digits at `p` without reading its value, for
    validators (`scan_number[validate_only=True]`).

    A number's runs are short (citm's are 1-13 digits), so the first 16
    digits are tested one at a time, where a vector scan's fixed cost would
    not amortize; longer runs continue 16 at a time. Measured on citm's
    `Lazy` captures (Zen 2): out of line, within 1% of the validator's old
    byte walk; inlined, 9% slower; `ingest_digits` (SSE), 3% slower.

    Parameters:
        unchecked: See `ingest_digits`.
    """
    comptime for _ in range(16):
        if not isdigit(at_or_nul[unchecked](p)):
            return
        p += 1
    if not __is_run_in_comptime_interpreter:
        while unchecked or p.dist() >= SIMD8_WIDTH:
            var chunk = p.p.unsafe_load[width=SIMD8_WIDTH]()
            var stop = pack_into_integer(~(chunk.ge(`0`) & chunk.le(`9`)))
            if stop != 0:
                p += Int(count_trailing_zeros(stop))
                return
            p += SIMD8_WIDTH
    while isdigit(at_or_nul[unchecked](p)):
        p += 1


@always_inline
def _digit_run16_step(mut p: CheckedPointer, mut i: UInt64) -> Bool:
    """Consumes up to 16 digits at `p` (16 bytes readable) into `i`;
    whether the run ended within them."""
    var run = unsafe_parse_digit_run16(p.p)
    i = i * lut[POW10_U64](run[1]) + run[0]
    p += run[1]
    return run[1] < 16


@always_inline
def _scan_integer_part[
    origin: ImmOrigin,
    //,
    unchecked: Bool,
    wide: Bool,
    sse: Bool,
    validate_only: Bool = False,
](mut p: CheckedPointer[origin]) raises DeserializationError -> NumberParts[
    origin
]:
    """`-? (0 | [1-9][0-9]*)` at `p`, which is on a byte of the input.

    Parameters:
        unchecked: See `ingest_digits`.
        wide: Read the digits with `ingest_digits`, for integers. Otherwise
            they are read one at a time: a float's integer part rarely runs
            past three digits, and the fraction's wide read then starts
            sooner. Only the speed differs, never what is accepted.
        sse: See `ingest_digits`.
    """
    var start = p.p
    var neg = p.unsafe_get() == `-`
    p += Int(neg)
    var digits = p.p
    var i: UInt64 = 0
    comptime if validate_only:
        skip_digits[unchecked](p)
    elif wide:
        ingest_digits[unchecked, sse](p, i)
    else:
        while parse_digit[unchecked](p, i):
            p += 1
    var digit_count = ptr_dist(digits, p.p)
    if unlikely(digit_count == 0 or (digit_count > 1 and digits[] == `0`)):
        raise invalid_number()
    return NumberParts(start, i, 0, digit_count, neg, False)


@always_inline
def _scan_fraction[
    origin: ImmOrigin,
    //,
    unchecked: Bool,
    sse: Bool = SSE_DIGITS,
    validate_only: Bool = False,
](
    mut p: CheckedPointer[origin], mut n: NumberParts[origin]
) raises DeserializationError:
    """`(. [0-9]+)?` after the integer part."""
    if at_or_nul[unchecked](p) != `.`:
        return
    n.is_float = True
    p += 1
    var first = p
    comptime if validate_only:
        skip_digits[unchecked](p)
    else:
        ingest_digits[unchecked, sse](p, n.i)
    var frac_digits = ptr_dist(first.p, p.p)
    if unlikely(frac_digits == 0):
        raise invalid_number()
    n.exponent = -Int64(frac_digits)
    n.digit_count += frac_digits


@always_inline
def _scan_exponent[
    origin: ImmOrigin, //, unchecked: Bool
](
    mut p: CheckedPointer[origin], mut n: NumberParts[origin]
) raises DeserializationError:
    """`([eE] [+-]? [0-9]+)?` after the fraction."""
    if not is_exp_char(at_or_nul[unchecked](p)):
        return
    n.is_float = True
    p += 1
    var neg_exp = at_or_nul[unchecked](p) == `-`
    p += Int(neg_exp or at_or_nul[unchecked](p) == `+`)
    if unlikely(is_exp_char(at_or_nul[unchecked](p))):
        raise double_exponent_sign()
    var start_exp = p
    var exp_number: Int64 = 0
    while parse_digit[unchecked](p, exp_number):
        p += 1
    if unlikely(p == start_exp):
        raise invalid_number()
    if unlikely(p > start_exp + 18):
        # Past 18 digits `exp_number` may have wrapped; leading zeros do
        # not count, and any real excess saturates to a power no double
        # reaches.
        while at_or_nul[unchecked](start_exp) == `0`:
            start_exp += 1
        if p > start_exp + 18:
            exp_number = 999999999999999999
    n.exponent += select(neg_exp, -exp_number, exp_number)


@always_inline
def scan_number[
    origin: ImmOrigin,
    //,
    unchecked: Bool,
    wide_integer_part: Bool = True,
    sse: Bool = SSE_DIGITS,
    validate_only: Bool = False,
](mut p: CheckedPointer[origin]) raises DeserializationError -> NumberParts[
    origin
]:
    """Consumes the JSON number at `p`, which must be on a byte of the
    input: `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`.

    Anything else raises `InvalidValue`. Callers that give a byte other
    than `-` or a digit its own error (a shape mismatch, say) check the
    first byte before calling.

    Parameters:
        unchecked: See `ingest_digits`.
        wide_integer_part: See `_scan_integer_part`.
        sse: See `ingest_digits`.
        validate_only: Skip the digits (`skip_digits`) rather than read
            them: only the grammar is checked, and `i` (and so any value
            computed from the parts) is meaningless. `digit_count`,
            `is_float` and the exponent stay exact.
    """
    var n = _scan_integer_part[
        unchecked, wide_integer_part, sse, validate_only
    ](p)
    _scan_fraction[unchecked, sse, validate_only](p, n)
    _scan_exponent[unchecked](p, n)
    return n


# ===----------------------------------------------------------------------===#
# Untyped numbers (`Value`, `Document`)
# ===----------------------------------------------------------------------===#


@always_inline
def parse_raw_number[
    origin: ImmOrigin, //, unchecked: Bool
](mut p: CheckedPointer[origin]) raises DeserializationError -> RawNumber:
    """The number at `p` as an Int64, a UInt64 above Int64's range, or a
    Float64: `try_parse_raw_number` inline, anything else rescanned out of
    line."""
    var start = p.p
    var r = RawNumber(0, 0)
    if likely(try_parse_raw_number[unchecked](p, r)):
        return r
    var g = _parse_raw_number_general[unchecked](
        CheckedPointer(start, p.start, p.end)
    )
    p = g[1]
    return g[0]


@always_inline
def try_parse_raw_number[
    origin: ImmOrigin, //, unchecked: Bool
](
    mut p: CheckedPointer[origin], mut r: RawNumber
) raises DeserializationError -> Bool:
    """`parse_raw_number` for the common shapes, at most 19 digits and no
    exponent: stores the number in `r`. False otherwise, as `try_parse_int`
    returns it.

    The integer part is read with SWAR rather than SSE even on x86: the
    tape builder's loop has the registers for it, and it was measured
    faster there.
    """
    var c0 = p.unsafe_get()
    if unlikely(not (isdigit(c0) or c0 == `-`)):
        return False
    var n = _scan_integer_part[unchecked, wide=True, sse=False](p)
    _scan_fraction[unchecked](p, n)
    if unlikely(
        n.digit_count > 19 or not lut[_NUMBER_END](Int(at_or_nul[unchecked](p)))
    ):
        return False
    if n.is_float:
        # `i` is exact, and the power is minus the fraction digits.
        var f = compute_float64[fraction_power=True](n.exponent, n.i, n.neg)
        r = RawNumber(RawNumber.FLOAT64, bitcast[DType.uint64](f))
        return True
    comptime MIN_ABS = UInt64(1) << 63
    if n.neg:
        # Past Int64.MIN it is a Float64, which the general scan builds.
        if unlikely(n.i > MIN_ABS):
            return False
        r = RawNumber(RawNumber.INT64, ~n.i + 1)
    else:
        r = RawNumber(
            select(n.i >= MIN_ABS, RawNumber.UINT64, RawNumber.INT64), n.i
        )
    return True


@no_inline
def _parse_raw_number_general[
    origin: ImmOrigin, //, unchecked: Bool
](var p: CheckedPointer[origin]) raises DeserializationError -> Tuple[
    RawNumber, CheckedPointer[origin]
]:
    if p.unsafe_get() == `+`:
        raise plus_sign()
    var n = scan_number[unchecked](p)
    if n.is_float:
        var f = number_to_float64(n, p.end)
        return RawNumber(RawNumber.FLOAT64, bitcast[DType.uint64](f)), p

    # `n.i` is exact up to 19 digits. At 20, a positive number starting
    # with `1` lies in [10^19, 2*10^19): below 2^64 it is exactly `i`,
    # which then exceeds Int64.MAX; at or above 2^64 it wrapped to below
    # 2*10^19 - 2^64 < 2^63.
    var longest_digit_count = select(n.neg, 19, 20)
    comptime SIGNED_OVERFLOW = UInt64(Int64.MAX)
    var overflow = n.digit_count > longest_digit_count
    if not overflow and n.digit_count == longest_digit_count:
        if n.neg:
            overflow = n.i > SIGNED_OVERFLOW + 1
        else:
            overflow = n.digits()[] != `1` or n.i <= SIGNED_OVERFLOW
    if unlikely(overflow):
        # R2: an integer literal outside Int64/UInt64 is a Float64, the
        # same result `List[Float64]` already produces; only ±Inf raises.
        var f = number_to_float64(n, p.end)
        return RawNumber(RawNumber.FLOAT64, bitcast[DType.uint64](f)), p
    if not n.neg and n.i > SIGNED_OVERFLOW:
        return RawNumber(RawNumber.UINT64, n.i), p
    return RawNumber(RawNumber.INT64, select(n.neg, ~n.i + 1, n.i)), p


# ===----------------------------------------------------------------------===#
# Integers
# ===----------------------------------------------------------------------===#


@always_inline
def parse_int[
    origin: ImmOrigin, //, DT: DType, unchecked: Bool
](mut p: CheckedPointer[origin]) raises DeserializationError -> Scalar[DT]:
    """`number_to_int[DT](scan_number(p))`: `try_parse_int` inline, and a
    fraction or exponent (a `TypeMismatch` unless malformed) rescanned out
    of line."""
    var start = p.p
    var v = Scalar[DT]()
    if likely(try_parse_int[DT, unchecked](p, v)):
        return v
    var r = _parse_int_general[DT, unchecked](
        CheckedPointer(start, p.start, p.end)
    )
    p = r[1]
    return r[0]


@always_inline
def try_parse_int[
    origin: ImmOrigin, //, DT: DType, unchecked: Bool, nul_ends: Bool = True
](
    mut p: CheckedPointer[origin], mut v: Scalar[DT]
) raises DeserializationError -> Bool:
    """`parse_int` for the common shape, digits alone: stores the value in
    `v`. False, with `p` somewhere inside the number, when `p` is not on
    `-` or a digit, past 19 digits, or when anything but a `_NUMBER_END`
    byte follows the digits. Makes no calls, so a caller that inlines it
    can keep its own state in registers and handle False on one cold
    path.

    Parameters:
        DT: The integer type to produce.
        unchecked: See `ingest_digits`.
        nul_ends: Whether a NUL after the number is end of input. A caller
            that knows the number ends inside the input passes False, and
            True then also means the byte after it ends the token.
    """
    comptime END = _NUMBER_END if nul_ends else _TOKEN_END_OK
    var c0 = p.unsafe_get()
    if unlikely(not (isdigit(c0) or c0 == `-`)):
        return False
    var n = _scan_integer_part[unchecked, wide=True, sse=SSE_DIGITS](p)
    if unlikely(
        n.digit_count > 19 or not lut[END](Int(at_or_nul[unchecked](p)))
    ):
        return False
    v = number_to_int[DT](n)
    return True


@no_inline
def _parse_int_general[
    origin: ImmOrigin, //, DT: DType, unchecked: Bool
](var p: CheckedPointer[origin]) raises DeserializationError -> Tuple[
    Scalar[DT], CheckedPointer[origin]
]:
    var v = number_to_int[DT](scan_number[unchecked](p))
    return v, p


@always_inline
def number_to_int[
    DT: DType
](n: NumberParts) raises DeserializationError -> Scalar[DT]:
    """The integer `n` spells, as a `DT`.

    A float, or an integer outside `DT`'s range, is well-formed JSON the
    target cannot represent: a shape problem, not a grammar one (there is
    no range kind), so it raises `TypeMismatch`.
    """
    comptime assert DT.is_integral()
    comptime acc = _uint_type_of_width[max(bit_width_of[DT](), 64)]()
    if unlikely(n.is_float):
        raise found_float()
    # 19 digits cannot wrap `i` (10^19 - 1 < 2^64).
    var mag: Scalar[acc]
    if likely(n.digit_count <= 19):
        mag = n.i.cast[acc]()
    else:
        mag = _long_magnitude[acc](n.digits(), n.digit_count)

    comptime if DT.is_signed():
        # A negative value may reach one past `MAX`: `MIN`'s magnitude.
        if unlikely(mag > Scalar[DT].MAX.cast[acc]() + Scalar[acc](Int(n.neg))):
            raise int_overflow()
        return select(n.neg, ~mag + 1, mag).cast[DT]()
    else:
        if unlikely(mag > Scalar[DT].MAX.cast[acc]()):
            raise int_overflow()
        if unlikely(n.neg):
            raise found_negative()
        return mag.cast[DT]()


@no_inline
def _long_magnitude[
    acc: DType
](digits: BytePtr, count: Int) raises DeserializationError -> Scalar[acc]:
    """The value of the `count` (already scanned) digits at `digits`,
    which do not fit `NumberParts.i`'s 19."""
    comptime MAX_VAL = Scalar[acc].MAX // 10
    comptime MAX_REM = Scalar[acc].MAX % 10
    var v = Scalar[acc](0)
    for k in range(count):
        var d = (digits[unsafe_offset=k] - `0`).cast[acc]()
        if unlikely(v > MAX_VAL or (v == MAX_VAL and d > MAX_REM)):
            raise int_overflow()
        v = v * 10 + d
    return v


# ===----------------------------------------------------------------------===#
# Floats
# BASED ON SIMDJSON https://github.com/simdjson/simdjson/blob/master/include/simdjson/generic/numberparsing.h
# ===----------------------------------------------------------------------===#


@always_inline
def parse_float64[
    origin: ImmOrigin, //, unchecked: Bool
](mut p: CheckedPointer[origin]) raises DeserializationError -> Float64:
    """`number_to_float64(scan_number(p))`: `try_parse_float64` inline, and
    anything else rescanned out of line."""
    var start = p.p
    var v = Float64()
    if likely(try_parse_float64[unchecked](p, v)):
        return v
    var r = _parse_float64_general[unchecked](
        CheckedPointer(start, p.start, p.end)
    )
    p = r[1]
    return r[0]


@always_inline
def try_parse_float64[
    origin: ImmOrigin, //, unchecked: Bool, nul_ends: Bool = True
](
    mut p: CheckedPointer[origin], mut v: Float64
) raises DeserializationError -> Bool:
    """`parse_float64` for the common shape, no exponent and at most 19
    digits: stores the value in `v`. False otherwise, as `try_parse_int`
    returns it (which also describes the parameters)."""
    comptime END = _NUMBER_END if nul_ends else _TOKEN_END_OK
    var c0 = p.unsafe_get()
    if unlikely(not (isdigit(c0) or c0 == `-`)):
        return False
    var n = _scan_integer_part[unchecked, wide=False, sse=SSE_DIGITS](p)
    _scan_fraction[unchecked](p, n)
    if unlikely(
        n.digit_count > 19 or not lut[END](Int(at_or_nul[unchecked](p)))
    ):
        return False
    # `i` is exact, and the power is minus the fraction digits: [-19, 0].
    v = compute_float64[fraction_power=True](n.exponent, n.i, n.neg)
    return True


@no_inline
def _parse_float64_general[
    origin: ImmOrigin, //, unchecked: Bool
](var p: CheckedPointer[origin]) raises DeserializationError -> Tuple[
    Float64, CheckedPointer[origin]
]:
    var n = scan_number[unchecked, wide_integer_part=False](p)
    return number_to_float64(n, p.end), p


@always_inline
def number_to_float64[
    origin: ImmOrigin, //
](
    n: NumberParts[origin], end: BytePtr[origin]
) raises DeserializationError -> Float64:
    """The Float64 nearest `n`, which was scanned from an input ending at
    `end`."""
    if unlikely(n.digit_count > 19):
        return _long_number_to_float64(n, end)
    return compute_float64(n.exponent, n.i, n.neg)


@no_inline
def _long_number_to_float64[
    origin: ImmOrigin, //
](
    n: NumberParts[origin], end: BytePtr[origin]
) raises DeserializationError -> Float64:
    """`number_to_float64` past 19 digits. Leading zeros do not limit
    precision; past 19 significant digits `n.i` has lost digits, so the
    decimal is converted exactly."""
    if significant_digits(n.digits(), n.digit_count) > 19:
        return from_chars_slow[DType.float64](
            CheckedPointer(n.start, n.start, end)
        )
    return compute_float64(n.exponent, n.i, n.neg)


@always_inline
def compute_float64[
    fraction_power: Bool = False
](
    power: Int64, var i: UInt64, negative: Bool
) raises DeserializationError -> Float64:
    """The Float64 nearest `i * 10^power` (negated if `negative`), for an
    exact `i` (at most 19 digits).

    Parameters:
        fraction_power: The caller guarantees `power` is in [-19, 0], as a
            number without an exponent has, which removes the range checks
            and specializes the fast path to one division.
    """
    comptime if fraction_power:
        # -19 is within the fast path's powers, and `i == 0` takes it.
        if i <= 9007199254740991:
            var d = Float64(i) / lut[POWER_OF_TEN](Int(-power))
            return select(negative, -d, d)
    else:
        if Int64(-22) <= power <= Int64(22) and i <= 9007199254740991:
            var d = Float64(i)
            var pow = lut[POWER_OF_TEN](Int(abs(power)))
            d = select(power < 0, d / pow, d * pow)
            return select(negative, -d, d)
        if unlikely(i == 0 or power < smallest_power):
            return select(negative, -0.0, 0.0)
        if unlikely(power > largest_power):
            raise infinite_float()

    # Eisel-Lemire.
    var lz = count_leading_zeros(i)
    i <<= lz

    var index = Int(2 * (power - smallest_power))

    var first_product = full_multiplication(i, lut[POWER_OF_FIVE_128](index))

    var upper = UInt64(first_product >> 64)
    var lower = UInt64(first_product)

    if unlikely(upper & 0x1FF == 0x1FF):
        _el_second_product(i, index, upper, lower)

    var upperbit: UInt64 = upper >> 63
    var mantissa: UInt64 = upper >> (upperbit + 9)
    lz += UInt64(1 ^ upperbit)

    comptime `152170 + 65536` = 152170 + 65536
    comptime `1024 + 63` = 1024 + 63

    var real_exponent: Int64 = (
        (((`152170 + 65536`) * power) >> 16)
        + `1024 + 63`
        - lz.cast[DType.int64]()
    )

    comptime `1 << 52` = 1 << 52

    if unlikely(real_exponent <= 0):
        return _el_subnormal(mantissa, real_exponent, negative)

    if unlikely(lower == 0 and (upper & 0x1FF) == 0 and (mantissa & 3 == 1)):
        comptime `64 - 53 - 2` = 64 - 53 - 2
        if (mantissa << (upperbit + `64 - 53 - 2`)) == upper:
            mantissa &= ~1

    mantissa += mantissa & 1
    mantissa >>= 1

    comptime `1 << 53` = 1 << 53
    if mantissa >= `1 << 53`:
        mantissa = `1 << 52`
        real_exponent += 1
    mantissa &= ~(`1 << 52`)

    if unlikely(real_exponent > 2046):
        raise infinite_float()

    return to_double(mantissa, real_exponent.cast[DType.uint64](), negative)


# Eisel-Lemire's rare paths, kept out of line: calls are speculation
# barriers, and inline the backend if-converts them, so every float pays for
# the subnormal rounding and the second 128-bit product it almost never needs.
@no_inline
def _el_second_product(
    i: UInt64, index: Int, mut upper: UInt64, mut lower: UInt64
):
    """Refines the product when its low 9 bits leave rounding undecided."""
    var second_product = full_multiplication(
        i, lut[POWER_OF_FIVE_128](index + 1)
    )
    var upper_s = UInt64(second_product >> 64)
    lower += upper_s
    if upper_s > lower:
        upper += 1


@no_inline
def _el_subnormal(
    out d: Float64, var mantissa: UInt64, real_exponent: Int64, negative: Bool
):
    """The result when the biased exponent underflows (subnormal or zero)."""
    comptime `1 << 52` = 1 << 52
    if -real_exponent + 1 >= 64:
        d = select(negative, -0.0, 0.0)
        return
    mantissa >>= (-real_exponent + 1).cast[DType.uint64]()
    mantissa += mantissa & 1
    mantissa >>= 1
    var biased = select(mantissa < `1 << 52`, Int64(0), Int64(1))
    d = to_double(mantissa, biased.cast[DType.uint64](), negative)
