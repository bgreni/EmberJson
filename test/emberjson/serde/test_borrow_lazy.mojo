from std.testing import (
    assert_equal,
    assert_true,
    assert_raises,
    TestSuite,
)

from emberjson._serde import (
    EmberJsonDeserializer,
    from_json_string,
    to_json_string,
)
from emberjson._deserialize import Parser, ParseOptions
from emberjson._deserialize import JsonDeserializable
from emberjson.lazy import (
    Lazy,
    LazyString,
    LazyInt,
    LazyUInt,
    LazyFloat,
    LazyValue,
)
from emberjson.value import Value
from emberjson.utils import PaddedBuffer

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


def test_raw_bytes_refuses_padded_options() raises:
    # Borrowing hands back a span into the parser's own input buffer. Under
    # non-default options (`_padded()`), that buffer is a temporary
    # `PaddedBuffer` copy that does not outlive the parse call -- a
    # borrowed span into it would dangle. `raw_bytes` must refuse rather
    # than silently handing out a soon-to-be-dangling span. This is the
    # `comptime assert options == ParseOptions()` restriction `Lazy` used
    # to carry itself (`emberjson/lazy.mojo`'s old `from_json`), now
    # enforced at the format layer (`EmberJsonDeserializer.raw_bytes` in
    # `emberjson/_serde/deserializer.mojo`) instead, since it knows the
    # buffer's provenance and `Lazy.deserialize` -- generic over `Some[
    # Deserializer]` -- deliberately does not.
    var wire = String('"hi"')
    var buf = PaddedBuffer(wire.as_bytes())
    var p = Parser[options=ParseOptions()._padded()](padded=buf)
    var d = EmberJsonDeserializer(p=Pointer(to=p))
    with assert_raises():
        _ = d.raw_bytes[RawKind.Str]()


# ===========================================================================
# `emberjson.lazy.Lazy` itself, driven through the new
# `BorrowingDeserializer` path (`EmberJsonDeserializer.raw_bytes`) via
# `from_json_string`. `Lazy` keeps dual conformance -- the tests above (and
# `test/emberjson/test_lazy.mojo`, `test_mixed_lazy.mojo`, `bench.mojo`)
# exercise the old `JsonDeserializable`/`Parser`-driven path unchanged;
# these exercise the new `Deserializable`/`Serializable` path this task
# adds. Both write the same `_data` span, and `get()` always re-parses it
# through the old `Parser` regardless of which path captured it.
# ===========================================================================


def test_lazy_string_via_borrowing_deserializer() raises:
    var wire = String('"hello"')
    var lz = from_json_string[LazyString[ImmutAnyOrigin]](wire)
    assert_equal(lz.get(), String("hello"))


def test_lazy_int_via_borrowing_deserializer() raises:
    var wire = String("-42")
    var lz = from_json_string[LazyInt[ImmutAnyOrigin]](wire)
    assert_equal(lz.get(), Int64(-42))


def test_lazy_uint_via_borrowing_deserializer() raises:
    var wire = String("18446744073709551615")
    var lz = from_json_string[LazyUInt[ImmutAnyOrigin]](wire)
    assert_equal(lz.get(), UInt64(18446744073709551615))


def test_lazy_float_via_borrowing_deserializer() raises:
    var wire = String("3.5e2")
    var lz = from_json_string[LazyFloat[ImmutAnyOrigin]](wire)
    assert_equal(lz.get(), Float64(3.5e2))


def test_lazy_value_via_borrowing_deserializer() raises:
    var wire = String('{"a": [1, 2, 3]}')
    var lz = from_json_string[LazyValue[ImmutAnyOrigin]](wire)
    var v = lz.get()
    assert_true(v.is_object())
    assert_equal(v.object()["a"].array()[1].int(), 2)


def test_lazy_string_unsafe_slice_strips_quotes() raises:
    # `unsafe_as_string_slice` returns the RAW (unescaped) bytes between the
    # quotes -- `RawKind.Str` spans include their quotes, so this must strip
    # exactly one byte off each end, and must not decode escapes.
    var wire = String('"a\\"b"')
    var lz = from_json_string[LazyString[ImmutAnyOrigin]](wire)
    assert_equal(String(lz.unsafe_as_string_slice()), String('a\\"b'))
    # `get()` does decode the escape.
    assert_equal(lz.get(), String('a"b'))


def test_lazy_int_kind_mismatch_raises() raises:
    var wire = String('"not an int"')
    with assert_raises():
        _ = from_json_string[LazyInt[ImmutAnyOrigin]](wire)


