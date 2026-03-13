from std.testing import TestSuite, assert_equal, assert_true, assert_false
from emberjson import (
    deserialize,
    serialize,
    Value,
    Object,
    Array,
    Null,
    JSON,
)
from emberjson._serialize import PrettySerializer


@fieldwise_init
struct BuiltinTypes(Defaultable, Movable):
    var value: Value
    var obj: Object
    var arr: Array
    var null_val: Null

    def __init__(out self):
        self.value = Value()
        self.obj = Object()
        self.arr = Array()
        self.null_val = Null()


def test_builtin_reflection() raises:
    var o = Object()
    o["key"] = "val"
    var a = Array()
    a.append(1)
    a.append(True)

    var b = BuiltinTypes()
    b.value = Value(o.copy())
    b.obj = o^
    b.arr = a^
    b.null_val = Null()

    # Serialize
    var s = serialize(b)

    # Deserialize
    var b2 = deserialize[BuiltinTypes](s)

    # Verify
    assert_true(b2.value.is_object())
    assert_equal(b2.value.object()["key"].string(), "val")
    assert_equal(b2.obj["key"].string(), "val")
    assert_equal(len(b2.arr), 2)
    assert_equal(b2.arr[0].int(), 1)
    assert_true(b2.arr[1].bool())
    assert_true(b2.null_val == Null())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
