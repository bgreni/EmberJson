from std.reflection import reflect

from std.builtin.rebind import downcast
from std.collections import Set
from std.memory import ArcPointer, OwnedPointer

from .parser import Parser
from .parser import Parser, ParseOptions
from emberjson.constants import `{`, `}`, `:`, `,`, `t`, `f`, `n`, `[`, `]`, `"`
from std.sys.intrinsics import unlikely, _type_is_eq
from emberjson.utils import to_string
from ._parser_helper import NULL, copy_to_string
from std.hashlib.hasher import Hasher
from std.sys import bit_width_of


comptime non_struct_error = "Cannot deserialize non-struct type"


comptime _Base = ImplicitlyDestructible & Movable


trait Deserializer:
    def expect_string(mut self) -> String:
        ...

    def expect_bool(mut self) -> Bool:
        ...

    def expect_int[dtype: DType](mut self) raises -> Scalar[dtype]:
        ...

    def expect_float[dtype: DType](mut self) -> Scalar[dtype]:
        ...


trait JsonDeserializable(_Base):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = _default_deserialize[Self, Self.deserialize_as_array()](p)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


@always_inline
def try_deserialize[T: _Base](s: String) -> Optional[T]:
    var p = Parser(s)
    return try_deserialize[T](p)


def try_deserialize[
    origin: ImmutOrigin, options: ParseOptions, //, T: _Base
](mut p: Parser[origin, options]) -> Optional[T]:
    try:
        return _deserialize_impl[T](p)
    except:
        return None


@always_inline
def deserialize[T: _Base](s: String, out res: T) raises:
    var p = Parser(s)
    res = deserialize[T](p)


# @always_inline
def deserialize[
    origin: ImmutOrigin, options: ParseOptions, //, T: _Base
](mut p: Parser[origin, options], out res: T) raises:
    res = _deserialize_impl[T](p)


# @always_inline
def deserialize[
    origin: ImmutOrigin, options: ParseOptions, //, T: _Base
](var p: Parser[origin, options], out res: T) raises:
    res = _deserialize_impl[T](p)


@always_inline
def __is_optional[T: AnyType]() -> Bool:
    return reflect[T].base_name() == "Optional"


@always_inline
def __is_default[T: AnyType]() -> Bool:
    return reflect[T].base_name() == "Default"


def __all_dtors_are_trivial[T: AnyType]() -> Bool:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime type = r.field_types()[i]
        if not downcast[type, ImplicitlyDestructible].__del__is_trivial:
            return False
    return True


@always_inline
def _default_deserialize[
    origin: ImmutOrigin,
    options: ParseOptions,
    //,
    T: _Base,
    is_array: Bool,
](mut p: Parser[origin, options], out s: T) raises:
    comptime if conforms_to(T, Defaultable):
        s = {}
    else:
        # If we use mark_initialized with a struct that has something like a pointer
        # field that doesn't become initialized it will cause a crash if parsing fails.
        comptime assert __all_dtors_are_trivial[T](), (
            "Cannot deserialize non-Defaultable struct containing fields with"
            " non-trivial destructors"
        )
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))

    comptime r = reflect[T]
    comptime field_count = r.field_count()
    comptime field_names = r.field_names()
    comptime field_types = r.field_types()

    comptime if is_array:
        p.expect(`[`)
        comptime for i in range(field_count):
            ref field = trait_downcast[_Base](r.field_ref[i](s))
            field = _deserialize_impl[type_of(field)](p)
            p.skip_whitespace()
            if i < field_count - 1:
                p.expect(`,`)
        p.expect(`]`)
    else:
        p.expect(`{`)

        # maybe an optimization since the InlineArray ctor uses a for loop
        # but according to the IR this will just inline the computed values
        var seen = materialize[InlineArray[Bool, field_count](fill=False)]()

        while p.peek() != `}`:
            var ident = p.read_string()
            p.expect(`:`)

            var matched = False
            comptime for i in range(field_count):
                comptime name = field_names[i]

                if ident == name:
                    ref seen_i = seen.unsafe_get(i)
                    if unlikely(seen_i):
                        raise Error("Duplicate key: ", name)
                    seen_i = True
                    matched = True
                    ref field = trait_downcast[_Base](r.field_ref[i](s))

                    field = _deserialize_impl[type_of(field)](p)

            if unlikely(not matched):
                raise Error("Unexpected field: ", ident)

            p.skip_whitespace()
            if p.peek() != `}`:
                p.expect(`,`)

        comptime for i in range(field_count):
            if not seen.unsafe_get(i):
                comptime if __is_optional[field_types[i]]() or __is_default[
                    field_types[i]
                ]():
                    ref field = trait_downcast[_Base & Defaultable](
                        r.field_ref[i](s)
                    )
                    field = type_of(field)()
                else:
                    comptime name = field_names[i]
                    raise Error("Missing key: ", name)

        p.expect(`}`)


