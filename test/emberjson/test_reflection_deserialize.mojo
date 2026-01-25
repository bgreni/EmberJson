from testing import TestSuite, assert_equal, assert_false
from emberjson._deserialize import deserialize, try_deserialize


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
    # var ina: InlineArray[Float64, 3]
    var d: Dict[String, Int]
    var il: type_of(Self.I)
    var fl: type_of(Self.F)
    var vec: SIMD[DType.float32, 4]

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
        self.d = {}
        self.il = {}
        self.fl = {}
        self.vec = {}
        # self.ina = InlineArray[Float64, 3](uninitialized=True)


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
    "vec": [1.0, 2.0, 3.0, 4.0]
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
    assert_equal(foo.li, [1, 2, 3])
    assert_equal(String(foo.d), String({"some key": 12345}))
    assert_equal(foo.il, 23)
    assert_equal(foo.fl, 234.23)
    assert_equal(foo.vec, SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0))


@fieldwise_init
struct Bar(Defaultable, Movable):
    var a: Int
    var b: Bool

    fn __init__(out self):
        self.a = 0
        self.b = False


def test_out_of_order_keys():
    var bar = deserialize[Bar]('{"b": false, "a": 10}')


# Crashing?
# def test_ctime_deserialize():
#     comptime foo_ctime = try_deserialize[Foo[23, 234.23]](
#         """
# {
#     "a": "hello",
#     "i": 42,
#     "f": 3.14,
#     "i32": 23,
#     "o": null,
#     "o2": 1234,
#     "b": true,
#     "bs": true,
#     "li": [1, 2, 3],
#     "d": {"some key": 12345},
#     "il": 23,
#     "fl": 234.23,
#     "vec": [1.0, 2.0, 3.0, 4.0]
# }
# """
#     )

#     var foo = materialize[foo_ctime.value()]()

#     print(foo.li)

#     assert_equal(foo.a, "hello")
#     assert_equal(foo.i, 42)
#     assert_equal(foo.f, 3.14)
#     assert_equal(foo.i32, 23)
#     assert_false(foo.o)
#     assert_equal(foo.o2.value(), 1234)
#     assert_equal(foo.b, True)
#     assert_equal(foo.bs, True)
#     assert_equal(foo.li, [1, 2, 3])
#     assert_equal(String(foo.d), String({"some key": 12345}))
#     assert_equal(foo.il, 23)
#     assert_equal(foo.fl, 234.23)
#     assert_equal(foo.vec, SIMD[DType.float32, 4](1.0, 2.0, 3.0, 4.0))


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
