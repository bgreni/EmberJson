trait Deserializer(ImplicitlyDestructible):
    fn peek(self) raises -> Byte:
        ...

    fn expect(mut self, b: Byte) raises:
        ...

    fn read_string(mut self) raises -> String:
        ...

    fn expect_integer[
        type: DType = DType.int64
    ](mut self) raises -> Scalar[type]:
        ...

    fn expect_unsigned_integer[
        type: DType = DType.uint64
    ](mut self) raises -> Scalar[type]:
        ...

    fn expect_float[
        type: DType = DType.float64
    ](mut self) raises -> Scalar[type]:
        ...

    fn expect_bool(mut self) raises -> Bool:
        ...

    fn expect_null(mut self) raises:
        ...

    fn skip_whitespace(mut self) raises:
        ...