def _deserialize_impl[
    origin: ImmutOrigin, options: ParseOptions, //, T: _Base
](mut p: Parser[origin, options], out s: T) raises:
    comptime assert reflect[T].is_struct(), non_struct_error

    comptime if conforms_to(T, JsonDeserializable):
        s = downcast[T, JsonDeserializable].from_json(p)
    else:
        s = _default_deserialize[T, False](p)


# ===============================================
# Primitives
# ===============================================


__extension String(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = p.read_string()

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Int(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Int(p.expect_int())

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Bool(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = p.expect_bool()

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension SIMD(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self()

        @parameter
        @always_inline
        def parse_simd_element(
            mut p: Parser[origin, options],
        ) raises -> Scalar[Self.dtype]:
            comptime if Self.dtype.is_numeric():
                comptime if Self.dtype.is_floating_point():
                    return p.expect_float[Self.dtype]()
                else:
                    return p.expect_int[Self.dtype]()
            else:
                return Scalar[Self.dtype](p.expect_bool())

        comptime if size > 1:
            p.expect(`[`)

        comptime for i in range(size):
            s[i] = parse_simd_element(p)

            comptime if i < size - 1:
                p.expect(`,`)

        comptime if size > 1:
            p.expect(`]`)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension IntLiteral(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self()
        var i = p.expect_int()
        if i != s:
            raise Error("Expected: ", s, ", Received: ", i)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension FloatLiteral(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self()
        var f = p.expect_float()
        if f != s:
            raise Error("Expected: ", s, ", Received: ", f)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


# ===============================================
# Pointers
# ===============================================


__extension ArcPointer(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self(_deserialize_impl[downcast[Self.T, _Base]](p))

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension OwnedPointer(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = rebind_var[Self](
            OwnedPointer(_deserialize_impl[downcast[Self.T, _Base]](p))
        )

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


# ===============================================
# Collections
# ===============================================


__extension Optional(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        if p.peek() == `n`:
            p.expect_null()
            s = None
        else:
            s = Self(_deserialize_impl[downcast[Self.T, _Base]](p))

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension List(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        p.expect(`[`)
        s = Self()

        while p.peek() != `]`:
            s.append(_deserialize_impl[downcast[Self.T, _Base]](p))
            p.skip_whitespace()
            if p.peek() != `]`:
                p.expect(`,`)
        p.expect(`]`)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Dict(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        comptime assert (
            _type_is_eq[Self.K, String]()
            or reflect[Self.K].base_name() == "LazyString"
        ), "Dict must have string keys"
        p.expect(`{`)
        s = Self()

        while p.peek() != `}`:
            var ident = rebind_var[Self.K](
                _deserialize_impl[downcast[Self.K, _Base & Movable]](p)
            )
            p.expect(`:`)
            s[ident^] = _deserialize_impl[downcast[Self.V, _Base]](p)
            p.skip_whitespace()
            if p.peek() != `}`:
                p.expect(`,`)
        p.expect(`}`)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Tuple(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))
        p.expect(`[`)

        comptime for i in range(Self.__len__()):
            UnsafePointer(to=s[i]).init_pointee_move(
                _deserialize_impl[downcast[Self.element_types[i], _Base]](p)
            )

            if i < Self.__len__() - 1:
                p.expect(`,`)

        p.expect(`]`)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension InlineArray(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut j: Parser[origin, options], out s: Self) raises:
        j.expect(`[`)
        s = Self(uninitialized=True)

        for i in range(size):
            UnsafePointer(to=s[i]).init_pointee_move(
                _deserialize_impl[downcast[Self.ElementType, _Base]](j)
            )

            if i != size - 1:
                j.expect(`,`)

        j.expect(`]`)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Set(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut j: Parser[origin, options], out s: Self) raises:
        j.expect(`[`)
        s = Self()

        while j.peek() != `]`:
            s.add(_deserialize_impl[downcast[Self.T, _Base]](j))
            j.skip_whitespace()
            if j.peek() != `]`:
                j.expect(`,`)
        j.expect(`]`)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False
