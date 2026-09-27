"""Mutation tests for the reflection deserializer (`EmberJsonDeserializer`).

Valid documents, and every truncation and single-byte deletion, replacement
and insertion of them, go through `from_json[T]` under the default,
trailing-comma and lenient options, with the `Value` parser as an
independent oracle for the grammar:

- anything the `Value` parser rejects as malformed (`InvalidValue`),
  reflection rejects too, and when reflection's error is malformed JSON as
  well, it is the same error (see `test/emberjson/test_error_parity.mojo`);
- anything reflection accepts re-serializes to JSON that it reads back
  (with the default options) to the same value;
- every rejection is a typed error with a message.

Number edge cases, strings and grammar cases get the same checks, and the
valid numbers must read as the values the `Value` parser reads.
"""

from std.testing import assert_true, assert_false, assert_equal, TestSuite
from emberjson import (
    ParseOptions,
    StrictOptions,
    Value,
    from_json,
    to_json,
    DerErrorKind,
)


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Float64

    def __init__(out self):
        self.x = 0
        self.y = 0.0


@fieldwise_init
struct Rec(Defaultable, Movable):
    var id: Int
    var name: String
    var tags: List[String]
    var opt: Optional[Int]
    var vals: List[Float64]
    var m: Dict[String, Int]
    var flag: Bool
    var pt: Tuple[Float64, Float64]
    var pts: List[Point]
    var note: Optional[String]

    def __init__(out self):
        self.id = 0
        self.name = String()
        self.tags = List[String]()
        self.opt = None
        self.vals = List[Float64]()
        self.m = Dict[String, Int]()
        self.flag = False
        self.pt = (0.0, 0.0)
        self.pts = List[Point]()
        self.note = None


@fieldwise_init
struct Ints(Defaultable, Movable):
    var a: Int8
    var b: UInt8
    var c: Int32
    var d: UInt64
    var e: Int64

    def __init__(out self):
        self.a = 0
        self.b = 0
        self.c = 0
        self.d = 0
        self.e = 0


@fieldwise_init
struct Floats(Defaultable, Movable):
    var f: Float64
    var g: Float32

    def __init__(out self):
        self.f = 0.0
        self.g = 0.0


struct _Stats(Defaultable):
    var cases: Int
    var accepted: Int

    def __init__(out self):
        self.cases = 0
        self.accepted = 0


def _check[
    T: Movable & Deinitable, options: ParseOptions = ParseOptions()
](s: String, mut stats: _Stats) raises -> Bool:
    """Runs `from_json[T]` on `s` and checks it against the rules in the
    module docstring. Returns whether it accepted."""
    stats.cases += 1
    var malformed = False
    var value_message = String()
    try:
        _ = from_json[Value, options](s)
    except e:
        malformed = e.kind == DerErrorKind.InvalidValue
        value_message = e.message
    var v = Optional[T]()
    var kind = DerErrorKind.Custom
    var message = String()
    try:
        v = from_json[T, options](s)
    except e:
        kind = e.kind
        message = e.message
    if not v:
        if kind == DerErrorKind.Custom or not message:
            raise Error("untyped or empty error on: " + s)
        if malformed and kind == DerErrorKind.InvalidValue:
            if message != value_message:
                raise Error(
                    "error differs from the Value parser's on: "
                    + repr(s)
                    + "\n  reflection: "
                    + message
                    + "\n  Value:      "
                    + value_message
                )
        return False
    if malformed:
        raise Error("reflection ACCEPTED what the Value parser rejects: " + s)
    # Read back with the default options: serialized JSON needs none of
    # the lenient ones, and `ignore_unicode` would keep the escapes that
    # serializing a raw escape adds.
    var json = to_json(v.value())
    var again = to_json(from_json[T](json))
    if again != json:
        raise Error(
            "round trip changed on: " + s + "\n  " + json + "\n  " + again
        )
    stats.accepted += 1
    return True


comptime _INTERESTING: StaticString = ',:"\\ 0-.e}]{[xnt\n\t\x01'


