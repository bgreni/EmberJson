# Every parse engine must reject a malformed input with the same error: the
# same message and `DerErrorKind`, built by the shared constructors in
# `emberjson/_deserialize/_errors.mojo`. The `Value` parser is the reference;
# each case also runs through
#   - `Document`, whose tape builder walks bytes below
#     `PAD_INPUT_THRESHOLD` and the structural index above it;
#   - a `Lazy` root, captured by the `Parser`'s validating skip;
#   - reflection into a type that matches the input's shape, which walks
#     the structural index and reads scalars inline away from the end of
#     the input;
# as written, padded with leading whitespace, padded with trailing
# whitespace (both past the threshold), and as a field (`{"v": ...`), where
# reflection reads it through a struct and a `Lazy` field. (Reflection also
# prepends the field path, which is not compared.) The field is followed by
# `#`, which no token can take in, rather than by `}`, which could complete
# a truncated input into a value the target rejects for its shape (`{` into
# `{}`, a struct missing its fields).
#
# Only malformed JSON is compared, read as the type it is written as: a
# value of another type is a `TypeMismatch` that only reflection raises,
# judged by its first byte (`12x` read as a list is a mismatch).

from std.testing import assert_equal, assert_true, TestSuite
from std.collections import Dict
from std.utils import Variant
from emberjson import from_json, Value, Document, ParseOptions
from emberjson.lazy import LazyValue
from emberjson.utils import PAD_INPUT_THRESHOLD
from emberserde.utils import Base


@fieldwise_init
struct Wrap[T: Base](Defaultable, Movable):
    # `Optional` makes the struct `Defaultable`, which a struct with fields
    # that need destructors must be, whatever `T` is.
    var v: Optional[Self.T]

    def __init__(out self):
        self.v = None


@fieldwise_init
struct WrapLazy[o: ImmOrigin](Movable):
    var v: LazyValue[Self.o]


@fieldwise_init
struct Pair(Movable):
    var a: Int64
    var b: Int64


def _outcome[
    T: Movable & Deinitable, options: ParseOptions
](json: String) -> String:
    """How `from_json[T]` ends on `json`: "<kind>: <message>" or
    "accepted"."""
    try:
        _ = from_json[T, options](StringSlice(json))
    except e:
        return String(e.kind, ": ", e.message)
    return "accepted"


def _same[
    T: Movable & Deinitable, options: ParseOptions
](json: String, want: String, engine: StaticString) raises:
    assert_equal(
        _outcome[T, options](json),
        want,
        String(engine, " differs from Value on: ", repr(json)),
    )


def _check[
    T: Base, options: ParseOptions = ParseOptions(), grammar: Bool = True
](json: String) raises:
    """`json` is malformed, and every engine rejects it as `Value` does.

    `grammar=False`: `json` breaks a limit of materializing a value (a
    number out of range, a duplicate key), not the grammar. A `Lazy`
    capture checks only the grammar, and the limit when it is read, so it
    is left out."""
    var pad = String()
    for _ in range(PAD_INPUT_THRESHOLD + 8):
        pad += " "
    for input in [json, pad + json, json + pad]:
        var want = _outcome[Value, options](input)
        assert_true(want != "accepted", String("Value accepts: ", repr(input)))
        _same[Document, options](input, want, "Document")
        comptime if grammar:
            _same[LazyValue[ImmutAnyOrigin], options](input, want, "Lazy")
        _same[T, options](input, want, "reflection")

        var field = String('{"v": ', input, "#")
        want = _outcome[Value, options](field)
        assert_true(want != "accepted", String("Value accepts: ", repr(field)))
        _same[Document, options](field, want, "Document")
        _same[Wrap[T], options](field, want, "reflection")
        comptime if grammar:
            _same[WrapLazy[ImmutAnyOrigin], options](field, want, "Lazy field")


def test_empty() raises:
    _check[List[Int64]]("")
    _check[List[Int64]]("   ")
    _check[String]("")
    _check[Pair]("\n")


def test_arrays() raises:
    comptime L = List[Int64]
    _check[L]("[")
    _check[L]("[1")
    _check[L]("[1,")
    _check[L]("[1, 2")
    _check[L]("[1 2]")
    _check[L]("[1,]")
    _check[L]("[1,,2]")
    _check[L]("[,1]")
    _check[L]("[1:2]")
    _check[L]("[1}")
    _check[L]("]")
    _check[L]("[x]")
    _check[L]("[1]]")
    _check[L]("[1] x")
    _check[L]("[1] [2]")


def test_nested_arrays() raises:
    comptime LL = List[List[Int64]]
    _check[LL]("[[1],[2]")
    _check[LL]("[[1] [2]]")
    _check[LL]("[[1],]")
    _check[LL]("[[1,]]")
    _check[LL]("[[1}]")
    _check[LL]("[[1]}")
    _check[LL]("[[")


