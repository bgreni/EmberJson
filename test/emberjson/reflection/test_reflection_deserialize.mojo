from testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
)
from emberjson._deserialize import (
    deserialize,
    try_deserialize,
    Parser,
    ParseOptions,
    StrictOptions,
)
from emberjson import JsonDeserializable
from std.collections import Set
from std.memory import ArcPointer, OwnedPointer


struct Foo[I: IntLiteral, F: FloatLiteral](Defaultable, Movable):
    var a: String
    var i: Int
    var f: Float64
    var i32: Int32
    var o: Optional[Int]
    var o2: Optional[Int]
    var b: Bool
    var bs: SIMD[DType.bool, 1]
    var li: List[Int]
    var tup: Tuple[Int, Int, Int]
    var ina: InlineArray[Float64, 3]
    var d: Dict[String, Int]
    var il: type_of(Self.I)
    var fl: type_of(Self.F)
    var vec: SIMD[DType.float32, 4]
    var set: Set[Int]
    var ap: ArcPointer[Int]
    var op: OwnedPointer[Int]

    fn __init__(out self):
        self.a = ""
        self.i = 0
        self.f = 0.0
        self.i32 = 0
        self.o = None
        self.o2 = None
        self.b = False
        self.bs = False
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


def test_deserialize():
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
    "bs": true,
    "li": [1, 2, 3],
    "d": {"some key": 12345},
    "il": 23,
    "fl": 234.23,
    "vec": [1.0, 2.0, 3.0, 4.0],
    "tup": [1, 2, 3],
    "ina": [1.0, 2.0, 3.0],
    "set": [1, 2, 3],
    "ap": 42,
    "op": 42
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
    assert_equal(foo.bs, True)
    var expected_dict = Dict[String, Int]()
    expected_dict["some key"] = 12345
    assert_equal(String(foo.d), String(expected_dict))
    assert_equal(foo.il, 23)
    assert_equal(foo.fl, 234.23)
    assert_equal(foo.vec, SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0))
    assert_true(foo.tup == (1, 2, 3))
    for i in range(3):
        assert_equal(foo.ina[i], Float64(i + 1))
    assert_equal(foo.set, {1, 2, 3})
    assert_equal(foo.ap[], 42)
    assert_equal(foo.op[], 42)


@fieldwise_init
struct Bar(Defaultable, Movable):
    var a: Int
    var b: Bool

    fn __init__(out self):
        self.a = 0
        self.b = False


def test_out_of_order_keys():
    var bar = deserialize[Bar]('{"b": false, "a": 10}')
    assert_equal(bar.a, 10)
    assert_equal(bar.b, False)


def test_ctime_deserialize():
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
    "bs": true,
    "li": [1, 2, 3],
    "d": {"some key": 12345},
    "il": 23,
    "fl": 234.23,
    "vec": [1.0, 2.0, 3.0, 4.0],
    "tup": [1, 2, 3],
    "ina": [1.0, 2.0, 3.0],
    "set": [1, 2, 3],
    "ap": 42,
    "op": 42
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
    assert_equal(foo.bs, True)
    var expected_dict2 = Dict[String, Int]()
    expected_dict2["some key"] = 12345
    assert_equal(String(foo.d), String(expected_dict2))
    assert_equal(foo.il, 23)
    assert_equal(foo.fl, 234.23)
    assert_equal(foo.vec, SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0))
    assert_true(foo.tup == (1, 2, 3))
    for i in range(3):
        assert_equal(foo.ina[i], Float64(i + 1))
    assert_equal(foo.set, {1, 2, 3})
    assert_equal(foo.ap[], 42)
    assert_equal(foo.op[], 42)


struct Baz(Movable):
    var a: Int
    var b: Int


def test_unexpected():
    with assert_raises():
        var b = deserialize[Baz]('{"c": 230}')


def test_unexpected_keys():
    with assert_raises():
        var foo = deserialize[Foo[23, 234.23]](
            """
{
    "extra_string": "should be ignored",
    "a": "hello",
    "extra_int": 42000,
    "i": 42,
    "f": 3.14,
    "i32": 23,
    "o": null,
    "o2": 1234,
    "b": true,
    "bs": true,
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
    "extra_bool": false
}
"""
        )


@fieldwise_init
struct Point(JsonDeserializable):
    var x: Int
    var y: Int

    @staticmethod
    fn deserialize_as_array() -> Bool:
        return True


def test_point_array_reflection():
    var json_str = "[1, 2]"
    var p = deserialize[Point](json_str)
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


@fieldwise_init
struct NestedArray(Defaultable, JsonDeserializable):
    var p: Point
    var name: String

    fn __init__(out self):
        self.p = Point(0, 0)
        self.name = ""

    @staticmethod
    fn deserialize_as_array() -> Bool:
        return True


def test_nested_array_reflection():
    var json_str = '[[10, 20], "test"]'
    var n = deserialize[NestedArray](json_str)
    assert_equal(n.p.x, 10)
    assert_equal(n.p.y, 20)
    assert_equal(n.name, "test")


@fieldwise_init
struct OptionalTest(Movable):
    var a: Int
    var b: Optional[Int]


def test_missing_optional():
    var json_str = '{"a": 1}'
    var o = deserialize[OptionalTest](json_str)
    assert_equal(o.a, 1)
    assert_false(o.b)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
