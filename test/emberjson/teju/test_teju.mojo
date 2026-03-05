from emberjson.teju import write_float
from testing import assert_equal, TestSuite
from std.format import Writer
from utils.numerics import FPUtils


fn get_smallest_subnormal[dtype: DType]() -> Scalar[dtype]:
    var x = Scalar[dtype](1)
    var prev = x
    while x > 0:
        prev = x
        x /= Scalar[dtype](2)
    return prev


fn get_largest_subnormal[dtype: DType]() -> Scalar[dtype]:
    comptime mantissa_width = FPUtils[dtype].mantissa_width()
    var prev = get_smallest_subnormal[dtype]()
    var largest = prev
    for i in range(1, mantissa_width):
        largest += prev * Scalar[dtype](1 << i)
    return largest


def test_float16():
    var sw = String()
    write_float[DType.float16](Float16(1.25), sw)
    assert_equal(sw, "1.25")

    sw = String()
    write_float[DType.float16](Float16(0.0), sw)
    assert_equal(sw, "0.0")

    sw = String()
    write_float[DType.float16](Float16(-0.0), sw)
    assert_equal(sw, "-0.0")

    sw = String()
    write_float[DType.float16](Float16(-3.5), sw)
    assert_equal(sw, "-3.5")

    # Boundary values for f16
    sw = String()
    write_float[DType.float16](Float16(65504.0), sw)
    assert_equal(sw, "65504.0")

    sw = String()
    write_float[DType.float16](Float16(0.000061035), sw)
    assert_equal(sw, "6.104e-05")

    # More f16 cases
    sw = String()
    write_float[DType.float16](Float16(-65504.0), sw)
    assert_equal(sw, "-65504.0")

    sw = String()
    write_float[DType.float16](Float16(0.0001), sw)
    assert_equal(sw, "0.0001")

    sw = String()
    write_float[DType.float16](Float16(0.0000999), sw)
    assert_equal(sw, "9.99e-05")

    sw = String()
    write_float[DType.float16](Float16(0.3), sw)
    assert_equal(sw, "0.3")

    sw = String()
    write_float[DType.float16](Float16(0.7), sw)
    assert_equal(sw, "0.7")

    # Smallest and Largest subnormals
    var smallest = get_smallest_subnormal[DType.float16]()
    sw = String()
    write_float[DType.float16](smallest, sw)
    assert_equal(sw, "6e-08")

    var largest = get_largest_subnormal[DType.float16]()
    sw = String()
    write_float[DType.float16](largest, sw)
    assert_equal(sw, "6.1e-05")


def test_float32():
    var sw = String()
    write_float[DType.float32](Float32(1.23456), sw)
    assert_equal(sw, "1.23456")

    sw = String()
    write_float[DType.float32](Float32(0.0), sw)
    assert_equal(sw, "0.0")

    sw = String()
    write_float[DType.float32](Float32(-0.0), sw)
    assert_equal(sw, "-0.0")

    sw = String()
    write_float[DType.float32](Float32(-123.456), sw)
    assert_equal(sw, "-123.456")

    # Scientific notation
    sw = String()
    write_float[DType.float32](Float32(1e-10), sw)
    assert_equal(sw, "1e-10")

    sw = String()
    write_float[DType.float32](Float32(1e20), sw)
    assert_equal(sw, "1e20")

    # Boundary values
    sw = String()
    write_float[DType.float32](Float32(3.4028235e38), sw)
    assert_equal(sw, "3.4028235e38")

    sw = String()
    write_float[DType.float32](Float32(1.17549435e-38), sw)
    assert_equal(sw, "1.1754944e-38")

    # More f32 cases
    sw = String()
    write_float[DType.float32](Float32(-3.4028235e38), sw)
    assert_equal(sw, "-3.4028235e38")

    sw = String()
    write_float[DType.float32](Float32(0.0001), sw)
    assert_equal(sw, "0.0001")

    sw = String()
    write_float[DType.float32](Float32(0.00009999), sw)
    assert_equal(sw, "9.999e-05")

    sw = String()
    write_float[DType.float32](Float32(1e15), sw)
    # Note: Currently formats as full precision instead of shortest
    assert_equal(sw, "999999986991104.0")

    sw = String()
    write_float[DType.float32](Float32(1e16), sw)
    assert_equal(sw, "1.0000000272564224e16")

    sw = String()
    write_float[DType.float32](Float32(0.3), sw)
    assert_equal(sw, "0.3")

    sw = String()
    write_float[DType.float32](Float32(0.7), sw)
    assert_equal(sw, "0.7")

    # Smallest and Largest subnormals
    var smallest = get_smallest_subnormal[DType.float32]()
    sw = String()
    write_float[DType.float32](smallest, sw)
    assert_equal(sw, "1e-45")

    var largest = get_largest_subnormal[DType.float32]()
    sw = String()
    write_float[DType.float32](largest, sw)
    assert_equal(sw, "1.1754942e-38")


def test_float64():
    var sw = String()
    write_float[DType.float64](Float64(1.234567890123), sw)
    assert_equal(sw, "1.234567890123")

    sw = String()
    write_float[DType.float64](Float64(0.7), sw)
    assert_equal(sw, "0.7")

    # Smallest and Largest subnormals
    var smallest = get_smallest_subnormal[DType.float64]()
    sw = String()
    write_float[DType.float64](smallest, sw)
    assert_equal(sw, "5e-324")

    var largest = get_largest_subnormal[DType.float64]()
    sw = String()
    write_float[DType.float64](largest, sw)
    assert_equal(sw, "2.225073858507201e-308")

    sw = String()
    write_float[DType.float64](Float64(0.0), sw)
    assert_equal(sw, "0.0")

    sw = String()
    write_float[DType.float64](Float64(-0.0), sw)
    assert_equal(sw, "-0.0")

    # Scientific notation
    sw = String()
    write_float[DType.float64](Float64(1e-10), sw)
    assert_equal(sw, "1e-10")

    sw = String()
    write_float[DType.float64](Float64(1e20), sw)
    assert_equal(sw, "1e20")

    sw = String()
    write_float[DType.float64](Float64(-1.234567890123e10), sw)
    assert_equal(sw, "-12345678901.23")

    # Complex rounding / precision
    # Pi to high precision
    var pi = 3.141592653589793
    sw = String()
    write_float[DType.float64](pi, sw)
    assert_equal(sw, "3.141592653589793")

    # Large values
    sw = String()
    write_float[DType.float64](Float64(1.7976931348623157e308), sw)
    assert_equal(sw, "1.7976931348623157e308")

    # Small values
    sw = String()
    write_float[DType.float64](Float64(2.2250738585072014e-308), sw)
    assert_equal(sw, "2.2250738585072014e-308")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
