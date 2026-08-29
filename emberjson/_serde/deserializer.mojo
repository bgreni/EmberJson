from std.collections.string.string_span import get_static_string

from emberjson._deserialize import Parser, ParseOptions
from emberjson.constants import `[`, `]`, `{`, `}`, `"`, `:`, `,`, `n`

from emberserde.deserialize import (
    Deserializer,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
)
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.utils import Base

# JSON `Deserializer` format over EmberJson's existing hand-written `Parser`
# (`emberjson/_deserialize/parser.mojo`), ported to sit on top of
# emberserde's format-agnostic traits (`emberserde/emberserde/deserialize/
# __init__.mojo`). Structurally this mirrors `emberserde/test/_json_format.
# mojo`'s `JsonDeserializer`, but drives EmberJson's own byte-walking parser
# instead of a hand-rolled cursor: the `Parser`'s low-level token methods
# (`expect`, `peek`, `skip_whitespace`, `expect_string_bytes`, `expect_int`,
# `expect_float`, `expect_bool`, `expect_null`, `skip_value`, `read_string`)
# raise a plain (untyped) `Error`, so every call here is wrapped in a
# try/except that converts it into a typed `DeserializationError`.
#
# Two origins, like the toy format's `Pointer[JsonCursor, origin]`, but
# split in two because `Parser` itself is generic over the origin of the
# input it borrows: `origin` is that input origin, `ptr_origin` is the
# origin of the pointer to the `Parser` instance itself (sub-deserializers
# share one `Parser` via this pointer, exactly like the toy shares one
# `JsonCursor`). `options` rides as a struct parameter since the
# `Deserializer` trait has no parameter channel of its own.
#
# `expect_struct` is intentionally NOT overridden — per the trait's
# comments it is the framework's field-matching driver (rename/alias/skip,
# duplicate/unknown/missing-field handling, error paths); overriding it
# would silently opt out of all of that. Only `begin_struct`/`StructDerState`
# are implemented here.


def _invalid(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.InvalidValue)


def _mismatch(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.TypeMismatch)


@fieldwise_init
struct EmberJsonSeqDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](SeqDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        try:
            self.p[].skip_whitespace()
            if self.p[].peek() == `]`:
                return False
            if self.p[].peek() == `,`:
                self.p[].expect(`,`)
            return True
        except e:
            raise _invalid(String(e))

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        try:
            self.p[].expect(`]`)
        except e:
            raise _invalid(String(e))


@fieldwise_init
struct EmberJsonMapDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](MapDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        try:
            self.p[].skip_whitespace()
            if self.p[].peek() == `}`:
                return False
            if self.p[].peek() == `,`:
                self.p[].expect(`,`)
            return True
        except e:
            raise _invalid(String(e))

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        # `has_next` has already skipped whitespace and any separating
        # comma, so the parser sits at the key token. EmberJson's `Dict`
        # deserialize path only ever asks for `String` keys (JSON object
        # keys are always strings), so this delegates straight through.
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        try:
            self.p[].expect(`:`)
        except e:
            raise _invalid(String(e))
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        try:
            self.p[].expect(`}`)
        except e:
            raise _invalid(String(e))


@fieldwise_init
struct EmberJsonStructDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](StructDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]

    def expect_field_name(
        mut self,
    ) raises DeserializationError -> Optional[String]:
        try:
            self.p[].skip_whitespace()
            if self.p[].peek() == `}`:
                # End of struct: leave the `}` for `end()` to consume.
                return None
            if self.p[].peek() == `,`:
                self.p[].expect(`,`)
            if self.p[].peek() != `"`:
                raise Error("expected an object key string")
            var raw = self.p[].expect_string_bytes()
            # `raw` keeps its surrounding quotes (see `expect_string_bytes`'s
            # contract); strip them to build the plain field name. Field
            # names are not unescaped here — a known, accepted cost (see
            # the module docstring); this materializes one `String` per
            # field regardless.
            var name = String(
                StringSlice(
                    unsafe_from_utf8=Span(
                        unsafe_ptr=raw.unsafe_ptr().unsafe_offset(1),
                        length=len(raw) - 2,
                    )
                )
            )
            self.p[].expect(`:`)
            return name^
        except e:
            raise _invalid(String(e))

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        try:
            self.p[].skip_value()
        except e:
            raise _invalid(String(e))

    def end(mut self) raises DeserializationError:
        try:
            self.p[].expect(`}`)
        except e:
            raise _invalid(String(e))


