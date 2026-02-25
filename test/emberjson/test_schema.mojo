from emberjson.schema import Range
from emberjson import deserialize, serialize
from testing import assert_equal, assert_raises, TestSuite


def test_range_int():
    # Valid value
    var r1 = deserialize[Range[Int, 0, 10]]("5")
    assert_equal(r1.value, 5)

    # Boundary values
    var r2 = deserialize[Range[Int, 0, 10]]("0")
    assert_equal(r2.value, 0)

    var r3 = deserialize[Range[Int, 0, 10]]("10")
    assert_equal(r3.value, 10)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Int, 0, 10]]("-1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Int, 0, 10]]("11")


def test_range_float():
    # Valid value
    var r1 = deserialize[Range[Float64, 0.0, 1.0]]("0.5")
    assert_equal(r1.value, 0.5)

    # Boundary values
    var r2 = deserialize[Range[Float64, 0.0, 1.0]]("0.0")
    assert_equal(r2.value, 0.0)

    var r3 = deserialize[Range[Float64, 0.0, 1.0]]("1.0")
    assert_equal(r3.value, 1.0)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Float64, 0.0, 1.0]]("-0.1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Float64, 0.0, 1.0]]("1.1")


def test_range_serialization():
    var r = Range[Int, 0, 10](5)
    assert_equal(serialize(r), "5")

    var rf = Range[Float64, 0.0, 1.0](0.75)
    assert_equal(serialize(rf), "0.75")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
