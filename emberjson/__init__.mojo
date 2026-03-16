from .value import Value, Null
from .json import JSON
from .array import Array
from .object import Object
from .utils import write, write_pretty
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

from .schema import (
    Range,
    Size,
    OneOf,
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
    AllOf,
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
    var p = Parser[options=options](s)
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