def test_lazy_float_kind_mismatch_raises() raises:
    var wire = String("[1, 2]")
    with assert_raises():
        _ = from_json_string[LazyFloat[ImmutAnyOrigin]](wire)


def test_lazy_span_aliases_the_input() raises:
    # No-copy check, mirrored from `test_borrowed_span_aliases_the_input`
    # above but exercised through the real `Lazy` type.
    var wire = String('   "borrowed"')
    var base = Int(wire.unsafe_ptr())
    var limit = base + wire.byte_length()
    var lz = from_json_string[LazyString[ImmutAnyOrigin]](wire)
    var addr = Int(lz.unsafe_as_string_slice().unsafe_ptr())
    assert_true(addr >= base)
    assert_true(addr < limit)


def test_lazy_serialize_string_via_new_serializer() raises:
    var wire = String('"hello"')
    var lz = from_json_string[LazyString[ImmutAnyOrigin]](wire)
    assert_equal(to_json_string(lz), String('"hello"'))


def test_lazy_serialize_value_via_new_serializer() raises:
    var wire = String('{"a": [1, 2, 3]}')
    var lz = from_json_string[LazyValue[ImmutAnyOrigin]](wire)
    assert_equal(to_json_string(lz), String('{"a":[1,2,3]}'))


def test_serialize_reencodes_rather_than_echoing() raises:
    # `Lazy.serialize` re-parses via `get()` and re-encodes rather than
    # echoing the captured span, so the output is only *semantically*
    # equal to the source wire text -- here the inter-element whitespace is
    # gone. Pin that, since a caller who wanted the original bytes back has
    # to reach for the span itself (see the `Lazy` struct docstring in
    # `emberjson/lazy.mojo`).
    #
    # Until Task 8 this was a comparison against the deleted
    # `JsonSerializable.write_json`, which DID echo verbatim; that
    # passthrough has no emberserde counterpart (the `Serializer` trait
    # grew no raw hook), so what is left to assert is the re-encoding
    # itself.
    var wire = String('{"a": [1, 2, 3]}')
    var lz = from_json_string[LazyValue[ImmutAnyOrigin]](wire)

    var out = to_json_string(lz)
    assert_equal(out, String('{"a":[1,2,3]}'))
    assert_true(out != wire)

    # The captured span is still the original bytes -- only `serialize`
    # normalizes.
    assert_equal(String(StringSlice(unsafe_from_utf8=lz._data)), wire)


# A `JsonDeserializable` struct opting into array-style JSON, mirroring
# `test/emberjson/reflection/test_reflection_deserialize.mojo`'s `Point`.
# Exercises `__pick_kind`'s default (`Seq` when `deserialize_as_array()` is
# `True`) for a bare `Lazy[T, origin]` with no explicit `kind`, through the
# new borrowing path.
@fieldwise_init
struct _LazyPoint(JsonDeserializable):
    var x: Int
    var y: Int

    @staticmethod
    def deserialize_as_array() -> Bool:
        return True


def test_lazy_default_kind_picks_seq_for_array_struct() raises:
    var wire = String("[1, 2]")
    var lz = from_json_string[Lazy[_LazyPoint, ImmutAnyOrigin]](wire)
    var p = lz.get()
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


# A plain `JsonDeserializable` struct (default `deserialize_as_array() ->
# False`). Exercises `__pick_kind`'s other branch (`Map`).
@fieldwise_init
struct _LazyRecord(JsonDeserializable):
    var x: Int
    var y: Int


def test_lazy_default_kind_picks_map_for_plain_struct() raises:
    var wire = String('{"x": 1, "y": 2}')
    var lz = from_json_string[Lazy[_LazyRecord, ImmutAnyOrigin]](wire)
    var r = lz.get()
    assert_equal(r.x, 1)
    assert_equal(r.y, 2)


def test_lazy_serialize_surfaces_get_failure() raises:
    # `kind` (`Map`, from `__pick_kind`) only validates the captured span's
    # *shape* -- that it is a `{...}` object -- at capture time. Whether it
    # satisfies `_LazyRecord`'s own required fields is only checked when
    # `get()` re-parses it. `{"x": 1}` is a well-formed object missing the
    # required `y` field: capture succeeds, `get()` fails. `serialize`'s
    # `_checked_get` must convert that failure into a `SerializationError`
    # that surfaces through `to_json_string`, not crash or produce bad
    # output silently.
    var wire = String('{"x": 1}')
    var lz = from_json_string[Lazy[_LazyRecord, ImmutAnyOrigin]](wire)

    with assert_raises():
        _ = lz.get()  # sanity: get() itself does fail on this input

    with assert_raises():
        _ = to_json_string(lz)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
