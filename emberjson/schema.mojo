from emberjson import (
    JsonDeserializable,
    JsonSerializable,
    Parser,
    ParseOptions,
    Serializer,
    serialize,
)
from emberjson._deserialize.reflection import _deserialize_impl


@fieldwise_init
struct Range[T: Comparable & Movable, min: T, max: T](
    JsonDeserializable, JsonSerializable
):
    var value: Self.T

    @staticmethod
    fn from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))
        s.value = _deserialize_impl[Self.T](p)

        if (
            s.value < materialize[Self.min]()
            or s.value > materialize[Self.max]()
        ):
            raise Error("Value out of range")

    fn write_json(self, mut writer: Some[Serializer]):
        serialize(self.value, writer)
