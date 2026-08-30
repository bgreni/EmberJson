from std.python import ConvertibleToPython
from emberserde.serialize import Serializable
from emberserde.deserialize import Deserializable


trait JsonValue(
    Boolable,
    ConvertibleToPython,
    Copyable,
    Defaultable,
    Deserializable,
    Equatable,
    Movable,
    Serializable,
    Writable,
):
    pass
