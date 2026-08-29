from ._deserialize.parser import Parser
from ._serde.deserializer import EmberJsonDeserializer
from .value import Value
from std.hashlib import Hasher

# See `value.mojo` for why these are aliased.
from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializer as SerdeDeserializer,
    Deserializable,
    RawKind,
    deserialize as _serde_deserialize,
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


def _deserialize_bytes[
    T: Base, origin: ImmOrigin
](b: Span[Byte, origin]) raises -> T:
    var p = Parser(b)
    var d = EmberJsonDeserializer(p=Pointer(to=p))
    return _serde_deserialize[T](d)


@fieldwise_init
struct Lazy[
    T: Base,
    origin: ImmOrigin,
    # A struct always rides the wire as a JSON object, so `Map` is the
    # right default for a bare `Lazy[T, origin]`. Anything else (a string,
    # a number, a bare array, an unconstrained value) names its `kind`
    # explicitly -- see the `LazyString`/`LazyInt`/... aliases below.
    kind: RawKind = RawKind.Map,
](
    Deserializable,
    Hashable,
    Serializable,
    TrivialRegisterPassable,
):
    """Zero-copy capture of one JSON value's raw wire bytes.

    Deserializing a `Lazy` only records the `Span` covering its token (via
    `BorrowingDeserializer.raw_bytes[kind]`); no interpretation happens
    until `get()`, which re-parses that span through a fresh `Parser`.

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