def _mutations(s: String) -> List[String]:
    """Every truncation, and every single-byte deletion, replacement and
    insertion (from a set of JSON-significant bytes) of `s`."""
    var out = List[String]()
    var b = s.as_bytes()
    var n = len(b)
    var extra = _INTERESTING.as_bytes()
    for i in range(n + 1):
        out.append(String(StringSlice(unsafe_from_utf8=b[:i])))
    for i in range(n):
        var d = List[Byte](b[:i])
        d.extend(b[i + 1 :])
        out.append(String(unsafe_from_utf8=d^))
        for k in range(len(extra)):
            var r = List[Byte](b)
            r[i] = extra[k]
            out.append(String(unsafe_from_utf8=r^))
            var ins = List[Byte](b[:i])
            ins.append(extra[k])
            ins.extend(b[i:])
            out.append(String(unsafe_from_utf8=ins^))
    return out^


# Padding pushes every token far enough from the end of input that the
# deserializer takes its unchecked scalar readers; unpadded, the tokens near
# the end take the checked fallbacks. Both must pass the same checks.
comptime _PAD = (
    "                                                                "
)


def _rec_docs() -> List[String]:
    return [
        (
            '{"id":7,"name":"n","tags":["a","b"],"opt":3,"vals":[1.5,-2e3,0],'
            '"m":{"k":1,"j":2},"flag":true,"pt":[1.25,-0.5],'
            '"pts":[{"x":1,"y":2.5},{"x":-3,"y":0.125}],"note":null}'
        ),
        (
            '{ "id" : -12 , "name" : "h\\u00e9\\n" , "tags" : [ ] , "opt" :'
            ' null , "vals" : [ ] , "m" : { } , "flag" : false , "pt" : [ 0'
            ' , 1e-7 ] , "pts" : [ ] , "note" : "x\\"y" }'
        ),
        (
            '{"name":"out of order","id":1,"pt":[2,3],"flag":true,"vals":[],'
            '"tags":[],"m":{},"pts":[]}'
        ),
        '{"id":1,"extra":{"a":[1,2,{"b":null}]},"name":"skip","pt":[1,2],"flag":false,"tags":[],"vals":[],"m":{},"pts":[]}',
    ]


def _number_cases() -> List[String]:
    return [
        "0",
        "-0",
        "1",
        "-1",
        "7",
        "01",
        "-01",
        "00",
        "1.",
        ".5",
        "-.5",
        "+1",
        "-",
        "1e5",
        "1E+5",
        "1e-5",
        "1e",
        "1e+",
        "1.5e3",
        "1.5E-3",
        "12345678",
        "123456789",
        "1234567890123456",
        "12345678901234567",
        "1234567890123456789",
        "12345678901234567890",
        "123456789012345678901234567890",
        "127",
        "128",
        "-128",
        "-129",
        "255",
        "256",
        "2147483647",
        "2147483648",
        "-2147483648",
        "-2147483649",
        "9223372036854775807",
        "9223372036854775808",
        "-9223372036854775808",
        "-9223372036854775809",
        "18446744073709551615",
        "18446744073709551616",
        "0.1",
        "0.30000000000000004",
        "-65.613616999999977",
        "43.420273000000009",
        "1.7976931348623157e308",
        "1.7976931348623159e308",
        "1e309",
        "4.9e-324",
        "2.4703282292062327e-324",
        "1e-400",
        "2.2250738585072014e-308",
        "3.4028235677973366e38",
        "3.4028234663852886e38",
        "1.00000000000000011102230246251565404236316680908203125",
        "0.000000000000000000001",
        "123.456e-7",
        "1234567.8901234567",
        "12345678.901234567",
        "123456789.01234567",
        "1.23456789012345678",
        "true",
        "null",
        '"1"',
        "1x",
        "1 2",
        "1,",
    ]


