from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
)

# Ported in Task 8 from the deleted `Parser`-driven reflection walker to
# the public (emberserde-backed) entry points. Same inputs, same
# expectations, except where called out below.
from emberjson import deserialize, try_deserialize
from emberserde import DenyUnknownFields
from std.collections import Set, Array as StdArray
from std.memory import ArcPointer, OwnedPointer
from emberjson import Value, Object, Array, Null


struct Foo[I: IntLiteral, F: FloatLiteral](Defaultable, Movable):
    var a: String
    var i: Int
    var f: Float64
    var i32: Int32
    var o: Optional[Int]
    var o2: Optional[Int]
    var b: Bool
    var li: List[Int]
    var tup: Tuple[Int, Int, Int]
    var ina: StdArray[Float64, 3]
    var d: Dict[String, Int]
    var il: type_of(Self.I)
    var fl: type_of(Self.F)
    var vec: SIMD[DType.float32, 4]
    var set: Set[Int]
    var ap: ArcPointer[Int]
    var op: OwnedPointer[Int]
    var v: Value
    var obj: Object
    var arr: Array
    var n: Null

    def __init__(out self):
        self.a = ""
        self.i = 0
        self.f = 0.0
        self.i32 = 0
        self.o = None
        self.o2 = None
        self.b = False
        self.li = []
        self.tup = (0, 0, 0)
        self.ina = [0.0, 0.0, 0.0]
        self.d = {}
        self.il = {}
        self.fl = {}
        self.vec = SIMD[DType.float32, 4](0.0, 0.0, 0.0, 0.0)
        self.set = {}
        self.ap = ArcPointer[Int](0)
        self.op = OwnedPointer[Int](0)
        self.v = None
        self.obj = Object()
        self.arr = Array()
        self.n = Null()


def test_deserialize() raises:
    var foo = deserialize[Foo[23, 234.23]](
        """
{
    "a": "hello",
    "i": 42, 
    "f": 3.14,
    "i32": 23,
    "o": null,
    "o2": 1234,
    "b": true,
    "li": [1, 2, 3],
    "d": {"some key": 12345},
    "il": 23,
    "fl": 234.23,
    "vec": [1.0, 2.0, 3.0, 4.0],
    "tup": [1, 2, 3],
    "ina": [1.0, 2.0, 3.0],
    "set": [1, 2, 3],
    "ap": 42,
    "op": 42,
    "v": {"variant": "test"},
    "obj": {"key": 123},
    "arr": [1, 2, "three"],
    "n": null
}
"""
    )
    assert_equal(foo.a, "hello")
    assert_equal(foo.i, 42)
    assert_equal(foo.f, 3.14)
    assert_equal(foo.i32, 23)
    assert_false(foo.o)
    assert_equal(foo.o2.value(), 1234)
    assert_equal(foo.b, True)
    assert_equal(foo.li, [1, 2, 3])
    var d = {"some key": 12345}
    assert_equal(String(foo.d), String(d))
    assert_equal(foo.il, 23)
    assert_equal(foo.fl, 234.23)
    assert_equal(foo.vec, SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0))
    assert_true(foo.tup == (1, 2, 3))
    for i in range(3):
        assert_equal(foo.ina[i], Float64(i + 1))
    assert_equal(foo.set, {1, 2, 3})
    assert_equal(foo.ap[], 42)
    assert_equal(foo.op[], 42)
    assert_equal(foo.v["variant"].string(), "test")
    assert_equal(foo.obj["key"].int(), 123)
    assert_equal(foo.arr[0].int(), 1)
    assert_equal(foo.arr[2].string(), "three")
    assert_false(foo.n)


@fieldwise_init
struct Bar(Defaultable, Movable):
    var a: Int
    var b: Bool

    def __init__(out self):
        self.a = 0
        self.b = False


