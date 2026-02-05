from emberjson import JSON, Value, PointerIndex
from std.testing import assert_equal, assert_raises, assert_true, TestSuite


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

    assert_equal(j.get("").object()["foo"].array()[0].string(), "bar")

    assert_equal(j.get("/foo").array()[0].string(), "bar")
    assert_equal(j.get("/foo/0").string(), "bar")
    assert_equal(j.get("/").int(), 0)
    assert_equal(j.get("/a~1b").int(), 1)
    assert_equal(j.get("/c%d").int(), 2)
    assert_equal(j.get("/e^f").int(), 3)
    assert_equal(j.get("/g|h").int(), 4)
    assert_equal(j.get("/i\\j").int(), 5)
    assert_equal(j.get('/k"l').int(), 6)
    assert_equal(j.get("/ ").int(), 7)
    assert_equal(j.get("/m~0n").int(), 8)
    assert_equal(j.get("/0123").int(), 9)


def test_errors():
    var j = JSON(parse_string='{"a": 1}')

    with assert_raises():
        _ = j.get("a")  # No leading /

    with assert_raises():
        _ = j.get("/b")  # Missing key

    with assert_raises():
        _ = j.get("/a/0")  # Traversing primitive


def test_array_idx():
    var j = JSON(parse_string="[10, 20]")
    assert_equal(j.get("/0").int(), 10)
    assert_equal(j.get("/1").int(), 20)

    with assert_raises():
        _ = j.get("/2")  # OOB

    with assert_raises():
        _ = j.get("/-1")  # Negative

    with assert_raises():
        _ = j.get("/01")  # Leading zero


def test_explicit_pointer_index():
    # Verify that we can construct a PointerIndex explicitly and reuse it
    var ptr = PointerIndex("/foo/1")

    var j = JSON(parse_string='{"foo": ["bar", "baz"]}')
    ref val = j.get(ptr)
    assert_equal(val.string(), "baz")

    comptime ptr2 = PointerIndex.try_from_string("/foo/0")
    comptime assert ptr2 is not None
    assert_equal(j.get(materialize[ptr2]().value()).string(), "bar")


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


def test_unicode_keys():
    var j = JSON(
        parse_string='{"🔥": "fire", "🚀": "rocket", "key with spaces": 1}'
    )
    assert_equal(j.get("/🔥").string(), "fire")
    assert_equal(j.`🔥`.string(), "fire")
    assert_equal(j.get("/🚀").string(), "rocket")
    assert_equal(j.get("/key with spaces").int(), 1)
    assert_equal(j.`key with spaces`.int(), 1)


def test_value_sugar():
    # Test __getattr__ chaining on Value with mixed arrays/objects
    var j = JSON(
        parse_string=(
            '{"users": [{"name": "alice", "id": 1}, {"name": "bob", "id": 2}]}'
        )
    )

    # Read chain: JSON -> Value(Array) -> Value(Object) -> Value(String)
    # j.users returns ref Value(Array)
    # [0] returns ref Value(Object)
    # .name returns ref Value(String)
    assert_equal(j.users[0].name.string(), "alice")
    assert_equal(j.users[1].id.int(), 2)

    # Write chain
    j.users[0].name = "Alice Cooper"
    assert_equal(j.users[0].name.string(), "Alice Cooper")

    # Mixed with backtick syntax on intermediate Value
    # j.users[1] is a Value, we can use backticks on it
    assert_equal(j.users[1].`/name`.string(), "bob")

    # Write using backticks on intermediate Value
    j.users[1].`name` = "Bob Dylan"
    assert_equal(j.users[1].name.string(), "Bob Dylan")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
