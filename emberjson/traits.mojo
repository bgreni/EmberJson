from std.python import ConvertibleToPython
from emberserde.serialize import Serializable
from emberserde.deserialize import Deserializable


trait PrettyPrintable:
    def pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        ...


trait JsonValue(
    Boolable,
    ConvertibleToPython,
    Copyable,
    Defaultable,
    Deserializable,
    Equatable,
    Movable,
    PrettyPrintable,
    Serializable,
    Writable,
):
    pass
