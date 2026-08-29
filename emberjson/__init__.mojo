from .value import Value, Null
from .json import JSON
from .array import Array
from .object import Object
from .utils import write, write_pretty, PaddedBuffer, PAD_INPUT_THRESHOLD

# `deserialize`/`serialize` are imported under private aliases rather than
# re-exported directly: the public `deserialize`/`serialize`/`to_string`
# names below are thin wrappers around these same (still bare-`Error`-
# raising) implementations that translate what they raise into emberserde's
# typed `DeserializationError`/`SerializationError`. The `Parser`-taking
# `deserialize` overloads and the `Serializer`-taking `serialize` overload
# are re-exported unchanged (see the forwarding overloads below `parse`) —
# `emberjson/schema.mojo`'s old-path `JsonDeserializable`/`JsonSerializable`
# conformances call exactly those, under a bare `raises`, and must keep
# compiling untouched (Task 7 does not modify `schema.mojo`).
from ._deserialize import (
    Parser,
    ParseOptions,
    minify,
    deserialize as _reflect_deserialize,
    try_deserialize,
    JsonDeserializable,
    StrictOptions,
)
from .jsonl import read_lines, write_lines
from .traits import JsonValue
from ._serialize import (
    JsonSerializable,
    serialize as _reflect_serialize,
    PrettySerializer,
    Serializer,
)
from ._pointer import PointerIndex

from .lazy import (
    Lazy,
    LazyString,
    LazyInt,
    LazyUInt,
    LazyFloat,
    Lazy,
    LazyValue,
)

from .document import (
    Document,
    DocValue,
    DocObject,
    DocArray,
    DocEntry,
    parse_document,
    try_parse_document,
)

from ._deserialize.query import parse_pointer, try_parse_pointer
from ._utf8 import is_valid_utf8

from .schema import (
    Range,
    ExclusiveRange,
    Size,
    NonEmpty,
    StartsWith,
    EndsWith,
    OneOf,
    AnyOf,
    NoneOf,
    Enum,
    AllOf,
    Eq,
    Ne,
    Not,
    Unique,
    Validated,
    Validator,
    Secret,
    Clamp,
    Coerce,
    CoerceInt,
    CoerceUInt,
    CoerceFloat,
    CoerceString,
    Default,
    Transform,
    MultipleOf,
)

# `Default` is now emberserde's `Field[T, default=...]`; re-export the
# upstream names so the wrapper can be spelled either way.
from emberserde import Defaulted, Field

# Typed errors that the public API (`parse`, `try_parse`, `to_string`,
# `serialize`, `deserialize`, `try_deserialize`) raises instead of a bare
# `Error` (see the wrapper definitions below `parse`). Re-exported so a
# caller can write `from emberjson import DeserializationError` without
# reaching into `emberserde` directly.
from emberserde.error import (
    DeserializationError,
    DerErrorKind,
    SerializationError,
    SerErrorKind,
)


# EmberJson's schema wrappers are all read through `w[]`, and `Field` keeps
# that spelling so `Default` stays a drop-in for the struct it replaced
# (`w.value`, emberserde's own spelling, works as well).
#
# This lives HERE, not in `schema.mojo`, because an `__extension` that adds
# a *method* to a foreign type is only visible where the module declaring
# it is itself in scope. Next to the re-export above, `from emberjson
# import Field` alone is enough; in `schema.mojo` it would have silently
# required the caller to also import `emberjson.schema`, which is exactly
# the trap `from emberjson import Defaulted` + `f[]` fell into.
__extension Field:
    def __getitem__(self) -> ref[self.value] Self.T:
        return self.value


@always_inline
def parse[
    options: ParseOptions = ParseOptions()
](out j: Value, s: StringSlice) raises DeserializationError:
    """Parses a JSON object from a String.

    Parameters:
        options: The parsing options to be applied.

    Args:
        s: The input String.

    Returns:
        A JSON object.

    Raises:
        `DeserializationError` if an invalid JSON string is provided.
    """
    comptime if options.validate_utf8:
        if not is_valid_utf8(s):
            raise DeserializationError(
                "Invalid UTF-8 in input", DerErrorKind.InvalidValue
            )
    # Copy the input into a NUL-padded buffer (one memcpy, cheap relative to
    # parsing) so the parser's hot loops can skip per-byte bounds checks.
    # Safe because the returned Value owns all of its data. Tiny inputs skip
    # the copy: the allocation would cost more than the parse.
    #
    # `Parser.parse()` (`emberjson/_deserialize/parser.mojo`, never modified
    # by this package) still raises a bare `Error` -- every syntax failure
    # it can produce is a malformed-JSON condition, so it is translated to
    # `DeserializationError(..., DerErrorKind.InvalidValue)` here rather
    # than propagated untyped.
    if s.byte_length() < PAD_INPUT_THRESHOLD:
        var p = Parser[options=options](s)
        try:
            j = p.parse()
        except e:
            raise DeserializationError(String(e), DerErrorKind.InvalidValue)
    else:
        var buf = PaddedBuffer(s.as_bytes())
        var p = Parser[options=options._padded()](padded=buf)
        try:
            j = p.parse()
        except e:
            raise DeserializationError(String(e), DerErrorKind.InvalidValue)


