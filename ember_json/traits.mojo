from utils import Variant


trait PrettyPrintable:
    fn pretty_to[W: Writer](self, mut writer: W, indent: String):
        ...


trait StringSize:
    fn min_size_for_string(self) -> Int:
        ...


trait JsonValue(EqualityComparableCollectionElement, Writable, Stringable, Representable, StringSize):
    pass
