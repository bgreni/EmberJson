"""Device number parsing for GPU stage 2 (Phase 4).

Metal supports NO FP64 — any `double`-typed instruction fails backend
verification — so this is the Eisel-Lemire float algorithm in pure
integer form: the same `full_multiplication` / `POWER_OF_FIVE_128` /
`to_double` machinery as `Parser.compute_float64`, minus the CPU's
FP64 shortcut (`compute_float_fast`, valid only as an optimization:
both paths produce the unique correctly-rounded double, so skipping the
shortcut is bit-identical — enforced by the tape-equality gates). The
result is the raw 64-bit IEEE pattern, which is exactly what the tape's
number word stores; `Float64` never materializes on device.

Kernels cannot raise, and the arbitrary-precision `from_chars_slow`
fallback is CPU-only by design — every function returns an `ok` flag
instead. A not-ok token lands on the CPU fix-up list, where the full
CPU parser re-parses it from the input bytes: slow-path numbers get
their exact value, and genuinely invalid numbers raise there with the
CPU error verdict.
"""

from emberjson._deserialize._parser_helper import (
    largest_power,
    smallest_power,
)
from std.bit import count_leading_zeros
from std.memory import UnsafePointer

comptime _NEG_ZERO_BITS: UInt64 = UInt64(1) << 63

# Metal-specific constraints (probed):
#   * UInt128 arithmetic CRASHES the Metal shader compiler — the
#     64x64->128 multiply is done in 32-bit limbs instead.
#   * comptime StackArray globals do not link into Metal kernels
#     ("Undefined symbols: global_constant") — POWER_OF_FIVE_128 is
#     uploaded once per session as a DeviceBuffer and passed by pointer.


@always_inline
def _mul_64x64_128(x: UInt64, y: UInt64) -> Tuple[UInt64, UInt64]:
    """(hi, lo) of the 128-bit product, in 32-bit limbs (Metal-safe;
    equivalent to `tables.full_multiplication`)."""
    var x0 = x & 0xFFFFFFFF
    var x1 = x >> 32
    var y0 = y & 0xFFFFFFFF
    var y1 = y >> 32
    var p00 = x0 * y0
    var p01 = x0 * y1
    var p10 = x1 * y0
    var p11 = x1 * y1
    var mid = p01 + (p00 >> 32) + (p10 & 0xFFFFFFFF)
    var lo = (mid << 32) | (p00 & 0xFFFFFFFF)
    var hi = p11 + (mid >> 32) + (p10 >> 32)
    return (hi, lo)


@always_inline
def _zero_bits(negative: Bool) -> UInt64:
    return _NEG_ZERO_BITS if negative else UInt64(0)


@always_inline
def _assemble_double_bits(
    var mantissa: UInt64, real_exponent: UInt64, negative: Bool
) -> UInt64:
    """Integer form of `_parser_helper.to_double` (which returns
    Float64; Metal cannot)."""
    comptime `1 << 52` = 1 << 52
    mantissa &= ~UInt64(`1 << 52`)
    mantissa |= real_exponent << 52
    mantissa |= UInt64(negative) << 63
    return mantissa


@always_inline
def device_float_bits(
    power: Int64,
    var i: UInt64,
    negative: Bool,
    five_table: UnsafePointer[UInt64, MutAnyOrigin],
) -> Tuple[UInt64, Bool]:
    """Mirror of `Parser.compute_float64` in integer form ->
    (IEEE-754 bits, ok). `five_table` is the uploaded
    POWER_OF_FIVE_128 data. Not-ok covers the CPU path's raise
    ("infinite value") — the fix-up reparse reproduces the verdict."""
    if i == 0 or power < -342:
        return (_zero_bits(negative), True)

    var lz = count_leading_zeros(i)
    i <<= lz

    var index = Int(2 * (power - smallest_power))

    var first_product = _mul_64x64_128(i, five_table[index])

    var upper = first_product[0]
    var lower = first_product[1]

    if upper & 0x1FF == 0x1FF:
        var second_product = _mul_64x64_128(i, five_table[index + 1])
        var upper_s = second_product[0]
        lower += upper_s
        if upper_s > lower:
            upper += 1

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

    if real_exponent <= 0:
        if -real_exponent + 1 >= 64:
            return (_zero_bits(negative), True)
        mantissa >>= (-real_exponent + 1).cast[DType.uint64]()
        mantissa += mantissa & 1
        mantissa >>= 1
        real_exponent = Int64(0) if mantissa < `1 << 52` else Int64(1)
        return (
            _assemble_double_bits(
                mantissa, real_exponent.cast[DType.uint64](), negative
            ),
            True,
        )

    if lower == 0 and (upper & 0x1FF) == 0 and (mantissa & 3 == 1):
        comptime `64 - 53 - 2` = 64 - 53 - 2
        if (mantissa << (upperbit + `64 - 53 - 2`)) == upper:
            mantissa &= ~1

    mantissa += mantissa & 1
    mantissa >>= 1

    comptime `1 << 53` = 1 << 53
    if mantissa >= `1 << 53`:
        mantissa = `1 << 52`
        real_exponent += 1
    mantissa &= ~UInt64(`1 << 52`)

    if real_exponent > 2046:
        # CPU path raises "infinite value" here.
        return (UInt64(0), False)

    return (
        _assemble_double_bits(
            mantissa, real_exponent.cast[DType.uint64](), negative
        ),
        True,
    )


@always_inline
def device_write_float_bits(
    power: Int64,
    i: UInt64,
    negative: Bool,
    long_digits: Bool,
    five_table: UnsafePointer[UInt64, MutAnyOrigin],
) -> Tuple[UInt64, Bool]:
    """Mirror of `Parser.write_float`'s dispatch. `long_digits` is the
    caller's >19-significant-digits determination (slow path)."""
    if long_digits:
        return (UInt64(0), False)
    if power < smallest_power or power > largest_power:
        if power < smallest_power or i == 0:
            return (_zero_bits(negative), True)
        # CPU raises "Invalid number: inf".
        return (UInt64(0), False)
    return device_float_bits(power, i, negative, five_table)
