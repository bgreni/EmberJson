from emberjson._deserialize.parser import Parser, ParseOptions
from emberjson import JSON, Null, Array, Object, parse
from testing import assert_true, assert_equal, assert_raises, TestSuite


def test_parse():
    var s: String = '{"key": 123}'
    var p = Parser(s)
    var json = p.parse()
    assert_true(json.is_object())
    assert_equal(json.object()["key"].int(), 123)
    assert_equal(json.object()["key"].int(), 123)

    assert_equal(String(json), '{"key":123}')

    assert_equal(len(json), 1)

    s = "[123, 345]"
    json = parse(s)
    assert_true(json.is_array())
    assert_equal(json.array()[0].int(), 123)
    assert_equal(json.array()[1].int(), 345)
    assert_equal(json.array()[0].int(), 123)

    assert_equal(String(json), "[123,345]")

    assert_equal(len(json.array()), 2)


def test_parse_utf16_surrogates():
    var s: String = r'{"key": "To decode U+10437 (\uD801\uDC37) from UTF-16:"}'
    var p = Parser(s)
    var json = p.parse()
    assert_true(json.is_object())
    assert_true(json.object()["key"].isa[String]())
    assert_equal(
        json.object()["key"].string(), "To decode U+10437 (𐐷) from UTF-16:"
    )

    var s2: String = r'{"\uD801\uDC37": "\uD801\uDC37"}'
    var p2 = Parser(s2)
    var json2 = p2.parse()
    assert_true(json2.is_object())
    assert_true(json2.object()["𐐷"].isa[String]())
    assert_equal(json2.object()["𐐷"].string(), "𐐷")


def test_parse_escaped_strings():
    # Quotes
    var s_quote = r'{"key": "foo \"bar\""}'
    var json_quote = parse(s_quote)
    assert_equal(json_quote.object()["key"].string(), 'foo "bar"')

    # Backslash
    var s_bs = r'{"key": "foo \\ bar"}'
    var json_bs = parse(s_bs)
    assert_equal(json_bs.object()["key"].string(), "foo \\ bar")

    # Forward slash
    var s_fs = r'{"key": "foo \/ bar"}'
    var json_fs = parse(s_fs)
    assert_equal(json_fs.object()["key"].string(), "foo / bar")

    # Controls
    var s_b = r'{"key": "foo \b bar"}'
    var json_b = parse(s_b)
    assert_equal(json_b.object()["key"].string(), "foo \b bar")

    var s_f = r'{"key": "foo \f bar"}'
    var json_f = parse(s_f)
    assert_equal(json_f.object()["key"].string(), "foo \f bar")

    var s_n = r'{"key": "foo \n bar"}'
    var json_n = parse(s_n)
    assert_equal(json_n.object()["key"].string(), "foo \n bar")

    var s_r = r'{"key": "foo \r bar"}'
    var json_r = parse(s_r)
    assert_equal(json_r.object()["key"].string(), "foo \r bar")

    var s_t = r'{"key": "foo \t bar"}'
    var json_t = parse(s_t)
    assert_equal(json_t.object()["key"].string(), "foo \t bar")

    # Null byte \u0000
    var s_null = r'{"key": "foo \u0000 bar"}'
    var json_null = parse(s_null)
    # Construct expected string with null byte manually
    var expected_null = String("foo ")
    expected_null.append(Codepoint(0))
    expected_null += " bar"
    assert_equal(json_null.object()["key"].string(), expected_null)


def test_parse_wrong_backslash():
    var data = List('{"key": "This should raise and not segfault:'.as_bytes())
    data.append(Byte(ord("\\")))
    with assert_raises():
        var p = Parser(Span(data))
        _ = p.parse()
    data.append(Byte(ord("u")))
    with assert_raises():
        var p = Parser(Span(data))
        _ = p.parse()
    data.extend("D801".as_bytes())
    with assert_raises():
        var p = Parser(Span(data))
        _ = p.parse()
    data.append(Byte(ord("\\")))
    with assert_raises():
        var p = Parser(Span(data))
        _ = p.parse()
    data.append(Byte(ord("u")))
    with assert_raises():
        var p = Parser(Span(data))
        _ = p.parse()
    data.extend("D801".as_bytes())
    with assert_raises():
        var p = Parser(Span(data))
        _ = p.parse()

    var data2 = List('{"key": '.as_bytes())
    data2.append(Byte(ord("\\")))
    data2.extend('"this should not be correct"}'.as_bytes())
    var p2 = Parser(Span(data2))
    with assert_raises():
        _ = p2.parse()


def test_integer_strict_overflow():
    # Int8 max is 127
    var s_ok = "127"
    var p_ok = Parser(s_ok)
    assert_equal(p_ok.expect_integer[DType.int8](), 127)

    var s_overflow = "128"
    var p_over = Parser(s_overflow)
    with assert_raises():
        _ = p_over.expect_integer[DType.int8]()

    # Int8 min is -128
    var s_min = "-128"
    var p_min = Parser(s_min)
    assert_equal(p_min.expect_integer[DType.int8](), -128)

    var s_under = "-129"
    var p_under = Parser(s_under)
    with assert_raises():
        _ = p_under.expect_integer[DType.int8]()


