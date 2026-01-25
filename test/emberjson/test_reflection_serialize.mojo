from testing import TestSuite, assert_equal
from emberjson._serialize import serialize, JsonSerializable


@fieldwise_init
struct Bar(Copyable):
    var b: Int


@fieldwise_init
struct Foo[I: IntLiteral, F: FloatLiteral]:
    var f: Int
    var s: String
    var o: Optional[Int]
    var bar: Bar
    var i: Int32
    var vec: SIMD[DType.float64, 2]
    var l: List[Int]
    var arr: InlineArray[Bool, 3]
    var dic: Dict[String, Int]
    var il: type_of(Self.I)
    var fl: type_of(Self.F)


@fieldwise_init
struct Baz(JsonSerializable):
    var a: Bool
    var b: Int
    var c: String

    @staticmethod
    fn serialize_as_array() -> Bool:
        return True


def test_serialize():
    var f = Foo[45, 7.43](
        1,
        "something",
        10,
        Bar(20),
        23,
        [2.32, 5.345],
        [32, 42, 353],
        [False, True, True],
        {"a key": 1234},
        {},
        {},
    )

    assert_equal(
        serialize(f),
        (
            '{"f":1,"s":"something","o":10,"bar":{"b":20},"i":23,"vec":[2.32,5.345],"l":[32,42,353],"arr":[false,true,true],"dic":{"a'
            ' key":1234},"il":45,"fl":7.43}'
        ),
    )


def test_ctime_serialize():
    comptime f = Foo[45, 7.43](
        1,
        "something",
        10,
        Bar(20),
        23,
        [2.32, 5.345],
        [32, 42, 353],
        [False, True, True],
        {"a key": 1234},
        {},
        {},
    )

    comptime serialized = serialize(f)

    assert_equal(
        serialized,
        (
            '{"f":1,"s":"something","o":10,"bar":{"b":20},"i":23,"vec":[2.32,5.345],"l":[32,42,353],"arr":[false,true,true],"dic":{"a'
            ' key":1234},"il":45,"fl":7.43}'
        ),
    )


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
