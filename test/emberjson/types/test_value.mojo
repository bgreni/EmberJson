from emberjson.value import Value, Null
from emberjson import Object, Array, JSON, write_pretty
from testing import (
    assert_equal,
    assert_true,
    assert_raises,
    assert_not_equal,
    assert_almost_equal,
    assert_false,
    TestSuite,
)


def test_nested_access():
    var nested: Value = {"key": [True, None, {"inner2": False}]}

    assert_equal(nested["key"][2]["inner2"].bool(), False)


def test_bool():
    var s: String = "false"
    var v = Value(parse_string=s)
    assert_true(v.is_bool())
    assert_equal(v.bool(), False)
    assert_equal(String(v), s)

    s = "true"
    v = Value(parse_string=s)
    assert_true(v.is_bool())
    assert_equal(v.bool(), True)
    assert_equal(String(v), s)


def test_string():
    var s: String = '"Some String"'
    var v = Value(parse_string=s)
    assert_true(v.is_string())
    assert_equal(v.string(), "Some String")
    assert_equal(String(v), s)

    s = '"Escaped"'
    v = Value(parse_string=s)
    assert_true(v.is_string())
    assert_equal(v.string(), "Escaped")
    assert_equal(String(v), s)

    # check short string
    s = '"s"'
    v = Value(parse_string=s)
    assert_equal(v.string(), "s")
    assert_equal(String(v), s)

    with assert_raises():
        _ = Value(parse_string=r"Invalid unicode \u123z escape")

    with assert_raises():
        _ = Value(parse_string=r"Another invalid \uXYZG escape")

    with assert_raises():
        _ = Value(parse_string=r"Wrong format \u12Z4 escape")

    with assert_raises():
        _ = Value(parse_string=r"Wrong format \uFFFF escape")

    with assert_raises():
        _ = Value(parse_string=r"Incomplete escape \u12 escape")


def test_null():
    var s: String = "null"
    var v = Value(parse_string=s)
    assert_true(v.is_null())
    assert_equal(v.null(), Null())
    assert_equal(String(v), s)

    assert_true(Value(None).is_null())

    with assert_raises(contains="Expected 'null'"):
        _ = Value(parse_string="nil")


def test_integer():
    var v = Value(parse_string="123")
    assert_true(v.is_int())
    assert_equal(v.int(), 123)
    assert_equal(v.uint(), 123)
    assert_equal(String(v), "123")
    assert_true(v.is_int())

    # test to make signed vs unsigned comparisons work
    assert_equal(Value(Int64(123)), Value(UInt64(123)))
    assert_equal(Value(UInt64(123)), Value(Int64(123)))
    assert_not_equal(Value(Int64(125)), Value(UInt64(123)))
    assert_not_equal(Value(UInt64(125)), Value(Int64(123)))
    assert_not_equal(Value(UInt64(Int64.MAX) + 10), Int64.MAX)
    assert_not_equal(Value(-123), Value(UInt64(123)))


def test_integer_leading_plus():
    var v = Value(parse_string="+123")
    assert_true(v.is_int())
    assert_equal(v.int(), 123)
    assert_equal(v.uint(), 123)


def test_integer_negative():
    var v = Value(parse_string="-123")
    assert_true(v.is_int())
    assert_equal(v.int(), -123)
    assert_equal(String(v), "-123")


def test_signed_overflow_to_unsigned():
    var n = UInt64(Int64.MAX) + 100
    var v = Value(parse_string=String(n))
    assert_true(v.is_uint())
    assert_equal(v.uint(), n)
    assert_equal(String(v), String(n))


def test_float():
    var v = Value(parse_string="43.5")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), 43.5)
    assert_equal(String(v), "43.5")
    assert_true(v.is_float())


def test_eight_digits_after_dot():
    var v = Value(parse_string="342.12345678")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), 342.12345678)
    assert_equal(String(v), "342.12345678")


def test_special_case_floats():
    var v = Value(parse_string="2.2250738585072013e-308")
    assert_almost_equal(v.float(), 2.2250738585072013e-308)
    assert_true(v.is_float())

    v = Value(parse_string="7.2057594037927933e+16")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), 7.2057594037927933e16)

    v = Value(parse_string="1e000000000000000000001")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), 1e000000000000000000001)

    v = Value(
        parse_string="3.1415926535897932384626433832795028841971693993751"
    )
    assert_true(v.is_float())
    assert_almost_equal(
        v.float(), 3.1415926535897932384626433832795028841971693993751
    )

    with assert_raises():
        # This is "infinite"
        _ = Value(
            parse_string="10000000000000000000000000000000000000000000e+308"
        )

    v = Value(parse_string=String(Float64.MAX_FINITE))
    assert_equal(v.float(), Float64.MAX_FINITE)

    v = Value(parse_string=String(Float64.MIN_FINITE))
    assert_equal(v.float(), Float64.MIN_FINITE)


def test_float_leading_plus():
    var v = Value(parse_string="+43.5")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), 43.5)


def test_float_negative():
    var v = Value(parse_string="-43.5")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), -43.5)


def test_float_exponent():
    var v = Value(parse_string="43.5e10")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), 43.5e10)


def test_float_exponent_negative():
    var v = Value(parse_string="-43.5e10")
    assert_true(v.is_float())
    assert_almost_equal(v.float(), -43.5e10)


def test_equality():
    var v1 = Value(34)
    var v2 = Value("Some string")
    var v3 = Value("Some string")
    assert_equal(v2, v3)
    assert_not_equal(v1, v2)

    def eq_self(v: Value):
        assert_equal(v, v)

    eq_self(Value(123))
    eq_self(Value(34.5))
    eq_self(Value(Null()))
    eq_self(Value(False))
    eq_self(Value(Array()))
    eq_self(Value(Object()))


def test_implicit_conversion():
    var val: Value = "a string"
    assert_equal(val.string(), "a string")
    val = 100
    assert_equal(val.int(), 100)
    val = False
    assert_false(val.bool())
    val = 1e10
    assert_almost_equal(val.float(), 1e10)
    val = Null()
    assert_equal(val.null(), Null())
    val = Object()
    assert_equal(val.object(), Object())
    val = Array(1, 2, 3)
    assert_equal(val.array(), Array(1, 2, 3))


def test_pretty():
    var v = Value(parse_string="[123, 43564, false]")
    var expected: String = """[
    123,
    43564,
    false
]"""
    assert_equal(expected, write_pretty(v))

    v = Value(parse_string='{"key": 123, "k2": null}')
    expected = """{
    "k2": null,
    "key": 123
}"""

    assert_equal(expected, write_pretty(v))


def test_booling():
    var a: Value = True
    assert_true(a)
    if not a:
        raise Error("Implicit bool failed")

    var trues = Array("some string", 123, 3.43)
    for t in trues:
        assert_true(t)

    var falsies = Array("", 0, 0.0, False, Null(), None)
    for f in falsies:
        assert_false(f)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