def test_out_of_order_keys() raises:
    var bar = deserialize[Bar]('{"b": false, "a": 10}')
    assert_equal(bar.a, 10)
    assert_equal(bar.b, False)


def test_ctime_deserialize() raises:
    comptime foo_ctime = try_deserialize[Foo[23, 234.23]](
        """
{
    "a": "hello",
    "i": 42,
    "f": 3.14,
    "i32": 23,
    "o": null,
    "o2": 1234,
    "b": true,
    "li": [1, 2, 3],
    "d": {"some key": 12345},
    "il": 23,
    "fl": 234.23,
    "vec": [1.0, 2.0, 3.0, 4.0],
    "tup": [1, 2, 3],
    "ina": [1.0, 2.0, 3.0],
    "set": [1, 2, 3],
    "ap": 42,
    "op": 42,
    "v": {"variant": "test"},
    "obj": {"key": 123},
    "arr": [1, 2, "three"],
    "n": null
}
"""
    )

    comptime assert Bool(foo_ctime)

    var foo = materialize[foo_ctime.value()]()

    assert_equal(foo.a, "hello")
    assert_equal(foo.i, 42)
    assert_equal(foo.f, 3.14)
    assert_equal(foo.i32, 23)
    assert_false(foo.o)
    assert_equal(foo.o2.value(), 1234)
    assert_equal(foo.b, True)
    assert_equal(foo.li, [1, 2, 3])
    var d = {"some key": 12345}
    assert_equal(String(foo.d), String(d))
    assert_equal(foo.il, 23)
    assert_equal(foo.fl, 234.23)
    assert_equal(foo.vec, SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0))
    assert_true(foo.tup == (1, 2, 3))
    for i in range(3):
        assert_equal(foo.ina[i], Float64(i + 1))
    assert_equal(foo.set, {1, 2, 3})
    assert_equal(foo.ap[], 42)
    assert_equal(foo.op[], 42)
    assert_equal(foo.v["variant"].string(), "test")
    assert_equal(foo.obj["key"].int(), 123)
    assert_equal(foo.arr[0].int(), 1)
    assert_equal(foo.arr[2].string(), "three")
    assert_false(foo.n)


struct Baz(Movable):
    var a: Int
    var b: Int


def test_unexpected() raises:
    # Still raises, but for a different reason than it used to: the
    # unbound `"c"` is now skipped (see `test_unexpected_keys` below) and
    # what fails is `Baz.a`/`Baz.b` being missing.
    with assert_raises():
        var b = deserialize[Baz]('{"c": 230}')


@fieldwise_init
struct StrictBaz(DenyUnknownFields, Movable):
    var a: Int
    var b: Int


def test_unexpected_key_rejected_under_deny_unknown_fields() raises:
    # The opt-in that recovers the old always-reject behavior.
    with assert_raises(contains="Unknown field"):
        _ = deserialize[StrictBaz]('{"a": 1, "b": 2, "c": 230}')


def test_unexpected_keys() raises:
    # BEHAVIOR CHANGE (Task 8). This used to assert that ANY wire key with
    # no matching field is rejected -- the deleted walker's
    # `raise Error("Unexpected field: ", ...)`. emberserde's `expect_struct`
    # skips an unbound key unless the target type conforms to
    # `DenyUnknownFields` (see the test above), so the same input now
    # deserializes cleanly and every declared field still binds correctly.
    # The three `extra_*` keys below (scalar, array-with-nested-object, and
    # deeply nested object) are kept because skipping them exercises
    # `skip_value` over exactly the shapes that are hardest to skip.
    var foo = _deserialize_with_extras()
    assert_equal(foo.a, "hello")
    assert_equal(foo.i, 42)
    assert_equal(foo.o2.value(), 1234)
    assert_equal(foo.li, [1, 2, 3])
    assert_equal(foo.set, {1, 2, 3})
    assert_equal(foo.arr[2].string(), "three")