def test_rec_documents_and_mutations() raises:
    var stats = _Stats()
    var docs = _rec_docs()
    for doc in docs:
        for padded in [False, True]:
            var d = doc + _PAD if padded else doc
            assert_true(_check[Rec](d, stats), "rejected a base document")
            _ = _check[Rec, ParseOptions(strict_mode=StrictOptions.LENIENT)](
                d, stats
            )
            for m in _mutations(d):
                _ = _check[Rec](m, stats)
                _ = _check[
                    Rec,
                    ParseOptions(
                        strict_mode=StrictOptions.ALLOW_TRAILING_COMMA
                    ),
                ](m, stats)
                _ = _check[
                    Rec, ParseOptions(strict_mode=StrictOptions.LENIENT)
                ](m, stats)
    assert_true(stats.accepted > 0)


def test_number_edge_cases() raises:
    var stats = _Stats()
    for num in _number_cases():
        for padded in [False, True]:
            var tail = _PAD if padded else ""
            _ = _check[Floats](
                '{"f":' + num + ',"g":' + num + "}" + tail, stats
            )
            _ = _check[List[Int]]("[" + num + ", 1]" + tail, stats)
            _ = _check[Ints](
                '{"a":'
                + num
                + ',"b":'
                + num
                + ',"c":'
                + num
                + ',"d":'
                + num
                + ',"e":'
                + num
                + "}"
                + tail,
                stats,
            )
            _ = _check[List[UInt8]]("[" + num + "]" + tail, stats)
    assert_true(stats.accepted > 0)


def test_numbers_read_as_the_value_parser_reads_them() raises:
    """A `Float64` target takes exactly the numbers the `Value` parser
    takes, with the same value; an `Int64` target takes exactly its
    Int64s."""
    for num in _number_cases():
        for padded in [False, True]:
            var doc = "[" + num + "," + num + "]" + (_PAD if padded else "")
            var expected = Optional[Value]()
            try:
                expected = from_json[Value](doc)
            except:
                pass
            var floats = Optional[List[Float64]]()
            try:
                floats = from_json[List[Float64]](doc)
            except:
                pass
            var is_number = False
            var is_int = False
            if expected:
                ref x = expected.value()[0]
                is_number = x.is_int() or x.is_uint() or x.is_float()
            assert_equal(Bool(floats), is_number, doc)
            if is_number:
                ref x = expected.value()[0]
                var f: Float64
                if x.is_float():
                    f = x.float()
                elif x.is_int():
                    f = Float64(x.int())
                    is_int = True
                else:
                    f = Float64(x.uint())
                assert_true(floats.value()[0] == f, doc)
                assert_true(floats.value()[1] == f, doc)
            var ints = Optional[List[Int64]]()
            try:
                ints = from_json[List[Int64]](doc)
            except:
                pass
            assert_equal(Bool(ints), is_int, doc)
            if ints:
                assert_equal(ints.value()[0], expected.value()[0].int(), doc)


def test_string_and_grammar_cases() raises:
    var stats = _Stats()
    var cases: List[String] = [
        '["a","b"]',
        '["a" "b"]',
        '["a",]',
        '[,"a"]',
        '["\\u00e9", "\\ud83d\\ude00", "\\/", "\\b\\f\\n\\r\\t"]',
        '["\\x"]',
        '["\\u12G4"]',
        '["\\ud800"]',
        '["tab\there"]',
        '["nl\nhere"]',
        '["a"]]',
        '[["a"]',
        '["unterminated]',
        '"top"',
        "[]",
        "[ ]",
        "  [  ]  ",
        "[] x",
        "[]x",
        "",
        " ",
        "[null]",
        '["a",null]',
    ]
    for c in cases:
        for padded in [False, True]:
            var d = c + _PAD if padded else c
            _ = _check[List[String]](d, stats)
            _ = _check[List[Optional[String]]](d, stats)
            _ = _check[List[String], ParseOptions(ignore_unicode=True)](
                d, stats
            )
            _ = _check[
                List[String],
                ParseOptions(strict_mode=StrictOptions.ALLOW_TRAILING_COMMA),
            ](d, stats)
    var maps: List[String] = [
        '{"a":1,"b":2}',
        '{"a":1,"a":2}',
        '{"a":1,}',
        '{"a" 1}',
        '{"a":1 "b":2}',
        '{"\\u0061":1}',
        "{1:2}",
        "{}",
    ]
    # Raw control bytes: stage 1 does not flag them, so the index path must
    # catch them in every string it takes verbatim (values, map keys) and
    # in keys that match no field.
    maps.append('{"a\nb":1}')
    maps.append('{"a\x01":1}')
    maps.append('{"ok":1,"\tb":2}')
    for c in maps:
        _ = _check[Dict[String, Int]](c, stats)
        _ = _check[
            Dict[String, Int], ParseOptions(strict_mode=StrictOptions.LENIENT)
        ](c, stats)
        _ = _check[Point](c, stats)
    var points: List[String] = [
        '{"x":1,"y":2}',
        '{"y":2,"x":1}',
        '{"x":1,"x":2,"y":3}',
        '{"x":1}',
        '{"x":1,"y":2,"z":3}',
        '{"\\u0078":1,"y":2}',
        '{"x":1,"y":2,}',
        '{"x":1;"y":2}',
    ]
    points.append('{"x":1,"y":2,"z\x01":3}')
    points.append('{"x\t":1,"x":1,"y":2}')
    points.append('{"x":1,"y":2,"note\n":"v"}')
    for c in points:
        _ = _check[Point](c, stats)
        _ = _check[
            Point, ParseOptions(strict_mode=StrictOptions.ALLOW_TRAILING_COMMA)
        ](c, stats)
    assert_true(stats.accepted > 0)


