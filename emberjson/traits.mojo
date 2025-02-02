from utils import Variant


trait PrettyPrintable:
    fn pretty_to[W: Writer](self, mut writer: W, indent: String, *, curr_depth: Int = 0):
        ...


trait StringSize:
    fn min_size_for_string(self) -> Int:
        ...


trait JsonValue(
    EqualityComparableCollectionElement,
    Writable,
    Stringable,
    Representable,
    StringSize,
    Defaultable,
    Boolable,
    ImplicitlyBoolable,
    ExplicitlyCopyable,
    PrettyPrintable,
):
    pass
