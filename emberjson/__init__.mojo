from .value import Value, Null
from .json import JSON
from .array import Array
from .object import Object
from .utils import write, write_pretty, PaddedBuffer, PAD_INPUT_THRESHOLD
from ._deserialize import (
    Parser,
    ParseOptions,
    minify,
    deserialize,
    try_deserialize,
    JsonDeserializable,
    StrictOptions,
)
from .jsonl import read_lines, write_lines
from .traits import JsonValue
from ._serialize import (
    JsonSerializable,
    serialize,
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
from .gpu import (
    GpuSession,
    gpu_is_valid_utf8,
    gpu_parse_document,
    gpu_parse_documents,
    try_gpu_parse_document,
)

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


@always_inline
def parse[
    options: ParseOptions = ParseOptions()
](out j: Value, s: StringSlice) raises:
    """Parses a JSON object from a String.

    Parameters:
        options: The parsing options to be applied.

    Args:
        s: The input String.

    Returns:
        A JSON object.

    Raises:
        If an invalid JSON string is provided.
    """
    comptime if options.validate_utf8:
        if not is_valid_utf8(s):
            raise Error("Invalid UTF-8 in input")
    # Copy the input into a NUL-padded buffer (one memcpy, cheap relative to
    # parsing) so the parser's hot loops can skip per-byte bounds checks.
    # Safe because the returned Value owns all of its data. Tiny inputs skip
    # the copy: the allocation would cost more than the parse.
    if s.byte_length() < PAD_INPUT_THRESHOLD:
        var p = Parser[options=options](s)
        j = p.parse()
    else:
        var buf = PaddedBuffer(s.as_bytes())
        var p = Parser[options=options._padded()](padded=buf)
        j = p.parse()


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
def to_string[*, pretty: Bool = False](out s: String, j: Value):
    """Stringifies the given JSON object.

    Parameters:
        pretty: Pretty prints the object is True, else uses condensed representation.

    Args:
        j: The input JSON object to be stringified.

    Returns:
        The String representation of the JSON object.
    """
    s = serialize[pretty=pretty](j)