def _deserialize_with_extras() raises -> Foo[23, 234.23]:
    return deserialize[Foo[23, 234.23]](
        """
{
    "a": "hello",
    "extra_int": 42000,
    "i": 42,
    "f": 3.14,
    "i32": 23,
    "o": null,
    "o2": 1234,
    "b": true,
    "li": [1, 2, 3],
    "extra_array": [1, 2, 3, {"nested": "keys"}],
    "d": {"some key": 12345},
    "il": 23,
    "fl": 234.23,
    "vec": [1.0, 2.0, 3.0, 4.0],
    "tup": [1, 2, 3],
    "ina": [1.0, 2.0, 3.0],
    "set": [1, 2, 3],
    "ap": 42,
    "extra_object": {
        "depth": {
             "still": "ignored"
        }
    },
    "op": 42,
    "v": {"variant": "test"},
    "obj": {"key": 123},
    "arr": [1, 2, "three"],
    "n": null,
    "extra_bool": false
}
"""
    )


# REMOVED IN TASK 8: `test_point_array_reflection` and
# `test_nested_array_reflection`, plus their `Point`/`NestedArray`
# fixtures. Both pinned `JsonDeserializable.deserialize_as_array` -- an
# opt-in that made a struct read from `[1, 2]` instead of `{"x":1,"y":2}`.
# It lived only on the deleted trait and has no emberserde counterpart: a
# struct always rides the wire as a JSON object. See the task-8 report.


@fieldwise_init
struct OptionalTest(Movable):
    var a: Int
    var b: Optional[Int]


def test_missing_optional() raises:
    var json_str = '{"a": 1}'
    var o = deserialize[OptionalTest](json_str)
    assert_equal(o.a, 1)
    assert_false(o.b)


struct LongInts(Movable):
    var i128: Scalar[DType.int128]
    var i256: Scalar[DType.int256]
    var u128: Scalar[DType.uint128]
    var u256: Scalar[DType.uint256]


def test_long_ints() raises:
    var s = (
        '{"i128": -170141183460469231731687303715884105728, "i256":'
        " 57896044618658097711785492504343953926634992332820282019728792003956564819967,"
        ' "u128": 340282366920938463463374607431768211455, "u256":'
        " 115792089237316195423570985008687907853269984665640564039457584007913129639935}"
    )
    var vals = deserialize[LongInts](s)

    assert_equal(vals.i128, Scalar[DType.int128].MIN)
    assert_equal(vals.i256, Scalar[DType.int256].MAX)
    assert_equal(vals.u128, Scalar[DType.uint128].MAX)
    assert_equal(vals.u256, Scalar[DType.uint256].MAX)


# ===========================================================================
# REGRESSION PIN (Task 8). `Foo` used to carry a `bs: SIMD[DType.bool, 1]`
# field read from the wire token `true`: the deleted walker's
# `__extension SIMD(JsonDeserializable)` had a non-numeric-dtype branch
# (`Scalar[dtype](Int(p.expect_bool()))`) for exactly that. emberserde's
# `SIMD.deserialize`
# (`emberserde/emberserde/deserialize/impls.mojo:32-45`) has no such
# branch -- it always goes through `expect_number` -- so a boolean-dtype
# SIMD now reads a JSON *number* and rejects a JSON *boolean*.
#
# The field is gone from `Foo` because there is no way to keep it passing;
# this pins the actual behavior instead, so the day emberserde grows the
# branch this test fails loudly rather than the gap staying invisible.
# `Bool` itself is unaffected -- only `SIMD[DType.bool, N]`.
# ===========================================================================


def test_simd_bool_reads_a_number_not_a_json_boolean() raises:
    assert_false(Bool(try_deserialize[SIMD[DType.bool, 1]]("true")))
    var from_number = deserialize[SIMD[DType.bool, 1]]("1")
    assert_true(Bool(from_number))

    # The plain `Bool` path still reads `true`, as it always did.
    assert_true(deserialize[Bool]("true"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
