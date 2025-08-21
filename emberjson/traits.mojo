from python import ConvertibleToPython


trait PrettyPrintable:
    fn pretty_to(self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0):
        ...


trait JsonValue(
    Boolable,
    ConvertibleToPython,
    Copyable,
    Defaultable,
    EqualityComparable,
    ExplicitlyCopyable,
    ImplicitlyBoolable,
    Movable,
    PrettyPrintable,
    Representable,
    Stringable,
    Writable,
):
    pass
