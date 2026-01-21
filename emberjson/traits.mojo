from python import ConvertibleToPython
from emberjson._serialize import JsonSerializable
from emberjson._deserialize import JsonDeserializable


trait PrettyPrintable:
    fn pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        ...


trait JsonValue(
    Boolable,
    ConvertibleToPython,
    Copyable,
    Defaultable,
    Equatable,
    JsonDeserializable,
    JsonSerializable,
    Movable,
    PrettyPrintable,
    Representable,
    Stringable,
    Writable,
):
    pass