@fieldwise_init
struct EmberJsonTupleDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](TupleDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]
    var first: Bool

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        try:
            self.p[].skip_whitespace()
            if not self.first:
                self.p[].expect(`,`)
        except e:
            raise _invalid(String(e))
        self.first = False
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        try:
            self.p[].expect(`]`)
        except e:
            raise _invalid(String(e))


@fieldwise_init
struct EmberJsonEnumDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](EnumDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]
    var idx: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        try:
            self.p[].expect(`}`)
        except e:
            raise _invalid(String(e))


@fieldwise_init
struct EmberJsonDeserializer[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](Deserializer):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]

    comptime SeqType = EmberJsonSeqDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime MapType = EmberJsonMapDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime StructType = EmberJsonStructDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime TupleType = EmberJsonTupleDe[
        Self.origin, Self.options, Self.ptr_origin
    ]
    comptime EnumType = EmberJsonEnumDe[
        Self.origin, Self.options, Self.ptr_origin
    ]

    def expect_bool(mut self) raises DeserializationError -> Bool:
        try:
            self.p[].skip_whitespace()
            return self.p[].expect_bool()
        except e:
            raise _mismatch(String(e))

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        try:
            self.p[].skip_whitespace()
            comptime if DT.is_floating_point():
                return self.p[].expect_float[DT]()
            else:
                return self.p[].expect_int[DT]()
        except e:
            raise _mismatch(String(e))

    def expect_string(mut self) raises DeserializationError -> String:
        try:
            self.p[].skip_whitespace()
            if self.p[].peek() != `"`:
                raise Error("expected a string")
            return self.p[].read_string()
        except e:
            raise _mismatch(String(e))

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        try:
            self.p[].skip_whitespace()
            if self.p[].peek() == `n`:
                self.p[].expect_null()
                return Optional[T]()
        except e:
            raise _mismatch(String(e))
        return Optional[T](deserialize[T](self))

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        try:
            self.p[].expect(`[`)
        except e:
            raise _mismatch(String(e))
        return EmberJsonSeqDe(p=self.p)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        try:
            self.p[].expect(`{`)
        except e:
            raise _mismatch(String(e))
        return EmberJsonMapDe(p=self.p)

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        # Field names are read off the wire, so `T` is unused; the
        # framework's reflection default drives the name-matching loop.
        try:
            self.p[].expect(`{`)
        except e:
            raise _mismatch(String(e))
        return EmberJsonStructDe(p=self.p)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        try:
            self.p[].expect(`[`)
        except e:
            raise _mismatch(String(e))
        return EmberJsonTupleDe(p=self.p, first=True)

    # Externally tagged `{"Arm":payload}`: consume up to and including the
    # `:`, resolve the arm name to an index; the closing `}` is `end`'s job.
    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        var name: String
        try:
            self.p[].expect(`{`)
            if self.p[].peek() != `"`:
                raise Error("expected an enum tag string")
            var raw = self.p[].expect_string_bytes()
            name = String(
                StringSlice(
                    unsafe_from_utf8=Span(
                        unsafe_ptr=raw.unsafe_ptr().unsafe_offset(1),
                        length=len(raw) - 2,
                    )
                )
            )
            self.p[].expect(`:`)
        except e:
            raise _mismatch(String(e))
        var idx = -1
        # `comptime for` over the interned candidates: no per-value list.
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and name == an:
                idx = i
        return EmberJsonEnumDe(p=self.p, idx=idx)


def from_json_string[T: AnyType](s: String) raises DeserializationError -> T:
    var p = Parser(s)
    var d = EmberJsonDeserializer(p=Pointer(to=p))
    return deserialize[T](d)
