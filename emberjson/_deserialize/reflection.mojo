from std.reflection import (
    struct_field_count,
    struct_field_types,
    struct_field_names,
    is_struct_type,
)

from std.builtin.rebind import downcast

from .parser import Parser
from emberjson.constants import `{`, `}`, `:`, `,`, `t`, `f`, `n`, `[`, `]`
from std.sys.intrinsics import unlikely, _type_is_eq
from emberjson.utils import to_string
from ._parser_helper import NULL

comptime non_struct_error = "Cannot deserialize non-struct type"


trait JsonDeserializable(Defaultable, Movable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        s = _default_deserialize[Self](p)


fn try_deserialize[T: Defaultable & Movable](var p: Parser) -> Optional[T]:
    try:
        return _deserialize_impl[T](p)
    except:
        return None


fn deserialize[T: Defaultable & Movable](var p: Parser, out s: T) raises:
    s = _deserialize_impl[T](p)


@always_inline
fn _default_deserialize[
    T: Defaultable & Movable
](mut p: Parser, out s: T) raises:
    s = T()
    comptime field_count = struct_field_count[T]()
    comptime field_names = struct_field_names[T]()

    p.expect(`{`)

    for i in range(field_count):
        var ident = p.read_string()
        p.expect(`:`)

        @parameter
        for j in range(field_count):
            comptime name = field_names[j]

            if ident == name:
                ref field = __struct_field_ref(j, s)
                comptime TField = downcast[
                    type_of(field), Movable & Defaultable
                ]

                field = rebind[type_of(field)](_deserialize_impl[TField](p))

        if i < field_count - 1:
            p.expect(`,`)
    p.expect(`}`)


fn _deserialize_impl[T: Defaultable & Movable](mut p: Parser, out s: T) raises:
    __comptime_assert is_struct_type[T](), non_struct_error

    @parameter
    if conforms_to(T, JsonDeserializable):
        s = rebind_var[T](downcast[T, JsonDeserializable].from_json(p))
    else:
        s = _default_deserialize[T](p)


__extension String(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        s = p.read_string()


__extension Int(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        # TODO: Make this specifically parse an integer
        try:
            s = Int(p.parse_number().int())
        except:
            raise Error("Expected integer")


__extension Bool(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        s = p.expect_bool()


__extension SIMD(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        s = Self()

        @parameter
        fn parse_simd_element(mut p: Parser) raises -> Scalar[Self.dtype]:
            @parameter
            if Self.dtype.is_numeric():

                @parameter
                if Self.dtype.is_floating_point():
                    try:
                        return p.parse_number().float().cast[Self.dtype]()
                    except:
                        raise Error("Expected float point number")
                else:

                    @parameter
                    if Self.dtype.is_signed():
                        try:
                            return p.parse_number().int().cast[Self.dtype]()
                        except:
                            raise Error("Expected integer")
                    else:
                        try:
                            return p.parse_number().uint().cast[Self.dtype]()
                        except:
                            raise Error("Expected unsigned integer")
            else:
                return Scalar[Self.dtype](p.expect_bool())

        @parameter
        if size > 1:
            p.expect(`[`)

        @parameter
        for i in range(size):
            s[i] = parse_simd_element(p)

            @parameter
            if i < size - 1:
                p.expect(`,`)

        @parameter
        if size > 1:
            p.expect(`]`)


__extension Optional(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        if p.data[] == `n`:
            p.expect_null()
            s = None
        else:
            s = Self(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, Defaultable & Movable]](
                        p
                    )
                )
            )


__extension List(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        p.expect(`[`)
        s = Self()

        while p.peek() != `]`:
            s.append(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, Defaultable & Movable]](
                        p
                    )
                )
            )
            p.skip_whitespace()
            if p.peek() != `]`:
                p.expect(`,`)
        p.expect(`]`)


__extension Dict(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        __comptime_assert _type_is_eq[
            Self.K, String
        ](), "Dict must have string keys"
        p.expect(`{`)
        s = Self()

        while p.peek() != `}`:
            var ident = rebind_var[Self.K](p.read_string())
            p.expect(`:`)
            s[ident^] = rebind_var[Self.V](
                _deserialize_impl[downcast[Self.V, Defaultable & Movable]](p)
            )
            p.skip_whitespace()
            if p.peek() != `}`:
                p.expect(`,`)
        p.expect(`}`)


__extension IntLiteral(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        s = Self()
        var i = p.parse_number().int()
        if i != s:
            raise Error("Expected: ", s, ", Received: ", i)


__extension FloatLiteral(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Parser, out s: Self) raises:
        s = Self()
        var f = p.parse_number().float()
        if f != s:
            raise Error("Expected: ", s, ", Received: ", f)


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
