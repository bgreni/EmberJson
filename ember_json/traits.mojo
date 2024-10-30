from utils import Variant

alias DefaultPrettyIndent = String(" ") * 4


trait PrettyPrintable:
    fn pretty_to[W: Writer](self, inout writer: W, indent: Variant[Int, String] = DefaultPrettyIndent):
        ...


trait JsonValue(EqualityComparableCollectionElement, Writable, Stringable, Representable):
    pass
