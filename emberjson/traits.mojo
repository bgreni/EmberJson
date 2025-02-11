trait PrettyPrintable:
    fn pretty_to[W: Writer](self, mut writer: W, indent: String, *, curr_depth: Int = 0):
        ...


trait JsonValue(
    EqualityComparableCollectionElement,
    Writable,
    Stringable,
    Representable,
    Defaultable,
    Boolable,
    ImplicitlyBoolable,
    ExplicitlyCopyable,
    PrettyPrintable,
):
    pass
