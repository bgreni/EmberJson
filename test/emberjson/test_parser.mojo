from emberjson.parser import Parser
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


def main():
    var s = TestSuite.discover_tests[__functions_in_module()]()
    print(s.generate_report())
