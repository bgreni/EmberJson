from python import ConvertibleToPython


trait PrettyPrintable:
    fn pretty_to[
        W: Writer
    ](self, mut writer: W, indent: String, *, curr_depth: UInt = 0):
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
