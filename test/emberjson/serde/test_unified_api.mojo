from std.testing import (
    assert_equal,
    assert_not_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from emberjson import (
    Document,
    ParseOptions,
    Value,
    from_json,
    try_from_json,
    to_json,
    to_json_pretty,
    PAD_INPUT_THRESHOLD,
)
from emberjson.lazy import LazyString


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


comptime SAMPLE = '{"a":[1,2.5,"x",true,null],"b":{"c":{"d":[{}]}}}'


def _invalid_utf8_wire(out s: String):
    # {"a":"<0xFF>"} -- 0xFF is never a legal UTF-8 byte.
    var b = List[Byte]()
    for c in '{"a":"'.as_bytes():
        b.append(c)
    b.append(0xFF)
    for c in '"}'.as_bytes():
        b.append(c)
    s = String(StringSlice(unsafe_from_utf8=Span[Byte, origin_of(b)](b)))


def test_value_round_trips() raises:
    var v = from_json[Value](SAMPLE)
    assert_equal(to_json(v), SAMPLE)


def test_document_round_trips() raises:
    var d = from_json[Document](SAMPLE)
    assert_equal(d.to_string(), SAMPLE)


def test_document_takes_the_padded_path() raises:
    var wire = '{"k":"' + String("PADDING_") * 40 + '"}'
    assert_true(wire.byte_length() > PAD_INPUT_THRESHOLD)
    assert_equal(from_json[Document](wire).to_string(), wire)


def test_reflected_struct_round_trips() raises:
    var p = from_json[Point]('{"x":3,"y":4}')
    assert_equal(p.x, 3)
    assert_equal(p.y, 4)


def test_scalar_round_trips() raises:
    assert_equal(from_json[Int]("42"), 42)
    assert_equal(from_json[String]('"hi"'), "hi")


def test_invalid_utf8_rejected_for_value() raises:
    with assert_raises(contains="Invalid UTF-8"):
        _ = from_json[Value](_invalid_utf8_wire())


def test_invalid_utf8_rejected_for_document() raises:
    with assert_raises(contains="Invalid UTF-8"):
        _ = from_json[Document](_invalid_utf8_wire())


def test_invalid_utf8_rejected_for_reflection() raises:
    # This is the case that silently passed before unification: the
    # reflection path did no UTF-8 validation at all.
    with assert_raises(contains="Invalid UTF-8"):
        _ = from_json[Point](_invalid_utf8_wire())


def test_validate_utf8_false_skips_the_check() raises:
    comptime trusted = ParseOptions(validate_utf8=False)
    # Does not raise: the caller opted out. The 0xFF rides through into
    # the resulting String, exactly as it does on the old `parse`.
    var v = from_json[Value, trusted](_invalid_utf8_wire())
    assert_true(v.is_object())


def test_trailing_content_rejected() raises:
    with assert_raises():
        _ = from_json[Value]('{"a":1} trailing')
    with assert_raises():
        _ = from_json[Point]('{"x":1,"y":2} trailing')


def test_options_reach_the_parser() raises:
    # The point is that `options` is actually threaded through to the
    # Parser rather than dropped on the floor by the new dispatch. Asserted
    # as a differential so the test does not hard-code an escape-encoding
    # expectation: `ignore_unicode` leaves `\uXXXX` undecoded, the default
    # decodes it, so the two results must differ.
    comptime raw = ParseOptions(ignore_unicode=True)
    var kept = to_json(from_json[Value, raw](r'["\uD83D\uDD25"]'))
    var decoded = to_json(from_json[Value](r'["\uD83D\uDD25"]'))
    assert_not_equal(kept, decoded)
    assert_true("\\u" in kept)


def test_try_from_json_value() raises:
    assert_true(try_from_json[Value]('{"a":1}'))
    assert_false(try_from_json[Value]("{not json"))


def test_try_from_json_document() raises:
    assert_true(try_from_json[Document]('{"a":1}'))
    assert_false(try_from_json[Document]("{not json"))


def test_try_from_json_struct() raises:
    assert_true(try_from_json[Point]('{"x":1,"y":2}'))
    assert_false(try_from_json[Point]('{"x":1}'))
    assert_false(try_from_json[Point](_invalid_utf8_wire()))


def test_lazy_borrowing_survives_the_unified_path() raises:
    # Regression guard for the spec's "Known limitation". The reflection
    # branch must stay UNPADDED: a `PaddedBuffer` is a local that dies when
    # from_json returns, so a borrowing type would be left pointing at
    # freed memory. A wire comfortably over PAD_INPUT_THRESHOLD is exactly
    # the input that would trigger the padded path if someone "optimized"
    # this branch later.
    var payload = String("BORROWED_") * 40
    var wire = '"' + payload + '"'
    assert_true(wire.byte_length() > PAD_INPUT_THRESHOLD)
    var lz = from_json[LazyString[ImmutAnyOrigin]](wire)
    assert_equal(lz.get(), payload)


def test_lazy_span_aliases_the_callers_buffer() raises:
    # The sharper form of the guard above: prove the borrow points INTO
    # the caller's own String, not into a copy. If the reflection branch
    # ever routes through PaddedBuffer this address check fails (and the
    # data is garbage) rather than passing by luck.
    var payload = String("BORROWED_") * 40
    var wire = '"' + payload + '"'
    var base = Int(wire.unsafe_ptr())
    var limit = base + wire.byte_length()
    var lz = from_json[LazyString[ImmutAnyOrigin]](wire)
    var addr = Int(lz.unsafe_as_string_slice().unsafe_ptr())
    assert_true(addr >= base)
    assert_true(addr < limit)


def test_from_json_does_not_relocate_a_literal_backed_string() raises:
    # `String("BORROWED_") * 40` in the two tests above is already a
    # UNIQUELY heap-owned buffer by the time `from_json` sees it, so
    # `unsafe_ptr_mut()` -- what a bare, mutable-resolving `StringSlice`
    # parameter forces a `String` through -- returns that SAME pointer.
    # Those two tests cannot tell the `ImmOrigin` signature apart from a
    # bare `StringSlice` one. A `String` built directly from a literal is
    # different: it holds a pointer into static literal data with no
    # unique heap ownership behind it, so `unsafe_ptr_mut()` must
    # reallocate onto the heap to hand back a mutable view -- silently
    # relocating the caller's buffer out from under any borrow taken from
    # it. That reallocation is exactly what the `ImmOrigin` signature on
    # `from_json`/`try_from_json` exists to prevent.
    var wire = String('"SENTINEL_LITERAL_BACKED_STRING_VALUE"')
    var before = Int(wire.unsafe_ptr())
    var lz = from_json[LazyString[ImmutAnyOrigin]](wire)
    assert_equal(Int(wire.unsafe_ptr()), before)
    var addr = Int(lz.unsafe_as_string_slice().unsafe_ptr())
    assert_true(addr >= before)
    assert_true(addr < before + wire.byte_length())
    assert_equal(lz.get(), "SENTINEL_LITERAL_BACKED_STRING_VALUE")


def test_to_json_value() raises:
    assert_equal(to_json(from_json[Value](SAMPLE)), SAMPLE)


def test_to_json_document() raises:
    assert_equal(to_json(from_json[Document](SAMPLE)), SAMPLE)


def test_to_json_reflected_struct() raises:
    assert_equal(to_json(Point(3, 4)), '{"x":3,"y":4}')


def test_to_json_pretty_indents() raises:
    var out = to_json_pretty(from_json[Value]('{"key":123}'))
    assert_equal(out, '{\n    "key": 123\n}')


def test_to_json_pretty_custom_indent() raises:
    var out = to_json_pretty[indent="\t"](from_json[Value]('{"key":123}'))
    assert_true("\t" in out)
    assert_equal(out, '{\n\t"key": 123\n}')


def test_to_json_pretty_matches_pretty_parameter() raises:
    var v = from_json[Value](SAMPLE)
    assert_equal(to_json_pretty(v), to_json[pretty=True](v))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
