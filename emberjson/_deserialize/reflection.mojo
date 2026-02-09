from std.reflection import (
    struct_field_count,
    struct_field_types,
    struct_field_names,
    is_struct_type,
)

from std.builtin.rebind import downcast
from std.collections import Set
from std.memory import ArcPointer, OwnedPointer

from .parser import Parser
from .traits import Deserializer
from emberjson.constants import `{`, `}`, `:`, `,`, `t`, `f`, `n`, `[`, `]`
from std.sys.intrinsics import unlikely, _type_is_eq
from emberjson.utils import to_string
from ._parser_helper import NULL


comptime non_struct_error = "Cannot deserialize non-struct type"


comptime _Base = ImplicitlyDestructible & Movable


trait JsonDeserializable(_Base):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = _default_deserialize[Self](p)


fn try_deserialize[T: _Base](s: String) -> Optional[T]:
    return try_deserialize[T](Parser(s))


fn try_deserialize[T: _Base](var p: Some[Deserializer]) -> Optional[T]:
    try:
        return _deserialize_impl[T](p)
    except:
        return None


fn deserialize[T: _Base](s: String, out res: T) raises:
    res = deserialize[T](Parser(s))


fn deserialize[T: _Base](var p: Some[Deserializer], out res: T) raises:
    res = _deserialize_impl[T](p)


@always_inline
fn _default_deserialize[T: _Base](mut p: Some[Deserializer], out s: T) raises:
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))

    comptime field_count = struct_field_count[T]()
    comptime field_names = struct_field_names[T]()

    p.expect(`{`)

    var seen = InlineArray[Bool, field_count](fill=False)

    for i in range(field_count):
        var ident = p.read_string()
        p.expect(`:`)

        @parameter
        for j in range(field_count):
            comptime name = field_names[j]

            if not seen[j] and ident == name:
                seen[j] = True
                ref field = __struct_field_ref(j, s)
                comptime TField = downcast[type_of(field), _Base]

                field = rebind_var[type_of(field)](_deserialize_impl[TField](p))

        if i < field_count - 1:
            p.expect(`,`)
    p.expect(`}`)


fn _deserialize_impl[T: _Base](mut p: Some[Deserializer], out s: T) raises:
    comptime assert is_struct_type[T](), non_struct_error

    @parameter
    if conforms_to(T, JsonDeserializable):
        s = rebind_var[T](downcast[T, JsonDeserializable].from_json(p))
    else:
        s = _default_deserialize[T](p)


# ===============================================
# Primitives
# ===============================================


__extension String(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = p.read_string()


__extension Int(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = Int(p.expect_integer())


__extension Bool(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = p.expect_bool()


__extension SIMD(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = Self()

        @parameter
        @always_inline
        fn parse_simd_element(
            mut p: Some[Deserializer],
        ) raises -> Scalar[Self.dtype]:
            @parameter
            if Self.dtype.is_numeric():

                @parameter
                if Self.dtype.is_floating_point():
                    return p.expect_float[Self.dtype]()
                else:

                    @parameter
                    if Self.dtype.is_signed():
                        return p.expect_integer[Self.dtype]()
                    else:
                        return p.expect_unsigned_integer[Self.dtype]()
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


__extension IntLiteral(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = Self()
        var i = p.expect_integer()
        if i != s:
            raise Error("Expected: ", s, ", Received: ", i)


__extension FloatLiteral(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = Self()
        var f = p.expect_float()
        if f != s:
            raise Error("Expected: ", s, ", Received: ", f)


# ===============================================
# Pointers
# ===============================================


__extension ArcPointer(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = Self(_deserialize_impl[downcast[Self.T, _Base]](p))


__extension OwnedPointer(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        s = rebind_var[Self](
            OwnedPointer(_deserialize_impl[downcast[Self.T, _Base]](p))
        )


# ===============================================
# Collections
# ===============================================


__extension Optional(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        if p.peek() == `n`:
            p.expect_null()
            s = None
        else:
            s = Self(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, _Base]](p)
                )
            )


__extension List(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        p.expect(`[`)
        s = Self()

        while p.peek() != `]`:
            s.append(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, _Base]](p)
                )
            )
            p.skip_whitespace()
            if p.peek() != `]`:
                p.expect(`,`)
        p.expect(`]`)


__extension Dict(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        comptime assert _type_is_eq[
            Self.K, String
        ](), "Dict must have string keys"
        p.expect(`{`)
        s = Self()

        while p.peek() != `}`:
            var ident = rebind_var[Self.K](p.read_string())
            p.expect(`:`)
            s[ident^] = rebind_var[Self.V](
                _deserialize_impl[downcast[Self.V, _Base]](p)
            )
            p.skip_whitespace()
            if p.peek() != `}`:
                p.expect(`,`)
        p.expect(`}`)


__extension Tuple(JsonDeserializable):
    @staticmethod
    fn from_json(mut p: Some[Deserializer], out s: Self) raises:
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))
        p.expect(`[`)

        @parameter
        for i in range(Self.__len__()):
            UnsafePointer(to=s[i]).init_pointee_move(
                rebind_var[Self.element_types[i]](
                    _deserialize_impl[downcast[Self.element_types[i], _Base]](p)
                )
            )

            if i < Self.__len__() - 1:
                p.expect(`,`)

        p.expect(`]`)


__extension InlineArray(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Some[Deserializer], out s: Self) raises:
        j.expect(`[`)
        s = Self(uninitialized=True)

        for i in range(size):
            UnsafePointer(to=s[i]).init_pointee_move(
                rebind_var[Self.ElementType](
                    _deserialize_impl[downcast[Self.ElementType, _Base]](j)
                )
            )

            if i != size - 1:
                j.expect(`,`)

        j.expect(`]`)


__extension Set(JsonDeserializable):
    @staticmethod
    fn from_json(mut j: Some[Deserializer], out s: Self) raises:
        j.expect(`[`)
        s = Self()

        while j.peek() != `]`:
            s.add(
                rebind_var[Self.T](
                    _deserialize_impl[downcast[Self.T, _Base]](j)
                )
            )
            j.skip_whitespace()
            if j.peek() != `]`:
                j.expect(`,`)
        j.expect(`]`)
