from std.reflection import reflect

from std.builtin.rebind import downcast
from std.collections import Set
from std.memory import ArcPointer, OwnedPointer

from .parser import Parser
from .parser import Parser, ParseOptions
from emberjson.constants import `{`, `}`, `:`, `,`, `t`, `f`, `n`, `[`, `]`, `"`
from std.sys.intrinsics import unlikely
from emberjson.utils import to_string
from ._parser_helper import NULL, copy_to_string, _next_backslash
from emberjson._utf8 import is_valid_utf8
from std.hashlib.hasher import Hasher
from std.memory import forget_deinit, unsafe_memcmp
from std.sys import bit_width_of


comptime non_struct_error = "Cannot deserialize non-struct type"


comptime _Base = ImplicitlyDeletable & Movable


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
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = _default_deserialize[Self, Self.deserialize_as_array()](p)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


@always_inline
def try_deserialize[T: _Base](s: String) -> Optional[T]:
    # Default options: UTF-8 validation is on (see ParseOptions). The
    # Parser-taking overloads skip it for callers managing their own input.
    if not is_valid_utf8(StringSlice(s)):
        return None
    var p = Parser(s)
    return try_deserialize[T](p)


def try_deserialize[
    origin: ImmOrigin, options: ParseOptions, //, T: _Base
](mut p: Parser[origin, options]) -> Optional[T]:
    try:
        return _deserialize_impl[T](p)
    except:
        return None


@always_inline
def deserialize[T: _Base](s: String, out res: T) raises:
    # Default options: UTF-8 validation is on (see ParseOptions). The
    # Parser-taking overloads skip it for callers managing their own input.
    if not is_valid_utf8(StringSlice(s)):
        raise Error("Invalid UTF-8 in input")
    var p = Parser(s)
    res = deserialize[T](p)


# @always_inline
def deserialize[
    origin: ImmOrigin, options: ParseOptions, //, T: _Base
](mut p: Parser[origin, options], out res: T) raises:
    res = _deserialize_impl[T](p)


