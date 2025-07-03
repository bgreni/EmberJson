# from emberjson import RawValue, RawObject, RawArray, write_pretty
# from testing import (
#     assert_equal,
#     assert_true,
#     assert_raises,
#     assert_not_equal,
#     assert_almost_equal,
#     assert_false,
# )


# def test_bool():
#     var s: String = "false"
#     var v = RawValue(parse_string=s)
#     assert_true(v.is_bool())
#     assert_equal(v.bool(), False)
#     assert_equal(String(v), s)

#     s = "true"
#     v = RawValue(parse_string=s)
#     assert_true(v.is_bool())
#     assert_equal(v.bool(), True)
#     assert_equal(String(v), s)
#     assert_true(v.is_bool())


# def test_string():
#     var s: String = '"Some String"'
#     var v = RawValue(parse_string=s)
#     assert_true(v.is_string())
#     assert_equal(v.string(), "Some String")
#     assert_equal(String(v), s)

#     s = r"\uD801\uDC37"
#     v = RawValue(s)
#     assert_true(v.is_string())
#     assert_equal(v.string(), "𐐷")
#     assert_equal(v.as_string_slice(), s)
#     assert_true(v.is_string())

#     # check short string
#     s = '"s"'
#     v = RawValue(parse_string=s)
#     assert_equal(v.string(), "s")
#     assert_equal(String(v), s)

#     with assert_raises():
#         _ = RawValue(parse_string=r"Invalid unicode \u123z escape").string()

#     with assert_raises():
#         _ = RawValue(parse_string=r"Another invalid \uXYZG escape").string()

#     with assert_raises():
#         _ = RawValue(parse_string=r"Wrong format \u12Z4 escape").string()

#     with assert_raises():
#         _ = RawValue(parse_string=r"Wrong format \uFFFF escape").string()

#     with assert_raises():
#         _ = RawValue(parse_string=r"Incomplete escape \u12 escape").string()


# def test_null():
#     var s: String = "null"
#     var v = RawValue(parse_string=s)
#     assert_true(v.is_null())
#     assert_equal(String(v), s)

#     assert_true(RawValue(None).is_null())

#     with assert_raises():
#         _ = RawValue(parse_string="nil")


# def test_integer():
#     var v = RawValue(parse_string="123")
#     assert_true(v.is_int())
#     assert_equal(v.int(), 123)
#     assert_equal(String(v), "123")
#     assert_true(v.is_int())


# def test_integer_leading_plus():
#     var v = RawValue(parse_string="+123")
#     assert_true(v.is_int())
#     assert_equal(v.int(), 123)


# def test_integer_negative():
#     var v = RawValue(parse_string="-123")
#     assert_true(v.is_int())
#     assert_equal(v.int(), -123)
#     assert_equal(String(v), "-123")


# def test_float():
#     var v = RawValue(parse_string="43.5")
#     assert_true(v.is_float())
#     assert_almost_equal(v.float(), 43.5)
#     assert_equal(String(v), "43.5")


# def test_eight_digits_after_dot():
#     var v = RawValue(parse_string="342.12345678")
#     assert_true(v.is_float())
#     assert_almost_equal(v.float(), 342.12345678)
#     assert_equal(String(v), "342.12345678")


# def test_special_case_floats():
#     var v = RawValue(parse_string="2.2250738585072013e-308")
#     assert_almost_equal(v.float(), 2.2250738585072013e-308)
#     assert_true(v.is_float())

#     var v2 = RawValue(parse_string="7.2057594037927933e+16")
#     assert_true(v2.is_float())
#     assert_almost_equal(v2.float(), 7.2057594037927933e16)

#     var v3 = RawValue(parse_string="1e000000000000000000001")
#     assert_true(v3.is_float())
#     assert_almost_equal(v3.float(), 1e000000000000000000001)

#     var v4 = RawValue(
#         parse_string="3.1415926535897932384626433832795028841971693993751"
#     )
#     assert_true(v4.is_float())
#     assert_almost_equal(
#         v4.float(), 3.1415926535897932384626433832795028841971693993751
#     )

#     with assert_raises():
#         # This is "infinite"
#         _ = RawValue(
#             parse_string="10000000000000000000000000000000000000000000e+308"
#         ).float()

#     var v5 = RawValue(parse_string=String(Float64.MAX_FINITE))
#     assert_equal(v5.float(), Float64.MAX_FINITE)

#     var v6 = RawValue(parse_string=String(Float64.MIN_FINITE))
#     assert_equal(v6.float(), Float64.MIN_FINITE)


# def test_float_leading_plus():
#     var v = RawValue(parse_string="+43.5")
#     assert_true(v.is_float())
#     assert_almost_equal(v.float(), 43.5)


# def test_float_negative():
#     var v = RawValue(parse_string="-43.5")
#     assert_true(v.is_float())
#     assert_almost_equal(v.float(), -43.5)


# def test_float_exponent():
#     var v = RawValue(parse_string="43.5e10")
#     assert_true(v.is_float())
#     assert_almost_equal(v.float(), 43.5e10)


# def test_float_exponent_negative():
#     var v = RawValue(parse_string="-43.5e10")
#     assert_true(v.is_float())
#     assert_almost_equal(v.float(), -43.5e10)


# def test_equality():
#     var s = "34"
#     var v1 = RawValue(parse_string=s)
#     var v2 = RawValue("Some string")
#     var v3 = RawValue("Some string")
#     assert_equal(v2, v3)
#     assert_not_equal(v1, v2)

#     def eq_self(v: RawValue):
#         assert_equal(v, v)

#     eq_self(RawValue(parse_string="123"))
#     eq_self(RawValue(parse_string="34.5"))
#     eq_self(RawValue(parse_string="null"))
#     eq_self(RawValue(parse_string="false"))
#     eq_self(RawValue(RawArray[StaticConstantOrigin]()))
#     eq_self(RawValue(RawObject[StaticConstantOrigin]()))


# def test_pretty():
#     var v = RawValue(parse_string="[123, 43564, false]")
#     var expected: String = """[
#     123,
#     43564,
#     false
# ]"""
#     assert_equal(expected, write_pretty(v))

#     v = RawValue(parse_string='{"key": 123, "k2": null}')
#     expected = """{
#     "k2": null,
#     "key": 123
# }"""

#     assert_equal(expected, write_pretty(v))


# def test_booling():
#     var a = RawValue(parse_string="true")
#     assert_true(a)
#     if not a:
#         raise Error("Implicit bool failed")

#     var trues = RawArray(parse_string='["some string", 123, 3.43]')
#     var i = 0
#     for t in trues:
#         i += 1
#         assert_true(t[])

#     var falsies = RawArray(parse_string='["", 0, 0.0, false, null, null]')
#     for f in falsies:
#         assert_false(f[])
