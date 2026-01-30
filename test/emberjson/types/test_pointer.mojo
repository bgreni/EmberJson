from emberjson import JSON, Value, PointerIndex
from testing import assert_equal, assert_raises, assert_true, TestSuite


def test_rfc6901():
    # RFC 6901 Example
    var json_str = String(
        "{"
        ' "foo": ["bar", "baz"],'
        ' "": 0,'
        ' "a/b": 1,'
        ' "c%d": 2,'
        ' "e^f": 3,'
        ' "g|h": 4,'
        ' "i\\\\j": 5,'
        ' "k\\"l": 6,'
        ' " ": 7,'
        ' "m~n": 8,'
        ' "0123": 9'
        "}"
    )
    var j = JSON(parse_string=json_str)

    with assert_raises():
        _ = j.pointer("")  # Cannot get ref to root JSON wrapper

    assert_equal(j.pointer("/foo").array()[0].string(), "bar")
    assert_equal(j.pointer("/foo/0").string(), "bar")
    assert_equal(j.pointer("/").int(), 0)
    assert_equal(j.pointer("/a~1b").int(), 1)
    assert_equal(j.pointer("/c%d").int(), 2)
    assert_equal(j.pointer("/e^f").int(), 3)
    assert_equal(j.pointer("/g|h").int(), 4)
    assert_equal(j.pointer("/i\\j").int(), 5)
    assert_equal(j.pointer('/k"l').int(), 6)
    assert_equal(j.pointer("/ ").int(), 7)
    assert_equal(j.pointer("/m~0n").int(), 8)
    assert_equal(j.pointer("/0123").int(), 9)


def test_errors():
    var j = JSON(parse_string='{"a": 1}')

    with assert_raises():
        _ = j.pointer("a")  # No leading /

    with assert_raises():
        _ = j.pointer("/b")  # Missing key

    with assert_raises():
        _ = j.pointer("/a/0")  # Traversing primitive


def test_array_idx():
    var j = JSON(parse_string="[10, 20]")
    assert_equal(j.pointer("/0").int(), 10)
    assert_equal(j.pointer("/1").int(), 20)

    with assert_raises():
        _ = j.pointer("/2")  # OOB

    with assert_raises():
        _ = j.pointer("/-1")  # Negative

    with assert_raises():
        _ = j.pointer("/01")  # Leading zero


def test_explicit_pointer_index():
    # Verify that we can construct a PointerIndex explicitly and reuse it
    var ptr = PointerIndex("/foo/1")

    var j = JSON(parse_string='{"foo": ["bar", "baz"]}')
    ref val = j.pointer(ptr)
    assert_equal(val.string(), "baz")

    comptime ptr2 = PointerIndex.try_from_string("/foo/0")
    __comptime_assert ptr2 is not None
    assert_equal(j.pointer(materialize[ptr2]().value()).string(), "bar")


def test_getattr_method():
    var j = JSON(parse_string='{"foo": {"bar": 1}}')
    assert_equal(j.`/foo/bar`, 1)

    j.`/foo` = [1, 2, 3]
    assert_equal(j.`/foo/0`, 1)
    assert_equal(j.`/foo/1`, 2)
    assert_equal(j.`/foo/2`, 3)

    j.foo = [4, 5, 6]
    assert_equal(j.`/foo/0`, 4)
    assert_equal(j.`/foo/1`, 5)
    assert_equal(j.`/foo/2`, 6)

    # adding a new key
    j.baz = False
    assert_equal(j.baz, False)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
