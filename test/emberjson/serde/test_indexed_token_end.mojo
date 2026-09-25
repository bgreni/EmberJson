# A scalar with garbage glued to its end (`12x`, `truex`, `nullnull`) must be
# rejected on every reflection path, exactly as the byte-walk rejects it.
# Stage 1 indexes only where a scalar starts, so any path that lets a `Parser`
# consume the scalar and then skips ahead in the index must check the token
# end itself: unknown-field skips, `Value`/`Null` targets and `Lazy` captures.

from std.testing import assert_raises, TestSuite
from emberjson import from_json, Value, Null
from emberjson.lazy import LazyInt


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Float64

    def __init__(out self):
        self.x = 0
        self.y = 0.0


@fieldwise_init
struct WithVal(Defaultable, Movable):
    var a: Int
    var v: Value

    def __init__(out self):
        self.a = 0
        self.v = Value()


@fieldwise_init
struct WithLazy[o: ImmOrigin](Movable):
    var a: LazyInt[Self.o]
    var b: Int


def test_unknown_field_scalar_with_glued_garbage() raises:
    with assert_raises():
        _ = from_json[Point]('{"x":1,"y":2,"z":12x}')
    with assert_raises():
        _ = from_json[Point]('{"x":1,"y":2,"z":truex}')
    with assert_raises():
        _ = from_json[Point]('{"z":1.5.3,"x":1,"y":2}')


def test_value_element_with_glued_garbage() raises:
    with assert_raises():
        _ = from_json[List[Value]]("[12x]")
    with assert_raises():
        _ = from_json[List[Value]]("[1-2]")
    with assert_raises():
        _ = from_json[List[Value]]("[nullnull]")
    with assert_raises():
        _ = from_json[WithVal]('{"a":1,"v":12x}')


def test_null_root_with_glued_garbage() raises:
    with assert_raises():
        _ = from_json[Null]("nullx")


def test_lazy_field_with_glued_garbage() raises:
    var s = String('{"a":12x,"b":1}')
    with assert_raises():
        _ = from_json[WithLazy[origin_of(s)]](s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
