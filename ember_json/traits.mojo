trait BytesForString:
    """Number of bytes the value needs to be be converted to a string"""

    fn bytes_for_string(self) -> Int:
        pass


trait JsonValue(EqualityComparableCollectionElement, Writable, Stringable, Representable, BytesForString):
    pass