def test_unsigned_strict_overflow():
    # UInt8 max is 255
    var s_ok = "255"
    var p_ok = Parser(s_ok)
    assert_equal(p_ok.expect_unsigned_integer[DType.uint8](), 255)

    var s_over = "256"
    var p_over = Parser(s_over)
    with assert_raises():
        _ = p_over.expect_unsigned_integer[DType.uint8]()

    # Negative should fail
    var s_neg = "-5"
    var p_neg = Parser(s_neg)
    with assert_raises():
        _ = p_neg.expect_unsigned_integer[DType.uint8]()


def test_float_conversions():
    # Float32 should parse
    var s = "42.5"
    var p = Parser(s)
    assert_equal(p.expect_float[DType.float32](), 42.5)

    # Int syntax as float
    var s_int = "100"
    var p_int = Parser(s_int)
    assert_equal(p_int.expect_float[DType.float32](), 100.0)

    # Casting check for float might be tricky due to precision,
    # but huge number to float16 might overflow to inf?
    # Float16 max is ~65504
    var s_huge = "100000.0"
    var p_huge = Parser(s_huge)
    with assert_raises():  # Expect overflow for float16
        _ = p_huge.expect_float[DType.float16]()


def test_integer_edge_cases():
    # Leading zeros are invalid (except for just "0")
    var p_01 = Parser("01")
    with assert_raises():
        _ = p_01.expect_integer()

    # "0" is valid
    var p_0 = Parser("0")
    assert_equal(p_0.expect_integer(), 0)

    # "-0" is valid and should be 0
    var p_neg0 = Parser("-0")
    assert_equal(p_neg0.expect_integer(), 0)

    # 64-bit boundaries
    # Int64 Max: 9223372036854775807
    var s_max = "9223372036854775807"
    var p_max = Parser(s_max)
    assert_equal(p_max.expect_integer(), 9223372036854775807)

    # Int64 Min: -9223372036854775808
    var s_min = "-9223372036854775808"
    var p_min = Parser(s_min)
    assert_equal(p_min.expect_integer(), -9223372036854775808)

    # UInt64 Max: 18446744073709551615
    var s_umax = "18446744073709551615"
    var p_umax = Parser(s_umax)
    assert_equal(p_umax.expect_unsigned_integer(), 18446744073709551615)


def test_float_edge_cases():
    # Negative zero
    var p_neg0 = Parser("-0.0")
    assert_equal(p_neg0.expect_float(), -0.0)

    # Scientific notation variations
    var p_e1 = Parser("1E1")
    assert_equal(p_e1.expect_float(), 10.0)

    var p_plus = Parser("1e+1")
    assert_equal(p_plus.expect_float(), 10.0)

    var p_minus = Parser("1e-1")
    assert_equal(p_minus.expect_float(), 0.1)

    var p_sci = Parser("1.2e2")
    assert_equal(p_sci.expect_float(), 120.0)

    # Invalid syntax
    with assert_raises():
        var p = Parser("1.")
        _ = p.expect_float()  # Trailing dot

    with assert_raises():
        var p = Parser(".1")
        _ = p.expect_float()  # Leading dot

    with assert_raises():
        var p = Parser("1e")
        _ = p.expect_float()  # Missing exponent

    with assert_raises():
        var p = Parser("1.e1")
        _ = p.expect_float()  # Dot must be followed by digit


def test_unicode_byte_lengths():
    # 1 byte: A (U+0041)
    var s1 = r'{"key": "\u0041"}'
    var j1 = parse(s1)
    assert_equal(j1.object()["key"].string(), "A")

    # 2 bytes: £ (U+00A3)
    var s2 = r'{"key": "\u00A3"}'
    var j2 = parse(s2)
    assert_equal(j2.object()["key"].string(), "£")

    # 3 bytes: € (U+20AC)
    var s3 = r'{"key": "\u20AC"}'
    var j3 = parse(s3)
    assert_equal(j3.object()["key"].string(), "€")

    # 4 bytes: 𝄞 (U+1D11E) - Surrogate pair \uD834\uDD1E
    var s5 = r'{"key": "\uD834\uDD1E"}'
    var j5 = parse(s5)
    assert_equal(j5.object()["key"].string(), "𝄞")


def test_trailing_tokens():
    with assert_raises(
        contains="Invalid json, expected end of input, recieved: garbage tokens"
    ):
        _ = parse("[1, null, false] garbage tokens")

    with assert_raises(
        contains=(
            'Invalid json, expected end of input, recieved: "trailing string"'
        )
    ):
        _ = parse('{"key": null} "trailing string"')


def test_incomplete_data():
    with assert_raises():
        _ = parse("[1 null, false,")

    with assert_raises():
        _ = parse('{"key": 123')

    with assert_raises():
        _ = parse('["asdce]')

    with assert_raises():
        _ = parse('["no close')


def test_reject_comment():
    var s = """
    {
        // a comment
        "key": 123
    }
"""
    with assert_raises():
        _ = parse(s)


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