def test_long_uints_and_escaped_keys() raises:
    """20-digit UInt64s, and escaped keys in a strict-mode `Dict` (each one
    a key whose duplicates are found by decoded value), next to their
    invalid neighbours: a 20-digit overflow, a duplicate spelled with an
    escape."""
    var u = from_json[List[UInt64]]("[18446744073709551615, 1, 2, 3]" + _PAD)
    assert_equal(u[0], UInt64.MAX)
    u = from_json[List[UInt64]]("[10000000000000000000, 18446744073709551615]")
    assert_equal(u[0], 10000000000000000000)
    assert_equal(u[1], UInt64.MAX)
    u = from_json[List[UInt64]]("[1, 12345678901234567890, 3]" + _PAD)
    assert_equal(u[1], 12345678901234567890)
    var ints = from_json[Ints](
        '{"a":1,"b":2,"c":3,"d":18446744073709551615,"e":5}' + _PAD
    )
    assert_equal(ints.d, UInt64.MAX)
    var keyed = from_json[Dict[String, Int]](
        '{"caf\\u00e9":1,"a\\/b":2,"q\\"x":3,"\\ud83d\\ude00":4,"tab\\t":5}'
        + _PAD
    )
    assert_equal(keyed["caf\u00e9"], 1)
    assert_equal(keyed["a/b"], 2)
    assert_equal(keyed['q"x'], 3)
    assert_equal(keyed["😀"], 4)
    assert_equal(keyed["tab\t"], 5)
    var stats = _Stats()
    var rejects: List[String] = [
        "[18446744073709551616, 1]",
        "[99999999999999999999, 1]",
        "[00000000000000000001, 1]",
        "[123456789012345678901, 1]",
        "[-10000000000000000000, 1]",
    ]
    for c in rejects:
        assert_false(_check[List[UInt64]](c + _PAD, stats), c)
        assert_false(_check[List[Int64]](c + _PAD, stats), c)
    var dupes: List[String] = [
        '{"a":1,"\\u0061":2}',
        '{"\\u0061":1,"a":2}',
        '{"a/b":1,"a\\/b":2}',
    ]
    for c in dupes:
        var kind = DerErrorKind.Custom
        try:
            _ = from_json[Dict[String, Int]](c + _PAD)
        except e:
            kind = e.kind
        assert_equal(kind, DerErrorKind.DuplicateField, c)
        # Lenient mode keeps the last value.
        var last = from_json[
            Dict[String, Int], ParseOptions(strict_mode=StrictOptions.LENIENT)
        ](c + _PAD)
        assert_equal(len(last), 1, c)
        for entry in last.items():
            assert_equal(entry.value, 2, c)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
