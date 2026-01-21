from std.reflection import (
    struct_field_count,
    struct_field_types,
    struct_field_names,
    is_struct_type,
)

from std.builtin.rebind import downcast

from .parser import Parser
from emberjson.constants import `{`, `}`, `:`, `,`, `t`, `f`, `n`, `[`, `]`
from std.sys.intrinsics import unlikely
from emberjson.utils import to_string
from ._parser_helper import NULL

comptime non_struct_error = "Cannot deserialize non-struct type"


trait JsonDeserializable(Defaultable, Movable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        s = _default_deserialize[Self](j)


fn deserialize[T: Defaultable & Movable](var j: Parser, out s: T) raises:
    s = _deserialize_impl[T](j)


@always_inline
fn _default_deserialize[
    T: Defaultable & Movable
](mut j: Parser, out s: T) raises:
    s = T()
    comptime field_count = struct_field_count[T]()
    comptime types = struct_field_types[T]()
    j.expect(`{`)

    @parameter
    for i in range(field_count):
        var ident = j.read_string()
        j.expect(`:`)
        comptime TField = downcast[types[i], Movable & Defaultable]
        __comptime_assert is_struct_type[TField](), non_struct_error
        var field = UnsafePointer(to=__struct_field_ref(i, s))
        field.bitcast[TField]()[] = _deserialize_impl[TField](j)

        @parameter
        if i < field_count - 1:
            j.expect(`,`)
    j.expect(`}`)


fn _deserialize_impl[T: Defaultable & Movable](mut j: Parser, out s: T) raises:
    __comptime_assert is_struct_type[T](), non_struct_error

    @parameter
    if conforms_to(T, JsonDeserializable):
        s = rebind_var[T](downcast[T, JsonDeserializable].from_json(j))
    else:
        s = _default_deserialize[T](j)


__extension String(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        s = j.read_string()


__extension Int(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        # TODO: Make this specifically parse an integer
        s = Int(j.parse_number().int())


__extension Bool(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        s = j.expect_bool()


__extension SIMD(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        @parameter
        if dtype.is_numeric():

            @parameter
            if dtype.is_floating_point():
                s = j.parse_number().float().cast[dtype]()
            else:

                @parameter
                if dtype.is_signed():
                    s = j.parse_number().int().cast[dtype]()
                else:
                    s = j.parse_number().uint().cast[dtype]()
        else:
            s = Self(j.expect_bool())


__extension Optional(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        if j.data[] == `n`:
            if unlikely(j.bytes_remaining() < 3):
                raise Error("Encountered EOF when expecting 'null'")
            # Safety: Safe because we checked the amount of bytes remaining
            var w = j.data.p.bitcast[UInt32]()[0]
            if w != NULL:
                raise Error("Expected 'null', received: ", to_string(w))
            s = None
            j.data += 4
        else:
            s = Self(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, Defaultable & Movable]](
                        j
                    )
                )
            )


__extension List(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Parser, out s: Self) raises:
        j.expect(`[`)
        s = Self()
        var i = 0
        while j.peek() != `]`:
            s.append(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, Defaultable & Movable]](
                        j
                    )
                )
            )
            j.skip_whitespace()
            if j.peek() != `]`:
                j.expect(`,`)
        j.expect(`]`)


# __extension InlineArray(JsonDeserializable):
#     @staticmethod
#     fn from_json(mut j: Parser, out s: Self) raises:
#         j.expect(`[`)
#         s = Self(uninitialized=True)

#         for i in range(size):
#             # error: '<unknown>' abandoned without being explicitly destroyed: Unhandled explicit_destroy type Copyable
#             s[i] = rebind_var[Self.ElementType](_deserialize_impl[downcast[Self.ElementType, Defaultable & Movable]](j))

#             if i != size - 1:
#                 j.expect(`,`)

#         j.expect(`]`)
