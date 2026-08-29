from ._deserialize.reflection import (
    _Base,
    JsonDeserializable,
    _deserialize_impl,
)
from ._deserialize.parser import Parser, ParseOptions
from .value import Value
from std.hashlib import Hasher
from std.builtin.rebind import downcast

# emberserde's `Deserializer` is aliased to avoid colliding with the name
# of EmberJson's own (pre-existing) `Deserializer` trait, which `from_json`
# below still serves: `Lazy` keeps direct conformance to the old
# `JsonDeserializable` trait alongside the new `Deserializable` until the
# deserialize half of the old layer retires too.
from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializer as SerdeDeserializer,
    Deserializable,
    RawKind,
)
from emberserde.serialize import (
    Serializer as SerdeSerializer,
    Serializable,
    serialize as _serde_serialize,
)
from emberserde.error import (
    DeserializationError,
    SerializationError,
    SerErrorKind,
)
from emberserde.utils import Base


def _expect_kind_bytes[
    origin: ImmOrigin, //, kind: RawKind
](mut p: Parser[origin]) raises -> Span[Byte, origin]:
    """Dispatches to the `Parser` byte-extractor matching `kind`.

    Consolidates what used to be six separate `_get_*_bytes` free functions
    (one per shape, picked via a stored function pointer) behind a single
    `RawKind`-keyed `comptime if`. Mirrors `EmberJsonDeserializer.raw_bytes`'s
    dispatch in `emberjson/_serde/deserializer.mojo`, except `Str` calls
    `expect_string_bytes` directly with no extra whitespace/quote check --
    matching this (old, `Parser`-driven) path's original behavior, where the
    caller is already responsible for positioning `p` at the token.
    """
    comptime if kind == RawKind.Any:
        return p.expect_value_bytes()
    elif kind == RawKind.Integer:
        return p.expect_int_bytes()
    elif kind == RawKind.Float:
        return p.expect_float_bytes()
    elif kind == RawKind.Str:
        return p.expect_string_bytes()
    elif kind == RawKind.Seq:
        return p.expect_array_bytes()
    else:
        return p.expect_object_bytes()


def _deserialize_bytes[
    T: _Base, origin: Origin
](b: Span[Byte, origin]) raises -> T:
    var p = Parser(b)
    return _deserialize_impl[T](p)


def __pick_kind[T: Base]() -> RawKind:
    """Default `kind` for a bare `Lazy[T, origin]` (no explicit `kind`).

    Picks `Seq` when `T` opts into array-style JSON via
    `JsonDeserializable.deserialize_as_array`, `Map` otherwise -- the same
    rule `__pick_byte_expect` used to choose between `_get_array_bytes` and
    `_get_object_bytes`.
    """
    comptime if conforms_to(T, JsonDeserializable) and downcast[
        T, JsonDeserializable
    ].deserialize_as_array():
        return RawKind.Seq
    else:
        return RawKind.Map


@fieldwise_init
struct Lazy[
    T: Base,
    origin: ImmOrigin,
    kind: RawKind = __pick_kind[T](),
](
    Deserializable,
    Hashable,
    JsonDeserializable,
    Serializable,
    TrivialRegisterPassable,
):
    """Zero-copy capture of one JSON value's raw wire bytes.

    Deserializing a `Lazy` only records the `Span` covering its token (via
    the old `Parser`-driven path's `_expect_kind_bytes`, or the new
    `BorrowingDeserializer.raw_bytes[kind]`); no interpretation happens
    until `get()`. Both capture paths write the same `_data` field, and
    `get()` always re-parses it through the old `Parser`, regardless of
    which path did the capturing.

    `serialize` does NOT echo the captured span verbatim. emberserde's
    `Serializer` trait has no raw-passthrough hook (only
    `BorrowingDeserializer` does, as `raw_bytes`), so it materializes
    through `get()` (the span is already grammar-validated at capture
    time) and re-serializes that value through the pipeline. That
    re-encoding is only semantically equivalent to the source wire text,
    not byte-identical: whitespace is normalized to compact form, floats
    lose trailing zeros/exponent spelling, object key order can change,
    etc. See `test_serialize_reencodes_rather_than_echoing` in
    `test/emberjson/serde/test_borrow_lazy.mojo` for a pinned example.

    `get()` failing (the captured span parses as the right *shape* --
    `kind` validates only that much -- but not as a valid `T`, e.g. a
    struct missing a required field) surfaces as a `SerializationError`
    from `serialize` (via `_checked_get`), not a crash or silent bad
    output.
    """

    var _data: Span[Byte, Self.origin]

    @staticmethod
    def from_json[
        o: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[o, options], out s: Self) raises:
        # TODO: Remove this restriction when compiler allows
        comptime assert (
            options == ParseOptions()
        ), "Lazy deserialization only works with default parse options"
        s = {_expect_kind_bytes[Self.kind](rebind[Parser[Self.origin]](p))}

    @staticmethod
    def deserialize(
        mut d: Some[SerdeDeserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            type_of(d), BorrowingDeserializer
        ), "Lazy requires a borrowing deserializer"
        return Self(rebind[Span[Byte, Self.origin]](d.raw_bytes[Self.kind]()))

    def _checked_get(self) raises SerializationError -> Self.T:
        try:
            return self.get()
        except e:
            raise SerializationError(String(e), SerErrorKind.Custom)

    def serialize(self, mut s: Some[SerdeSerializer]) raises SerializationError:
        # Re-encodes via `get()`, not a raw echo -- see the struct
        # docstring for why, and for what that costs a caller who wanted
        # the original bytes back.
        _serde_serialize(self._checked_get(), s)

    def get(self) raises -> Self.T:
        return _deserialize_bytes[Self.T](self._data)

    def __getitem__(self) raises -> Self.T:
        return self.get()

    def __eq__(self, other: Self) -> Bool:
        return self._data == other._data

    def __hash__(self, mut h: Some[Hasher]):
        comptime assert conforms_to(Self.T, Hashable)
        h.update(StringSlice(unsafe_from_utf8=self._data))

    def unsafe_as_string_slice(
        self,
    ) -> StringSlice[Self.origin]:
        # TODO: Use where clause when that actually works
        comptime assert Self.T == String
        return StringSlice(unsafe_from_utf8=self._data[1 : len(self._data) - 1])


comptime LazyString[origin: ImmOrigin] = Lazy[String, origin, RawKind.Str]

comptime LazyInt[origin: ImmOrigin] = Lazy[Int64, origin, RawKind.Integer]

comptime LazyUInt[origin: ImmOrigin] = Lazy[UInt64, origin, RawKind.Integer]

comptime LazyFloat[origin: ImmOrigin] = Lazy[Float64, origin, RawKind.Float]

comptime LazyValue[origin: ImmOrigin] = Lazy[Value, origin, RawKind.Any]