def test_numbers() raises:
    comptime L = List[Int64]
    _check[L]("[1x]")
    _check[L]("[1;2]")
    _check[L]("[01]")
    _check[L]("[1.]")
    _check[L]("[1.x]")
    _check[L]("[-]")
    _check[L]("[--1]")
    _check[L]("[+1]")
    _check[L]("[1e]")
    _check[L]("[1e+]")
    _check[Int64]("12x")
    _check[Int64]("-")
    _check[Int64]("1 2")

    comptime F = List[Float64]
    _check[F]("[1.5x]")
    _check[F]("[1.5e+-3]")
    _check[F, grammar=False]("[1e999]")
    _check[F, grammar=False]("[-1e999]")
    _check[F]("[.5]")
    _check[F]("[1.5")
    _check[F]("[1.5,]")
    _check[Float64]("1.5 2")
    _check[Float64]("1.5e")


def test_literals() raises:
    comptime B = List[Bool]
    _check[B]("[t")
    _check[B]("[tru]")
    _check[B]("[truex]")
    _check[B]("[fals]")
    _check[B]("[falsey]")
    _check[B]("[true false]")
    _check[B]("[True]")
    _check[Bool]("truex")
    _check[Bool]("true false")

    comptime O = List[Optional[Int64]]
    _check[O]("[n")
    _check[O]("[nul]")
    _check[O]("[nullx]")
    _check[O]("[null null]")
    _check[Optional[Int64]]("nulll")


def test_misspelled_literal_for_other_type() raises:
    # A misspelled `true`/`false`/`null` or a `+` is malformed JSON whatever
    # was expected there.
    _check[List[Int64]]("[nul]")
    _check[List[Int64]]("[tru")
    _check[List[Int64]]("[+]")
    _check[String]("tru")
    _check[String]("nul")
    _check[Pair]("fals")
    _check[List[Bool]]("[nulx]")


def test_strings() raises:
    comptime S = List[String]
    _check[S]('["abc')
    _check[S]('["a\\qb"]')
    _check[S]('["a\\qb')
    _check[S]('["a\x01"]')
    _check[S]('["a\x01')
    _check[S]('["a\x1f\\q"]')
    _check[S]('["a\\q\x1f"]')
    _check[S]('["\\u12"]')
    _check[S]('["\\u12G4"]')
    _check[S]('["\\uD800"]')
    _check[S]('["\\uD800\\u0041"]')
    _check[S]('["a" "b"]')
    _check[S]('["a"x]')
    _check[S]('["a\\')
    _check[S]('["a",]')
    _check[String]('"abc')
    _check[String]('"abc"x')
    _check[String]('"a" "b"')
    _check[String]('"0123456789abcdef0123456789\x01"')
    _check[String]('"0123456789abcdef0123456789\\x"')


def test_structs() raises:
    _check[Pair]("{")
    _check[Pair]('{"a"')
    _check[Pair]('{"a":')
    _check[Pair]('{"a":1,')
    _check[Pair]('{"a":1,"b"')
    _check[Pair]('{"a":1,"b":2')
    _check[Pair]('{"a":1 "b":2}')
    _check[Pair]('{"a":1,}')
    _check[Pair]('{"a":1,"b":2,}')
    _check[Pair]('{"a" 1}')
    _check[Pair]('{"a":}')
    _check[Pair]("{a:1}")
    _check[Pair]('{"a":1,,"b":2}')
    _check[Pair]('{"a":1;"b":2}')
    _check[Pair]('{"a":1x}')
    _check[Pair]('{"a":1,"b":2 x}')
    _check[Pair]('{"a":1, "b":2]')
    _check[Pair]('{"a":1,"b":2}}')
    _check[Pair]('{"a":1,"b":2} {')


def test_struct_keys() raises:
    # A malformed key can pair quotes differently in the structural index
    # (`\:` escapes the colon there), so the key is judged before the colon.
    _check[Pair]('{"a\\:1}')
    _check[Pair]('{"a\\:1, "b": 2}')
    _check[Pair]('{"a\\u12G4": 1}')
    _check[Pair]('{"\\u12G4" 1}')
    _check[Pair]('{"a\x01":1}')
    _check[Pair]('{"a\x01" 1}')
    _check[Pair]('{"a\\q" 1}')


def test_struct_reordered() raises:
    # Keys out of declaration order take the framework's driver.
    _check[Pair]('{"b":1 "a":2}')
    _check[Pair]('{"b":1,}')
    _check[Pair]('{"b":1,"a":2')
    _check[Pair]('{"b":1,"a"2}')


