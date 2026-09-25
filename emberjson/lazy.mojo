from ._deserialize.parser import Parser
from ._serde.deserializer import EmberJsonDeserializer
from ._serde.indexed import RawCapture
from .value import Value
from std.hashlib import Hasher

# The free functions `serialize`/`deserialize` are aliased below because
# `Lazy` declares methods of the same name.
from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializer,
    Deserializable,
    RawKind,
    deserialize as _serde_deserialize,
)
from emberserde.serialize import (
    Serializer,
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
    RawCapture,
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

    Lifetime safety -- the `origin` parameter is TRUSTED, not checked:

    - It must be the origin of the input actually passed to `from_json`.
      Nothing verifies this: the span reaches `deserialize` through
      emberserde's generic `raw_bytes` as `ImmUntrackedOrigin` (Mojo 1.1.0
      cannot carry the input's origin through a trait) and is re-labelled
      with whatever `origin` names. `from_json[LazyValue[ImmutAnyOrigin]]`,
      or an origin of some other variable, compiles and leaves a dangling
      span once the input dies; `get()` then re-parses freed memory, which
      usually yields plausible but wrong data rather than a crash.
    - Reassigning or appending to the source while the `Lazy` is alive is
      NOT caught when the origin is the whole variable's (`origin_of(s)`);
      that is a language property shared by every view, `StringSlice(s)`
      included. Borrow from the string's interior instead, which the
      compiler does track:

      ```mojo
      var src = s[byte=:]
      var l = from_json[LazyValue[src.origin]](src)
      s = other  # error: use of invalidated interior reference
      ```
    """

    var _data: Span[Byte, Self.origin]

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            type_of(d), BorrowingDeserializer
        ), "Lazy requires a borrowing deserializer"
        # Unchecked re-label of an untracked span: see "Lifetime safety" in
        # the struct docstring.
        return Self(rebind[Span[Byte, Self.origin]](d.raw_bytes[Self.kind]()))

    def _checked_get(self) raises SerializationError -> Self.T:
        try:
            return self.get()
        except e:
            raise SerializationError(String(e), SerErrorKind.Custom)

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
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
        h.update(self._data)

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
