"""Exhaustive / large-scale float round-trip tests.

These tests are intentionally NOT under test/emberjson/ so the regular
`pixi run test` runner does not pick them up. Run them with:

    pixi run stress

Expected runtimes (optimised build):
  Float16 exhaustive  — ~65 536 values     — < 1 second
  Float32 exhaustive  — ~4.3 B values      — ~1-2 minutes
  Float64 stratified  — ~4 M samples       — ~5-10 seconds
"""

from emberjson.teju import write_float
from emberjson import Value, deserialize
from std.utils.numerics import isinf, isnan
from std.memory.unsafe import bitcast
from std.testing import assert_equal
import std.sys


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


@always_inline
def _check_f16(bits: UInt16) raises:
    var f = bitcast[DType.float16](bits)
    if isnan(f) or isinf(f):
        return
    var sw = String()
    write_float[DType.float16](f, sw)
    var parsed = deserialize[Float16](sw)
    if bitcast[DType.uint16](parsed) != bits:
        raise Error(
            "Float16 round-trip failed for bits="
            + String(bits)
            + " f="
            + String(f)
            + " serialized='"
            + sw
            + "' reparsed="
            + String(parsed)
        )


@always_inline
def _check_f32(bits: UInt32) raises:
    var f = bitcast[DType.float32](bits)
    if isnan(f) or isinf(f):
        return
    var sw = String()
    write_float[DType.float32](f, sw)
    var parsed = deserialize[Float32](sw)
    if bitcast[DType.uint32](parsed) != bits:
        raise Error(
            "Float32 round-trip failed for bits="
            + String(bits)
            + " f="
            + String(f)
            + " serialized='"
            + sw
            + "' reparsed="
            + String(parsed)
        )


@always_inline
def _check_f64(bits: UInt64) raises:
    var f = bitcast[DType.float64](bits)
    if isnan(f) or isinf(f):
        return
    var sw = String()
    write_float[DType.float64](f, sw)
    var parsed = deserialize[Float64](sw)
    if bitcast[DType.uint64](parsed) != bits:
        raise Error(
            "Float64 round-trip failed for bits="
            + String(bits)
            + " f="
            + String(f)
            + " serialized='"
            + sw
            + "' reparsed="
            + String(parsed)
        )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_float16_exhaustive() raises:
    """Tests all 65 536 Float16 bit patterns."""
    print("  float16: testing all 65536 values ...", end="", flush=True)
    for bits in range(65536):
        _check_f16(UInt16(bits))
    print(" OK")


def test_float32_exhaustive() raises:
    """Tests all ~4.3 billion Float32 bit patterns.

    Prints progress every 100 M iterations (~every second).
    """
    print("  float32: testing all 4294967296 values ...")
    var bits = UInt64(0)
    var limit = UInt64(UInt32.MAX) + 1
    var milestone = UInt64(100_000_000)
    while bits < limit:
        _check_f32(UInt32(bits))
        bits += 1
        if bits % milestone == 0:
            print(
                "    ",
                bits // 1_000_000,
                "M /",
                limit // 1_000_000,
                "M",
                flush=True,
            )
    print("  float32: OK")


def test_float64_stratified() raises:
    """Samples ~4 million Float64 values spread evenly across all bit patterns.

    Covers every exponent range and many mantissa configurations without
    attempting the infeasible ~5 800-year exhaustive scan.
    """
    comptime SAMPLES = UInt64(4_000_000)
    comptime STEP = UInt64.MAX // SAMPLES
    print(
        "  float64: testing",
        SAMPLES,
        "stratified samples (step =",
        STEP,
        ") ...",
        end="",
        flush=True,
    )
    var bits = UInt64(0)
    for _ in range(SAMPLES):
        _check_f64(bits)
        bits += STEP
    print(" OK")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() raises:
    print("Float round-trip stress tests")
    print("------------------------------")
    test_float16_exhaustive()
    test_float32_exhaustive()
    test_float64_stratified()
    print("------------------------------")
    print("All stress tests passed.")