from testing import TestSuite, assert_equal, assert_false
from emberjson._deserialize import deserialize


struct Foo(Defaultable, Movable):
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
        # self.ina = InlineArray[Float64, 3](uninitialized=True)


def test_deserialize():
    var foo = deserialize[Foo](
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
    "li": [1, 2, 3]
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


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
