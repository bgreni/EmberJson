from .value import Value, Null
from .json import JSON
from .array import Array
from .object import Object
from .utils import write, write_pretty, PaddedBuffer, PAD_INPUT_THRESHOLD

# The public `deserialize`/`try_deserialize`/`serialize`/`to_string` names
# below are thin wrappers over `emberjson._serde`'s `from_json_string`/
# `to_json_string`, which drive emberserde's format-agnostic framework over
# the same hand-written `Parser`.
from ._deserialize import (
    Parser,
    ParseOptions,
    minify,
    StrictOptions,
)

# Imported under private names ON PURPOSE. `emberjson._serde` is the format
# layer, not part of the public surface: re-exporting `from_json_string` /
# `to_json_string` here gave callers a second way to deserialize with
# DIFFERENT semantics from `deserialize` below (which validates UTF-8 first,
# where the format layer does not). Reach for `emberjson._serde` explicitly
# if you really want the unvalidated entry point.
from ._serde import (
    from_json_string as _from_json_string,
    to_json_string as _to_json_string,
)
from .jsonl import read_lines, write_lines
from .traits import JsonValue
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
# Both ride `emberjson._serde`'s `from_json_string`, i.e. emberserde's
# format-agnostic `deserialize` framework driven by
# `EmberJsonDeserializer` over the same hand-written `Parser`. Errors are
# raised typed at the source (`DeserializationError` with a real `kind`
# and, for a nested failure, a real `path`) rather than reconstructed from
# message text at this boundary.


def deserialize[
    T: Deinitable & Movable, options: ParseOptions = ParseOptions()
](s: String, out res: T) raises DeserializationError:
    """Deserializes a JSON string into `T` via reflection.

    Parameters:
        T: The type to deserialize into.
        options: The parsing options to be applied, exactly as on `parse`
            (`ignore_unicode`, `strict_mode`, `validate_utf8`).

    Args:
        s: The input JSON string.

    Returns:
        The deserialized value.

    Raises:
        `DeserializationError` if `s` is not valid UTF-8, is not valid
        JSON, or does not match the shape of `T`.
    """
    comptime if options.validate_utf8:
        if not is_valid_utf8(StringSlice(s)):
            raise DeserializationError(
                "Invalid UTF-8 in input", DerErrorKind.InvalidValue
            )
    res = _from_json_string[T, options](s)


def try_deserialize[
    T: Deinitable & Movable, options: ParseOptions = ParseOptions()
](s: String) -> Optional[T]:
    """Deserializes a JSON string into `T`, or `None` on any failure.

    Parameters:
        T: The type to deserialize into.
        options: The parsing options to be applied, exactly as on `parse`.

    Args:
        s: The input JSON string.

    Returns:
        The deserialized value, or `None` if `s` could not be
        deserialized into `T`.
    """
    try:
        return deserialize[T, options](s)
    except:
        return {}


# ===============================================
# `serialize`
# ===============================================
#
# Rides `emberjson._serde`'s `to_json_string`, i.e. emberserde's
# format-agnostic `serialize` framework driven by `EmberJsonSerializer`.
# Unlike the superseded reflection writer, this one really can raise:
# a `Serializable` implementation is free to fail (see `Lazy.serialize`,
# which surfaces a failing `get()` as a `SerializationError`).


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
    output = _to_json_string[pretty=pretty](value)
