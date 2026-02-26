from emberjson.schema import Range, Size, OneOf, Secret
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


def test_size_string():
    # Valid size
    var s1 = deserialize[Size[String, 3, 5]]('"abc"')
    assert_equal(s1.value, "abc")
    assert_equal(s1[], "abc")

    var s2 = deserialize[Size[String, 3, 5]]('"abcde"')
    assert_equal(s2.value, "abcde")

    # Too short
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[String, 3, 5]]('"ab"')

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[String, 3, 5]]('"abcdef"')


def test_size_list():
    # Valid size
    var l1 = deserialize[Size[List[Int], 1, 3]]("[1, 2]")
    assert_equal(len(l1.value), 2)
    assert_equal(l1.value[0], 1)

    # Empty (too short)
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[List[Int], 1, 3]]("[]")

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[List[Int], 1, 3]]("[1, 2, 3, 4]")


def test_one_of():
    # String options
    var o1 = deserialize[OneOf[String, "red", "green", "blue"]]('"red"')
    assert_equal(o1.value, "red")

    with assert_raises(contains="Value not in options"):
        _ = deserialize[OneOf[String, "red", "green", "blue"]]('"yellow"')

    # Int options
    var o2 = deserialize[OneOf[Int, 1, 2, 3]]("2")
    assert_equal(o2.value, 2)

    with assert_raises(contains="Value not in options"):
        _ = deserialize[OneOf[Int, 1, 2, 3]]("4")


def test_secret():
    # Deserialize normally
    var s1 = deserialize[Secret[String]]('"my_super_secret_password"')
    assert_equal(s1.value, "my_super_secret_password")
    assert_equal(s1[], "my_super_secret_password")

    # Serialize as masked
    assert_equal(serialize(s1), '"********"')

    var s2 = deserialize[Secret[Int]]("12345")
    assert_equal(s2.value, 12345)
    assert_equal(serialize(s2), '"********"')


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
