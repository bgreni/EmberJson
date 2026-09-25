"""Differential test: the structural-index deserializer vs the byte walk.

`from_json` runs `from_json_indexed` and falls back to `from_json_bytewalk`
for the error it reports, so the index path must never ACCEPT an input the
byte walk rejects, and must build the identical value whenever it accepts.
Every case below runs both engines directly and checks exactly that, over
hand-picked documents, number edge cases, every truncation, and single-byte
deletions / replacements / insertions of valid documents, under the
default, trailing-comma and lenient options. It also checks the index path
actually takes (does not merely decline) the valid base documents, so the
fast path cannot silently rot into always falling back.
"""

from std.testing import assert_true, TestSuite
from emberjson import ParseOptions, StrictOptions, to_json
from emberjson._serde import from_json_bytewalk, from_json_indexed


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
    var both: Int
    var declined: Int

    def __init__(out self):
        self.cases = 0
        self.both = 0
        self.declined = 0


def _agree[
    T: Movable & Deinitable, options: ParseOptions = ParseOptions()
](s: String, mut stats: _Stats) raises -> Bool:
    """Runs both engines on `s`. Raises on a disagreement; returns whether
    the index path accepted."""
    stats.cases += 1
    var bw = Optional[String]()
    try:
        var v = from_json_bytewalk[T, options](s)
        try:
            bw = to_json(v)
        except:
            pass
    except:
        pass
    var ix = Optional[String]()
    try:
        var v = from_json_indexed[T, options](s)
        try:
            ix = to_json(v)
        except:
            pass
    except:
        pass
    if ix and not bw:
        raise Error("index path ACCEPTED what the byte walk rejects: " + s)
    if ix and bw:
        stats.both += 1
        if ix.value() != bw.value():
            raise Error(
                "value mismatch on: "
                + s
                + "\n  index: "
                + ix.value()
                + "\n  walk:  "
                + bw.value()
            )
    if bw and not ix:
        stats.declined += 1
    return Bool(ix)


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
# index path takes its unchecked scalar readers; unpadded, the tokens near
# the end take the checked fallbacks. Both must agree with the byte walk.
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


def test_rec_documents_and_mutations() raises:
    var stats = _Stats()
    var taken = 0
    var docs = _rec_docs()
    for doc in docs:
        for padded in [False, True]:
            var d = doc + _PAD if padded else doc
            if _agree[Rec](d, stats):
                taken += 1
            _ = _agree[Rec, ParseOptions(strict_mode=StrictOptions.LENIENT)](
                d, stats
            )
            for m in _mutations(d):
                _ = _agree[Rec](m, stats)
                _ = _agree[
                    Rec,
                    ParseOptions(
                        strict_mode=StrictOptions.ALLOW_TRAILING_COMMA
                    ),
                ](m, stats)
                _ = _agree[
                    Rec, ParseOptions(strict_mode=StrictOptions.LENIENT)
                ](m, stats)
    # Every valid base document must be settled by the index path itself.
    assert_true(taken == 2 * len(docs), "index path declined a base document")
    assert_true(stats.both > 0)


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


def test_number_edge_cases() raises:
    var stats = _Stats()
    for num in _number_cases():
        for padded in [False, True]:
            var tail = _PAD if padded else ""
            _ = _agree[Floats](
                '{"f":' + num + ',"g":' + num + "}" + tail, stats
            )
            _ = _agree[List[Float64]]("[" + num + "," + num + "]" + tail, stats)
            _ = _agree[List[Int64]]("[" + num + "]" + tail, stats)
            _ = _agree[List[Int]]("[" + num + ", 1]" + tail, stats)
            _ = _agree[Ints](
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
            _ = _agree[List[UInt8]]("[" + num + "]" + tail, stats)
    assert_true(stats.both > 0)


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
            _ = _agree[List[String]](d, stats)
            _ = _agree[List[Optional[String]]](d, stats)
            _ = _agree[List[String], ParseOptions(ignore_unicode=True)](
                d, stats
            )
            _ = _agree[
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
        _ = _agree[Dict[String, Int]](c, stats)
        _ = _agree[
            Dict[String, Int], ParseOptions(strict_mode=StrictOptions.LENIENT)
        ](c, stats)
        _ = _agree[Point](c, stats)
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
        _ = _agree[Point](c, stats)
        _ = _agree[
            Point, ParseOptions(strict_mode=StrictOptions.ALLOW_TRAILING_COMMA)
        ](c, stats)
    assert_true(stats.both > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
