from std.testing import (
    assert_equal,
    assert_true,
    assert_raises,
    TestSuite,
)

from emberjson._serde import EmberJsonDeserializer
from emberjson._deserialize import Parser, ParseOptions

from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializable,
    Deserializer,
    RawKind,
    deserialize,
)
from emberserde.error import DeserializationError


# Mirrors `emberserde/test/deserialize/test_borrow.mojo`'s `LazyRaw`, but
# drives `EmberJsonDeserializer` (backed by the hand-written `Parser`)
# instead of the toy format's cursor. Holds the raw wire bytes of one value,
# borrowed from the input, and defers any interpretation to the caller.
@fieldwise_init
struct LazyRaw[o: ImmOrigin, kind: RawKind](Deserializable, Movable):
    var _data: Span[Byte, Self.o]

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            type_of(d), BorrowingDeserializer
        ), "LazyRaw requires a borrowing deserializer"
        return Self(rebind[Span[Byte, Self.o]](d.raw_bytes[Self.kind]()))

    def as_slice(self) -> StringSlice[Self.o]:
        return StringSlice(unsafe_from_utf8=self._data)

    def address(self) -> Int:
        return Int(self._data.unsafe_ptr())


# `s` is borrowed (default `read` convention), so the origin ties back to
# the caller's own local — the caller must keep it alive as long as the
# returned `LazyRaw` is in use, same requirement the toy suite's `_borrow`
# places on its `cursor` argument.
def _borrow[
    kind: RawKind
](s: String) raises DeserializationError -> LazyRaw[ImmutAnyOrigin, kind]:
    var p = Parser(s)
    var d = EmberJsonDeserializer(p=Pointer(to=p))
    return deserialize[LazyRaw[ImmutAnyOrigin, kind]](d)


def test_raw_bytes_str_keeps_quotes() raises:
    # The span is the raw wire token, so the quotes are part of it -- callers
    # that want the contents strip them (EmberJson's `unsafe_as_string_slice`).
    var wire = String('"hi"')
    var lz = _borrow[RawKind.Str](wire)
    assert_equal(String(lz.as_slice()), String('"hi"'))


def test_raw_bytes_str_with_escape() raises:
    # An escaped quote must not end the token early.
    var wire = String('"a\\"b"')
    var lz = _borrow[RawKind.Str](wire)
    assert_equal(String(lz.as_slice()), String('"a\\"b"'))


def test_raw_bytes_int() raises:
    var wire = String("-42")
    var lz = _borrow[RawKind.Integer](wire)
    assert_equal(String(lz.as_slice()), String("-42"))


def test_raw_bytes_float() raises:
    var wire = String("3.5e2")
    var lz = _borrow[RawKind.Float](wire)
    assert_equal(String(lz.as_slice()), String("3.5e2"))


def test_raw_bytes_seq_captures_nested() raises:
    var wire = String("[1, 2, [3]]")
    var lz = _borrow[RawKind.Seq](wire)
    assert_equal(String(lz.as_slice()), String("[1, 2, [3]]"))


def test_raw_bytes_map_captures_whole_object() raises:
    var wire = String('{"a": {"b": 1}}')
    var lz = _borrow[RawKind.Map](wire)
    assert_equal(String(lz.as_slice()), String('{"a": {"b": 1}}'))


def test_raw_bytes_any_accepts_any_shape() raises:
    var wire = String("true")
    var lz = _borrow[RawKind.Any](wire)
    assert_equal(String(lz.as_slice()), String("true"))


def test_integer_kind_rejects_float() raises:
    # Fail-fast validation: this is what a single generic `raw_bytes[Any]`
    # would have silently accepted, deferring the error to `get`. Exercises
    # `Parser._validate_number[integer_only=True]`'s "received a float" path.
    var wire = String("1.5")
    with assert_raises():
        _ = _borrow[RawKind.Integer](wire)


def test_str_kind_rejects_number() raises:
    var wire = String("12")
    with assert_raises():
        _ = _borrow[RawKind.Str](wire)


def test_map_kind_rejects_seq() raises:
    var wire = String("[1]")
    with assert_raises():
        _ = _borrow[RawKind.Map](wire)


def test_borrowed_span_aliases_the_input() raises:
    # The defining property: no copy. The returned span must point *into*
    # the wire's own buffer, not at freshly allocated bytes.
    var wire = String('   "borrowed"')
    var base = Int(wire.unsafe_ptr())
    var limit = base + wire.byte_length()
    var lz = _borrow[RawKind.Str](wire)
    assert_true(lz.address() >= base)
    assert_true(lz.address() < limit)


def test_cursor_advances_past_borrowed_value() raises:
    # The borrow consumes the value, so a following read starts after it.
    var wire = String('["a", "b"]')
    var p = Parser(wire)
    var d = EmberJsonDeserializer(p=Pointer(to=p))
    var st = d.begin_seq()
    _ = st.has_next()
    var first = st.expect_element[LazyRaw[ImmutAnyOrigin, RawKind.Str]]()
    assert_equal(String(first.as_slice()), String('"a"'))
    _ = st.has_next()
    var second = st.expect_element[LazyRaw[ImmutAnyOrigin, RawKind.Str]]()
    assert_equal(String(second.as_slice()), String('"b"'))


def test_deferred_parse_of_borrowed_bytes() raises:
    # Laziness end to end: borrow the map's bytes, then interpret them later
    # by feeding the span back through a fresh parser/deserializer pair.
    var wire = String('{"x": 7}')
    var lz = _borrow[RawKind.Map](wire)

    var inner = String(lz.as_slice())
    var inner_p = Parser(inner)
    var d = EmberJsonDeserializer(p=Pointer(to=inner_p))
    var st = d.begin_map()
    _ = st.has_next()
    assert_equal(st.expect_key[String](), String("x"))
    assert_equal(st.expect_value[Int64](), Int64(7))


def test_conformance_relationships() raises:
    assert_true(
        conforms_to(
            EmberJsonDeserializer[ImmutAnyOrigin, ParseOptions(), MutAnyOrigin],
            Deserializer,
        )
    )
    assert_true(
        conforms_to(
            EmberJsonDeserializer[ImmutAnyOrigin, ParseOptions(), MutAnyOrigin],
            BorrowingDeserializer,
        )
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