@always_inline
def try_parse[
    options: ParseOptions = ParseOptions()
](s: String) -> Optional[Value]:
    try:
        return parse[options](s)
    except:
        return {}


@always_inline
def to_string(out s: String, d: Document):
    """Stringifies the given `Document` (identical output to stringifying
    the equivalent `Value`).

    Args:
        d: The input document to be stringified.

    Returns:
        The String representation of the document.
    """
    s = d.to_string()


@always_inline
def to_string[
    *, pretty: Bool = False
](out s: String, j: Value) raises SerializationError:
    """Stringifies the given JSON object.

    Parameters:
        pretty: Pretty prints the object is True, else uses condensed representation.

    Args:
        j: The input JSON object to be stringified.

    Returns:
        The String representation of the JSON object.

    Raises:
        `SerializationError` if the value cannot be serialized.
    """
    s = serialize[pretty=pretty](j)


# ===============================================
# `deserialize` / `try_deserialize`
# ===============================================
#
# `_reflect_deserialize` (aliased above) is EmberJson's pre-existing
# hand-written reflection walker (`emberjson/_deserialize/reflection.mojo`,
# not modified by this task -- `schema.mojo`'s old-path conformances and
# `Lazy` depend on it staying exactly as it is). It still raises a bare
# `Error` internally. The `String`-taking overload below is the one public
# entry point the brief asks to carry a typed error; the `Parser`-taking
# overloads are re-exported unchanged immediately after it, because
# `emberjson/schema.mojo`'s `from_json` methods call them directly under a
# bare `raises` and must keep compiling untouched.


def _classify_deserialize_error(var msg: String) -> DeserializationError:
    # `_reflect_deserialize`'s own struct-walking loop
    # (`_default_deserialize` in `_deserialize/reflection.mojo`) raises
    # exactly these three literal messages for the shape errors it detects
    # itself; everything else reaching here is a `Parser`-level "expected
    # token X, found Y" failure, i.e. the value was present but the wrong
    # shape for the field it is bound to.
    if msg.startswith("Missing key: "):
        return DeserializationError(msg^, DerErrorKind.MissingField)
    elif msg.startswith("Duplicate key: "):
        return DeserializationError(msg^, DerErrorKind.DuplicateField)
    elif msg.startswith("Unexpected field: "):
        return DeserializationError(msg^, DerErrorKind.UnknownField)
    else:
        return DeserializationError(msg^, DerErrorKind.TypeMismatch)


def deserialize[
    T: Deinitable & Movable
](s: String, out res: T) raises DeserializationError:
    """Deserializes a JSON string into `T` via reflection.

    Parameters:
        T: The type to deserialize into.

    Args:
        s: The input JSON string.

    Returns:
        The deserialized value.

    Raises:
        `DeserializationError` if `s` is not valid UTF-8, is not valid
        JSON, or does not match the shape of `T`.
    """
    if not is_valid_utf8(StringSlice(s)):
        raise DeserializationError(
            "Invalid UTF-8 in input", DerErrorKind.InvalidValue
        )
    var p = Parser(s)
    try:
        res = _reflect_deserialize[T](p)
    except e:
        raise _classify_deserialize_error(String(e))


# `Parser`-taking overloads, re-exported unchanged (still a bare `raises`):
# these back `emberjson/schema.mojo`'s `JsonDeserializable.from_json`
# implementations (e.g. `s = {deserialize[Self.T](p)}`), which are
# themselves declared with a bare `raises` and must keep compiling as-is.
@always_inline
def deserialize[
    origin: ImmOrigin, options: ParseOptions, //, T: Deinitable & Movable
](mut p: Parser[origin, options], out res: T) raises:
    res = _reflect_deserialize[T](p)


@always_inline
def deserialize[
    origin: ImmOrigin, options: ParseOptions, //, T: Deinitable & Movable
](var p: Parser[origin, options], out res: T) raises:
    res = _reflect_deserialize[T](p)


# ===============================================
# `serialize`
# ===============================================
#
# `_reflect_serialize` (aliased above) is the pre-existing reflection-based
# writer (`emberjson/_serialize/reflection.mojo`, not modified by this
# task). Neither of its overloads can currently raise (JSON serialization
# of an in-memory value never fails), so `raises SerializationError` below
# is a signature-level contract for callers -- consistent with `to_string`
# above and forward-compatible with a future implementation that can fail
# (e.g. a custom `Serializable` type) -- rather than a path this old
# implementation can presently take.


def serialize[
    T: AnyType, //, *, pretty: Bool = False
](value: T, out output: String) raises SerializationError:
    """Serializes `value` to a JSON string via reflection.

    Parameters:
        T: The type to serialize.
        pretty: Pretty-prints the output if True, else uses a condensed
            representation.

    Args:
        value: The value to serialize.

    Returns:
        The JSON string representation of `value`.

    Raises:
        `SerializationError` if `value` cannot be serialized.
    """
    output = _reflect_serialize[pretty=pretty](value)


# `Serializer`-taking overload, re-exported unchanged (no `raises`):
# `emberjson/schema.mojo`'s `JsonSerializable.write_json` implementations
# (e.g. `serialize(self.value, writer)`) call this directly from a
# non-raising method and must keep compiling as-is.
@always_inline
def serialize[T: AnyType, //](value: T, mut writer: Some[Serializer]):
    _reflect_serialize(value, writer)
