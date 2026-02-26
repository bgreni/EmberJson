from emberjson.schema import (
    Range,
    Size,
    OneOf,
    Secret,
    Clamp,
    Coerce,
    CoerceInt,
    CoerceUInt,
    CoerceFloat,
    CoerceString,
    Default,
    Transform,
)
from emberjson import deserialize, serialize, Value
from testing import assert_equal, assert_raises, TestSuite


def test_range_int():
    # Valid value
    var r1 = deserialize[Range[Int, 0, 10]]("5")
    assert_equal(r1[], 5)

    # Boundary values
    var r2 = deserialize[Range[Int, 0, 10]]("0")
    assert_equal(r2[], 0)

    var r3 = deserialize[Range[Int, 0, 10]]("10")
    assert_equal(r3[], 10)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Int, 0, 10]]("-1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Int, 0, 10]]("11")


def test_range_float():
    # Valid value
    var r1 = deserialize[Range[Float64, 0.0, 1.0]]("0.5")
    assert_equal(r1[], 0.5)

    # Boundary values
    var r2 = deserialize[Range[Float64, 0.0, 1.0]]("0.0")
    assert_equal(r2[], 0.0)

    var r3 = deserialize[Range[Float64, 0.0, 1.0]]("1.0")
    assert_equal(r3[], 1.0)

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


def test_size_string():
    # Valid size
    var s1 = deserialize[Size[String, 3, 5]]('"abc"')
    assert_equal(s1[], "abc")

    var s2 = deserialize[Size[String, 3, 5]]('"abcde"')
    assert_equal(s2[], "abcde")

    # Too short
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[String, 3, 5]]('"ab"')

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[String, 3, 5]]('"abcdef"')


def test_size_list():
    # Valid size
    var l1 = deserialize[Size[List[Int], 1, 3]]("[1, 2]")
    assert_equal(len(l1[]), 2)
    assert_equal(l1[][0], 1)

    # Empty (too short)
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[List[Int], 1, 3]]("[]")

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[List[Int], 1, 3]]("[1, 2, 3, 4]")


def test_one_of():
    # String options
    var o1 = deserialize[OneOf[String, "red", "green", "blue"]]('"red"')
    assert_equal(o1[], "red")

    with assert_raises(contains="Value not in options"):
        _ = deserialize[OneOf[String, "red", "green", "blue"]]('"yellow"')

    # Int options
    var o2 = deserialize[OneOf[Int, 1, 2, 3]]("2")
    assert_equal(o2[], 2)

    with assert_raises(contains="Value not in options"):
        _ = deserialize[OneOf[Int, 1, 2, 3]]("4")


def test_secret():
    # Deserialize normally
    var s1 = deserialize[Secret[String]]('"my_super_secret_password"')
    assert_equal(s1[], "my_super_secret_password")

    # Serialize as masked
    assert_equal(serialize(s1), '"********"')

    var s2 = deserialize[Secret[Int]]("12345")
    assert_equal(s2[], 12345)
    assert_equal(serialize(s2), '"********"')


def test_clamp():
    # Valid value
    var c1 = deserialize[Clamp[Int, 0, 10]]("5")
    assert_equal(c1[], 5)

    # Too low is clamped to min
    var c2 = deserialize[Clamp[Int, 0, 10]]("-5")
    assert_equal(c2[], 0)

    # Too high is clamped to max
    var c3 = deserialize[Clamp[Int, 0, 10]]("15")
    assert_equal(c3[], 10)


fn coerce_int(v: Value) raises -> Int:
    if v.is_int():
        return Int(v.int())
    elif v.is_string():
        return Int(v.string())
    elif v.is_float():
        return Int(v.float())
    elif v.is_bool():
        return Int(v.bool())
    raise Error("Invalid value")


def test_coerce():
    var c1 = deserialize[Coerce[Int, coerce_int]]('"123"')
    assert_equal(c1[], 123)

    var c2 = deserialize[Coerce[Int, coerce_int]]("123.45")
    assert_equal(c2[], 123)

    var c3 = deserialize[Coerce[Int, coerce_int]]("true")
    assert_equal(c3[], 1)


def test_coerce_int():
    var c1 = deserialize[CoerceInt]('"123"')
    assert_equal(c1[], 123)

    var c2 = deserialize[CoerceInt]("123.45")
    assert_equal(c2[], 123)

    var c3 = deserialize[CoerceInt]("123")
    assert_equal(c3[], 123)

    var c4 = deserialize[CoerceInt]("0")
    assert_equal(c4[], 0)

    with assert_raises(contains="Value cannot be converted to an integer"):
        _ = deserialize[CoerceInt]("null")


def test_coerce_uint():
    var c1 = deserialize[CoerceUInt]('"123"')
    assert_equal(c1[], 123)

    var c2 = deserialize[CoerceUInt]("123.45")
    assert_equal(c2[], 123)

    var c3 = deserialize[CoerceUInt]("123")
    assert_equal(c3[], 123)

    with assert_raises(
        contains="Value cannot be converted to an unsigned integer"
    ):
        _ = deserialize[CoerceUInt]("null")


def test_coerce_float():
    var c1 = deserialize[CoerceFloat]('"123.45"')
    assert_equal(c1[], 123.45)

    var c2 = deserialize[CoerceFloat]("123")
    assert_equal(c2[], 123.0)

    var c3 = deserialize[CoerceFloat]("123.45")
    assert_equal(c3[], 123.45)

    with assert_raises(contains="Value cannot be converted to a float"):
        _ = deserialize[CoerceFloat]("null")


def test_coerce_string():
    var c1 = deserialize[CoerceString]('"123"')
    assert_equal(c1[], "123")

    var c2 = deserialize[CoerceString]("123.45")
    assert_equal(c2[], "123.45")

    var c3 = deserialize[CoerceString]("123")
    assert_equal(c3[], "123")

    var c4 = deserialize[CoerceString]("0")
    assert_equal(c4[], "0")

    with assert_raises(contains="Value cannot be converted to a string"):
        _ = deserialize[CoerceString]("null")


struct TestDefault(Movable):
    var a: Int
    var b: Default[Int, 42]


def test_default():
    var d1 = deserialize[Default[Int, 42]]("10")
    assert_equal(d1[], 10)

    var d2 = deserialize[Default[Int, 42]]("null")
    assert_equal(d2[], 42)

    var d3 = deserialize[TestDefault]('{"a": 10}')
    assert_equal(d3.a, 10)
    assert_equal(d3.b[], 42)


fn date_to_int(s: String) -> Int:
    if s == "2024-01-01":
        return 1
    return 0


def test_transform():
    var t1 = deserialize[Transform[String, Int, date_to_int]]('"2024-01-01"')
    assert_equal(t1[], 1)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