def test_skipped_fields() raises:
    # An unknown field's value goes through the `Parser`'s validating skip.
    _check[Pair]('{"a":1,"z":[1 2],"b":2}')
    _check[Pair]('{"a":1,"z":[1,],"b":2}')
    _check[Pair]('{"a":1,"z":{"q" 1},"b":2}')
    _check[Pair]('{"a":1,"z":{"q":1,},"b":2}')
    _check[Pair]('{"a":1,"z":{q:1},"b":2}')
    _check[Pair]('{"a":1,"z":tru,"b":2}')
    _check[Pair]('{"a":1,"z":"ab\\q","b":2}')
    _check[Pair]('{"a":1,"z":1x,"b":2}')
    _check[Pair]('{"a":1,"z":1.e5,"b":2}')
    _check[Pair]('{"a":1,"z":[1')


def test_maps() raises:
    comptime M = Dict[String, Int64]
    _check[M]("{")
    _check[M]('{"a"')
    _check[M]('{"a":1')
    _check[M]('{"a":1,')
    _check[M]('{"a" 1}')
    _check[M]('{"a":1 "b":2}')
    _check[M]('{"a":1,}')
    _check[M]('{"a":1,,"b":2}')
    _check[M]("{1:2}")
    _check[M]('{"a":1,2:3}')
    _check[M]('{"a\x01":1}')
    _check[M]('{"a\\q":1}')
    _check[M, grammar=False]('{"a":1,"a":2}')
    _check[M, grammar=False]('{"\\u0061":1,"a":2}')


def test_tuples() raises:
    comptime T = Tuple[Int64, Int64]
    _check[T]("[1 2]")
    _check[T]("[1,")
    _check[T]("[1,2")
    _check[T]("[1,2 3]")
    _check[T]("[1,2,]")
    _check[T]("[1,2}")


def test_enums() raises:
    comptime E = Variant[Bool, String]
    _check[E]("{")
    _check[E]('{"Bool"')
    _check[E]('{"Bool" true}')
    _check[E]('{"Bool":true')
    _check[E]('{"Bool":true,}')
    _check[E]('{"Bool":true x}')
    _check[E]('{"Bool":tru}')
    _check[E]("{1:true}")
    _check[E]('{"Bo\\ql":true}')


comptime _INTERESTING: StaticString = ',:"\\ 0-.e}]{[xnt\x01'


def _mutations(s: String) -> List[String]:
    """Every truncation, and every single-byte deletion, replacement and
    insertion (from a set of JSON-significant bytes) of `s`."""
    var out = List[String]()
    var b = s.as_bytes()
    var extra = _INTERESTING.as_bytes()
    for i in range(len(b) + 1):
        out.append(String(StringSlice(unsafe_from_utf8=b[:i])))
    for i in range(len(b)):
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


def test_mutations_across_parsers() raises:
    # The parsers that read any JSON agree on every mutation of these
    # documents, accepted or not: `Document` exactly, a `Lazy` capture
    # wherever no materializing limit is involved (see `_check`).
    var docs: List[String] = [
        '{"a":[1,-2.5e3,true,null],"b":{"c":"x\\n\\u00e9"},"d":[]}',
        '[{"k":"\\uD834\\uDD1E"},[0.5,[false]],"",{}]',
    ]
    var pad = String()
    for _ in range(PAD_INPUT_THRESHOLD + 8):
        pad += " "
    var cases = 0
    for doc in docs:
        for m in _mutations(doc):
            for input in [m, pad + m, m + pad]:
                var want = _outcome[Value, ParseOptions()](input)
                _same[Document, ParseOptions()](input, want, "Document")
                if not (
                    want.startswith("DuplicateField")
                    or want.endswith("Infinite float")
                ):
                    _same[LazyValue[ImmutAnyOrigin], ParseOptions()](
                        input, want, "Lazy"
                    )
                cases += 1
    assert_true(cases > 1000)


def _kind[T: Movable & Deinitable](json: String) -> String:
    try:
        _ = from_json[T](StringSlice(json))
    except e:
        return String(e.kind)
    return "accepted"


def test_wrong_shapes_are_mismatches() raises:
    # Well-formed JSON the target cannot hold is not compared above: `Value`
    # accepts it, and reflection raises a `TypeMismatch`, never the
    # `InvalidValue` of malformed JSON.
    comptime T = Tuple[Int64, Int64]
    for json in ["[]", "[1]", "[1,2,3]", "{}", "1", '"a"']:
        assert_equal(_kind[T](json), "TypeMismatch", json)
    comptime E = Variant[Bool, String]
    for json in ["{}", '{"Bool":true,"x":1}', "[]", "true"]:
        assert_equal(_kind[E](json), "TypeMismatch", json)
    for json in ["[]", "1", "true", "null"]:
        assert_equal(_kind[Pair](json), "TypeMismatch", json)
        assert_equal(_kind[String](json), "TypeMismatch", json)


def test_depth() raises:
    comptime opts = ParseOptions(max_depth=2)
    _check[List[List[List[Int64]]], opts]("[[[1]]]")
    _check[Pair, opts]('{"a":1,"z":[[1]],"b":2}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
