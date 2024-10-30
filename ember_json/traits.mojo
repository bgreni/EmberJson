from utils import Variant


trait PrettyPrintable:
    fn pretty_to[W: Writer](self, inout writer: W, indent: String):
        ...


trait JsonValue(EqualityComparableCollectionElement, Writable, Stringable, Representable):
    pass
