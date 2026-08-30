from .value import Value, Null
from .json import JSON
from .array import Array
from .object import Object
from .utils import write, PaddedBuffer, PAD_INPUT_THRESHOLD
from std.builtin.rebind import rebind_var as _rebind_var

# The public `deserialize`/`try_deserialize`/`serialize`/`to_string` names
# below are thin wrappers over `emberjson._serde`'s `from_json`/
# `to_json`, which drive emberserde's format-agnostic framework over
# the same hand-written `Parser`.
from ._deserialize import (
    Parser,
    ParseOptions,
    minify,
    StrictOptions,
)

# Imported under private names ON PURPOSE. `emberjson._serde` is the format
# layer, not part of the public surface: re-exporting `from_json` /
# `to_json` here gave callers a second way to deserialize with
# DIFFERENT semantics from `deserialize` below (which validates UTF-8 first,
# where the format layer does not). Reach for `emberjson._serde` explicitly
# if you really want the unvalidated entry point.
from ._serde import (
    from_json as _from_json,
    to_json as _to_json,
    DefaultIndent,
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
    _parse_document_root,
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


def _parse_value_root[
    options: ParseOptions
](s: StringSlice, out j: Value) raises DeserializationError:
    """`from_json[Value]`'s parse, with the UTF-8 pre-pass removed.

    Copies the input into a NUL-padded buffer (one memcpy, cheap relative
    to parsing) so the parser's hot loops can skip per-byte bounds checks.
    Safe because the returned `Value` owns all of its data. Tiny inputs
    skip the copy: the allocation would cost more than the parse.

    `Parser.parse()` still raises a bare `Error`; every syntax failure it
    can produce is a malformed-JSON condition, so it is translated to
    `DeserializationError(..., DerErrorKind.InvalidValue)` here rather
    than propagated untyped.
    """
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


def from_json[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](s: StringSlice[o], out result: T) raises DeserializationError:
    """Deserializes JSON text into `T`.

    The single deserialization entry point. `T` selects the strategy at
    compile time:

    - `Value` -- the hand-written recursive-descent parser, into the
      mutable `Value` variant.
    - `Document` -- the immutable tape parser: no per-node allocation,
      several times faster on document-heavy input.
    - anything else -- emberserde's reflection framework, driven by
      `EmberJsonDeserializer` over the same hand-written `Parser`.

    UTF-8 is validated once here, before dispatch, so every strategy sees
    the same rule. `ParseOptions(validate_utf8=False)` skips the check for
    trusted input.

    Parameters:
        T: The type to deserialize into.
        options: The parsing options to be applied.

    Args:
        s: The input JSON text.

    Returns:
        The deserialized value.

    Raises:
        `DeserializationError` if `s` is not valid UTF-8, is not valid
        JSON, or does not match the shape of `T`.
    """
    comptime if options.validate_utf8:
        if not is_valid_utf8(s):
            raise DeserializationError(
                "Invalid UTF-8 in input", DerErrorKind.InvalidValue
            )
    # Validation has run; clear the flag so no branch repeats it.
    comptime checked = options._utf8_validated()
    comptime if T == Value:
        result = _rebind_var[T](_parse_value_root[checked](s))
    elif T == Document:
        # `_parse_document_root` still raises a bare `Error`; translate it
        # so this entry point's contract is uniformly typed.
        try:
            result = _rebind_var[T](_parse_document_root[checked](s))
        except e:
            raise DeserializationError(String(e), DerErrorKind.InvalidValue)
    else:
        # NOTE: the reflection branch must stay UNPADDED. `raw_bytes`
        # refuses `_assume_padded` because a `PaddedBuffer` is a local
        # that does not outlive the call, so every borrowing type
        # (`Lazy`, `LazyString`, ...) would dangle. See the spec's
        # "Known limitation".
        result = _from_json[T, checked](s)


def try_from_json[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](s: StringSlice[o]) -> Optional[T]:
    """Deserializes JSON text into `T`, or `None` on any failure.

    Parameters:
        T: The type to deserialize into.
        options: The parsing options to be applied, exactly as on
            `from_json`.

    Args:
        s: The input JSON text.

    Returns:
        The deserialized value, or `None` if `s` could not be
        deserialized into `T`.
    """
    try:
        return from_json[T, options](s)
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
# Both ride `emberjson._serde`'s `from_json`, i.e. emberserde's
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
    res = _from_json[T, options](s)


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
# Rides `emberjson._serde`'s `to_json`, i.e. emberserde's
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
    output = _to_json[pretty=pretty](value)


def write_pretty[
    T: AnyType, //, indent: String = DefaultIndent
](value: T, out output: String) raises SerializationError:
    """Serializes `value` to an indented JSON string.

    Parameters:
        T: The type to serialize.
        indent: The string one nesting level costs. A comptime parameter, so
            `write_pretty[indent="\\t"](v)` picks tabs.

    Args:
        value: The value to serialize.

    Returns:
        The indented JSON string representation of `value`.

    Raises:
        `SerializationError` if `value` cannot be serialized.
    """
    output = _to_json[pretty=True, indent=indent](value)


# ===============================================
# `to_json` / `to_json_pretty`
# ===============================================
#
# The unified serialization entry points. `Document` writes straight off
# its tape; everything else (`Value`, `Array`, `Object`, and reflected
# structs) rides emberserde's `Serializable` framework via
# `emberjson._serde.to_json`.


def to_json[
    T: AnyType, //, pretty: Bool = False, indent: String = DefaultIndent
](value: T, out output: String) raises SerializationError:
    """Serializes `value` to JSON text.

    The single serialization entry point. `Document` is written straight
    off its tape; everything else rides emberserde's reflection
    framework, which already covers `Value`, `Array` and `Object` through
    their own `Serializable` implementations.

    Parameters:
        T: The type to serialize.
        pretty: Pretty-prints the output if True, else uses a condensed
            representation.
        indent: The string one nesting level costs when `pretty`.

    Args:
        value: The value to serialize.

    Returns:
        The JSON text representation of `value`.

    Raises:
        `SerializationError` if `value` cannot be serialized.
    """
    comptime if T == Document:
        # `Document` writes straight off the tape and has only a
        # condensed writer -- there is no indented tape walk to call.
        # Deliberately a compile-time failure rather than a silent
        # fallback to condensed output. Parse into a `Value` if you need
        # indented output from tape input.
        comptime assert not pretty, (
            "Document has no pretty-print path; parse into a Value if you"
            " need indented output"
        )
        output = rebind[Document](value).to_string()
    else:
        output = _to_json[pretty=pretty, indent=indent](value)


def to_json_pretty[
    T: AnyType, //, indent: String = DefaultIndent
](value: T, out output: String) raises SerializationError:
    """Serializes `value` to indented JSON text.

    A wrapper rather than a parameter-bound alias on purpose: binding a
    parameter on an alias leaves it a generator type, so
    `to_json_pretty(v)` would not call and every use would need
    `to_json_pretty[](v)`.

    Parameters:
        T: The type to serialize.
        indent: The string one nesting level costs. A comptime parameter,
            so `to_json_pretty[indent="\\t"](v)` picks tabs.

    Args:
        value: The value to serialize.

    Returns:
        The indented JSON text representation of `value`.

    Raises:
        `SerializationError` if `value` cannot be serialized.
    """
    output = to_json[pretty=True, indent=indent](value)