# @always_inline
def deserialize[
    origin: ImmOrigin, options: ParseOptions, //, T: _Base
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
        if not downcast[type, ImplicitlyDeletable].__del__is_trivial:
            return False
    return True


@always_inline
def _field_key_eq(
    kb: Span[Byte, _], escaped: Bool, decoded: String, name: StaticString
) -> Bool:
    """Matches an object key against a comptime field name. The common
    case compares the key's raw bytes; keys containing escapes (rare for
    struct fields) are matched via their decoded form."""
    if unlikely(escaped):
        return decoded == name
    if len(kb) != name.byte_length():
        return False
    return unsafe_memcmp(kb.unsafe_ptr(), name.unsafe_ptr(), len(kb)) == 0


@always_inline
def _default_deserialize[
    origin: ImmOrigin,
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
            ref field = rebind[downcast[field_types[i], _Base]](
                r.field_ref[i](s)
            )
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
            if unlikely(p.peek() != `"`):
                raise Error("Invalid identifier")
            # Field names are matched against the key's raw span — no
            # String materialization per key. Escaped keys (rare) are
            # decoded once and compared in decoded form.
            var key_span = p.expect_string_bytes()
            p.expect(`:`)

            var kb = Span(
                unsafe_ptr=key_span.unsafe_ptr() + 1, length=len(key_span) - 2
            )
            var kb_end = kb.unsafe_ptr() + len(kb)
            var escaped = _next_backslash(kb.unsafe_ptr(), kb_end) < kb_end
            var decoded = String()
            if unlikely(escaped):
                decoded = copy_to_string[False](kb.unsafe_ptr(), kb_end)

            var matched = False
            comptime for i in range(field_count):
                comptime name = field_names[i]

                if _field_key_eq(kb, escaped, decoded, name):
                    ref seen_i = seen.unsafe_get(i)
                    if unlikely(seen_i):
                        raise Error("Duplicate key: ", name)
                    seen_i = True
                    matched = True
                    ref field = rebind[downcast[field_types[i], _Base]](
                        r.field_ref[i](s)
                    )

                    field = _deserialize_impl[type_of(field)](p)

            if unlikely(not matched):
                if escaped:
                    raise Error("Unexpected field: ", decoded)
                raise Error(
                    "Unexpected field: ", StringSlice(unsafe_from_utf8=kb)
                )

            p.skip_whitespace()
            if p.peek() != `}`:
                p.expect(`,`)

        comptime for i in range(field_count):
            if not seen.unsafe_get(i):
                comptime if __is_optional[field_types[i]]() or __is_default[
                    field_types[i]
                ]():
                    ref field = rebind[
                        downcast[field_types[i], _Base & Defaultable]
                    ](r.field_ref[i](s))
                    field = type_of(field)()
                else:
                    comptime name = field_names[i]
                    raise Error("Missing key: ", name)

        p.expect(`}`)


def _deserialize_impl[
    origin: ImmOrigin, options: ParseOptions, //, T: _Base
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
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = p.read_string()

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


# `Int` is now an alias for `Scalar[DType.int]`, so it is covered by the
# `SIMD` extension below rather than a dedicated extension.


__extension Bool(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = p.expect_bool()

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension SIMD(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
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
        origin: ImmOrigin, options: ParseOptions, //
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
        origin: ImmOrigin, options: ParseOptions, //
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
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = Self(_deserialize_impl[downcast[Self.T, _Base]](p))

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension OwnedPointer(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
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
        origin: ImmOrigin, options: ParseOptions, //
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
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        p.expect(`[`)

        # Build into a list whose element type is downcast to `_Base` (which is
        # `ImplicitlyDeletable`) so the partially-built list can be cleaned up if
        # a parse call raises, then rebind back to `Self` (same layout).
        var lst = List[downcast[Self.T, _Base]]()

        while p.peek() != `]`:
            lst.append(_deserialize_impl[downcast[Self.T, _Base]](p))
            p.skip_whitespace()
            if p.peek() != `]`:
                p.expect(`,`)
        p.expect(`]`)
        s = rebind_var[Self](lst^)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Dict(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        comptime assert (
            Self.K == String or reflect[Self.K].base_name() == "LazyString"
        ), "Dict must have string keys"
        p.expect(`{`)

        # `Dict.__setitem__` now requires evidence that `K` and `V` are
        # `ImplicitlyDeletable`, which the generic `Self.K`/`Self.V` don't
        # carry. Build into a dict whose key/value types are downcast to
        # supply that evidence, then rebind back to `Self` (same layout).
        comptime K2 = downcast[
            Self.K, Copyable & Hashable & Equatable & ImplicitlyDeletable
        ]
        comptime V2 = downcast[Self.V, Movable & ImplicitlyDeletable]
        var d = Dict[K2, V2, Self.H]()

        while p.peek() != `}`:
            var ident = rebind_var[K2](
                _deserialize_impl[downcast[Self.K, _Base]](p)
            )
            p.expect(`:`)
            d[ident^] = rebind_var[V2](
                _deserialize_impl[downcast[Self.V, _Base]](p)
            )
            p.skip_whitespace()
            if p.peek() != `}`:
                p.expect(`,`)
        p.expect(`}`)
        s = rebind_var[Self](d^)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Tuple(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        # Claim `s` only after the opening bracket: a throw before this point
        # leaves it untouched, so there is nothing to tear down.
        p.expect(`[`)
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))

        # A `Tuple` whose elements are not known `ImplicitlyDeletable` has no
        # implicit destructor, so every throwing path has to consume `s` by
        # hand. `mark_initialized` above claims the whole tuple, but on a throw
        # only elements `[0, n)` have actually been written — the rest are
        # forgotten rather than destroyed.
        @parameter
        def drop_prefix[n: Int](var partial: Self):
            @parameter
            def drop_elt[idx: Int](var elt: Self.element_types[idx]):
                comptime if idx < n:
                    _ = rebind_var[downcast[Self.element_types[idx], _Base]](
                        elt^
                    )
                else:
                    forget_deinit(elt^)

            partial^.deinit_with[drop_elt]()

        comptime for i in range(Self.__len__()):
            try:
                UnsafePointer(to=s[i]).unsafe_write(
                    _deserialize_impl[downcast[Self.element_types[i], _Base]](p)
                )
            except e:
                drop_prefix[i](s^)
                raise e^

            if i < Self.__len__() - 1:
                try:
                    p.expect(`,`)
                except e:
                    drop_prefix[i + 1](s^)
                    raise e^

        try:
            p.expect(`]`)
        except e:
            drop_prefix[Self.__len__()](s^)
            raise e^

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension InlineArray(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
    ](mut j: Parser[origin, options], out s: Self) raises:
        j.expect(`[`)

        # Build into an array whose element type is downcast to `_Base` (which
        # is `ImplicitlyDeletable`) so cleanup is possible if a parse call
        # raises, then rebind back to `Self` (same layout).
        var arr = InlineArray[downcast[Self.T, _Base], Self.length](
            uninitialized=True
        )

        for i in range(Self.length):
            UnsafePointer(to=arr[i]).unsafe_write(
                _deserialize_impl[downcast[Self.T, _Base]](j)
            )

            if i != Self.length - 1:
                j.expect(`,`)

        j.expect(`]`)
        s = rebind_var[downcast[Self, Movable]](arr^)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False


__extension Set(JsonDeserializable):
    @staticmethod
    def from_json[
        origin: ImmOrigin, options: ParseOptions, //
    ](mut j: Parser[origin, options], out s: Self) raises:
        j.expect(`[`)

        # `Set.add` now requires evidence that `T` is `ImplicitlyDeletable`,
        # which the generic `Self.T` doesn't carry. Build into a set whose
        # element type is downcast to supply that evidence, then rebind back
        # to `Self` (same layout).
        comptime T2 = downcast[
            Self.T, Copyable & Hashable & Equatable & ImplicitlyDeletable
        ]
        var acc = Set[T2, Self.H]()

        while j.peek() != `]`:
            acc.add(
                rebind_var[T2](_deserialize_impl[downcast[Self.T, _Base]](j))
            )
            j.skip_whitespace()
            if j.peek() != `]`:
                j.expect(`,`)
        j.expect(`]`)
        s = rebind_var[Self](acc^)

    @staticmethod
    def deserialize_as_array() -> Bool:
        return False
