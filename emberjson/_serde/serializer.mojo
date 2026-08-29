from emberserde.serialize import (
    Serializer,
    SeqSerState,
    MapSerState,
    StructSerState,
    TupleSerState,
    EnumSerState,
    serialize,
)
from emberserde.error import SerializationError
from emberjson.teju import write_float
from emberjson.utils import write_escaped_string
from std.format._utils import _WriteBufferStack

# JSON `Serializer` format over an arbitrary `Writer`, ported to sit on top
# of emberserde's format-agnostic traits (`emberserde/emberserde/serialize/
# __init__.mojo`). Structurally this is `emberserde/test/_json_format.mojo`'s
# `JsonSerializer`, generalized two ways:
#   - generic over the writer type `W` (instead of hardcoding `String`), so a
#     future caller can hand it EmberJson's `_WriteBufferStack` and keep that
#     writer's speed;
#   - comptime-branching on `pretty` to match the indentation behavior of
#     `emberjson/_serialize/reflection.mojo`'s `PrettySerializer` (4-space
#     indent, newline after every opening bracket/brace, indented closing
#     bracket/brace).
#
# `serialize_seq` and `serialize_struct` are intentionally NOT overridden —
# per the trait's comments they are framework drivers (size hints, skip/
# rename/wire-name handling); overriding them would silently opt out of that
# logic. Only the `begin_*`/state hooks are implemented here.


def _write_indent(mut out: Some[Writer], depth: Int):
    for _ in range(depth):
        out.write("    ")


@fieldwise_init
struct EmberJsonSeqSer[
    W: Writer & Movable & Deinitable,
    origin: MutOrigin,
    pretty: Bool = False,
](SeqSerState):
    var out: Pointer[Self.W, Self.origin]
    var first: Bool
    var depth: Int

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[].write(",")
            comptime if Self.pretty:
                self.out[].write("\n")
        self.first = False
        comptime if Self.pretty:
            _write_indent(self.out[], self.depth)
        var sub = EmberJsonSerializer[Self.W, Self.origin, Self.pretty](
            out=self.out, depth=self.depth
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        comptime if Self.pretty:
            # An empty container never ran `serialize_element`/`_key`/
            # `_field`, so `first` is still True: `begin_*` already wrote
            # the one newline right after the opening bracket, and there is
            # no trailing element that owes the closing bracket a
            # separating newline. Skipping it here (but still indenting to
            # `depth - 1`, matching this container's own opening-bracket
            # column) turns `"[\n\n]"` into `"[\n]"` — matching
            # `emberjson/_serialize/reflection.mojo`'s `PrettySerializer`,
            # whose `write_item` (not `end_*`) owns the inter-element/
            # trailing newline and so never emits one when there were no
            # items.
            if not self.first:
                self.out[].write("\n")
            _write_indent(self.out[], self.depth - 1)
        self.out[].write("]")


@fieldwise_init
struct EmberJsonMapSer[
    W: Writer & Movable & Deinitable,
    origin: MutOrigin,
    pretty: Bool = False,
](MapSerState):
    var out: Pointer[Self.W, Self.origin]
    var first: Bool
    var depth: Int

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[].write(",")
            comptime if Self.pretty:
                self.out[].write("\n")
        self.first = False
        comptime if Self.pretty:
            _write_indent(self.out[], self.depth)

        # Fast path: `String` keys are by far the common case (every
        # `Object`/`Dict[String, V]` key is one) — write straight into the
        # buffered writer via `write_escaped_string`, skipping the
        # scratch-`String` round trip the generic path below needs.
        comptime if type_of(k) == String:
            write_escaped_string(rebind[String](k), self.out[])
        else:
            # Stringify non-string keys (serde_json behavior, mirroring the
            # toy format): render the key into a scratch buffer, then wrap
            # in quotes unless it already produced a quoted JSON string.
            var keybuf = String()
            var sub = EmberJsonSerializer[
                String, origin_of(keybuf), Self.pretty
            ](out=Pointer(to=keybuf), depth=self.depth)
            serialize(k, sub)
            if keybuf.byte_length() > 0 and Int(keybuf.as_bytes()[0]) == ord(
                '"'
            ):
                self.out[].write(keybuf)
            else:
                self.out[].write('"')
                self.out[].write(keybuf)
                self.out[].write('"')

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        self.out[].write(":")
        comptime if Self.pretty:
            self.out[].write(" ")
        var sub = EmberJsonSerializer[Self.W, Self.origin, Self.pretty](
            out=self.out, depth=self.depth
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        comptime if Self.pretty:
            # See EmberJsonSeqSer.end for why this is guarded on `first`.
            if not self.first:
                self.out[].write("\n")
            _write_indent(self.out[], self.depth - 1)
        self.out[].write("}")


@fieldwise_init
struct EmberJsonStructSer[
    W: Writer & Movable & Deinitable,
    origin: MutOrigin,
    pretty: Bool = False,
](StructSerState):
    var out: Pointer[Self.W, Self.origin]
    var first: Bool
    var depth: Int

    def serialize_field(
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        if not self.first:
            self.out[].write(",")
            comptime if Self.pretty:
                self.out[].write("\n")
        self.first = False
        comptime if Self.pretty:
            _write_indent(self.out[], self.depth)
        write_escaped_string(field_name, self.out[])
        self.out[].write(":")
        comptime if Self.pretty:
            self.out[].write(" ")
        var sub = EmberJsonSerializer[Self.W, Self.origin, Self.pretty](
            out=self.out, depth=self.depth
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        comptime if Self.pretty:
            # See EmberJsonSeqSer.end for why this is guarded on `first`.
            if not self.first:
                self.out[].write("\n")
            _write_indent(self.out[], self.depth - 1)
        self.out[].write("}")


@fieldwise_init
struct EmberJsonTupleSer[
    W: Writer & Movable & Deinitable,
    origin: MutOrigin,
    pretty: Bool = False,
](TupleSerState):
    var out: Pointer[Self.W, Self.origin]
    var first: Bool
    var depth: Int

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[].write(",")
            comptime if Self.pretty:
                self.out[].write("\n")
        self.first = False
        comptime if Self.pretty:
            _write_indent(self.out[], self.depth)
        var sub = EmberJsonSerializer[Self.W, Self.origin, Self.pretty](
            out=self.out, depth=self.depth
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        comptime if Self.pretty:
            # See EmberJsonSeqSer.end for why this is guarded on `first`.
            if not self.first:
                self.out[].write("\n")
            _write_indent(self.out[], self.depth - 1)
        self.out[].write("]")


@fieldwise_init
struct EmberJsonEnumSer[
    W: Writer & Movable & Deinitable,
    origin: MutOrigin,
    pretty: Bool = False,
](EnumSerState):
    var out: Pointer[Self.W, Self.origin]
    var depth: Int

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = EmberJsonSerializer[Self.W, Self.origin, Self.pretty](
            out=self.out, depth=self.depth
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        comptime if Self.pretty:
            self.out[].write("\n")
            _write_indent(self.out[], self.depth - 1)
        self.out[].write("}")


@fieldwise_init
struct EmberJsonSerializer[
    W: Writer & Movable & Deinitable,
    origin: MutOrigin,
    pretty: Bool = False,
](Serializer):
    var out: Pointer[Self.W, Self.origin]
    var depth: Int

    comptime SeqType = EmberJsonSeqSer[Self.W, Self.origin, Self.pretty]
    comptime MapType = EmberJsonMapSer[Self.W, Self.origin, Self.pretty]
    comptime StructType = EmberJsonStructSer[Self.W, Self.origin, Self.pretty]
    comptime TupleType = EmberJsonTupleSer[Self.W, Self.origin, Self.pretty]
    comptime EnumType = EmberJsonEnumSer[Self.W, Self.origin, Self.pretty]

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self.out[].write("true" if v else "false")

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        comptime if dt.is_floating_point():
            write_float(v, self.out[])
        else:
            self.out[].write(v)

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        write_escaped_string(v, self.out[])

    def serialize_none(mut self) raises SerializationError:
        self.out[].write("null")

    # `serialize_some` is intentionally NOT overridden: JSON is transparent
    # about presence, which is exactly the trait's default.

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        self.out[].write("[")
        for i in range(len(v)):
            if i != 0:
                self.out[].write(",")
            self.out[].write(v[i])
        self.out[].write("]")

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        # Self-describing output: the size hint is not needed.
        self.out[].write("[")
        var d = self.depth
        comptime if Self.pretty:
            self.out[].write("\n")
            d += 1
        return EmberJsonSeqSer[Self.W, Self.origin, Self.pretty](
            out=self.out, first=True, depth=d
        )

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        self.out[].write("{")
        var d = self.depth
        comptime if Self.pretty:
            self.out[].write("\n")
            d += 1
        return EmberJsonMapSer[Self.W, Self.origin, Self.pretty](
            out=self.out, first=True, depth=d
        )

    def begin_struct[
        name: String
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        # Unlike a name-tagged debug format, JSON does not write the struct
        # name — `name` is intentionally unused.
        self.out[].write("{")
        var d = self.depth
        comptime if Self.pretty:
            self.out[].write("\n")
            d += 1
        return EmberJsonStructSer[Self.W, Self.origin, Self.pretty](
            out=self.out, first=True, depth=d
        )

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        self.out[].write("[")
        var d = self.depth
        comptime if Self.pretty:
            self.out[].write("\n")
            d += 1
        return EmberJsonTupleSer[Self.W, Self.origin, Self.pretty](
            out=self.out, first=True, depth=d
        )

    def begin_enum[
        name: String, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        # Externally tagged, matching the toy format: `{"<variant>":payload}`.
        self.out[].write("{")
        var d = self.depth
        comptime if Self.pretty:
            self.out[].write("\n")
            d += 1
            _write_indent(self.out[], d)
        write_escaped_string(variant, self.out[])
        self.out[].write(":")
        comptime if Self.pretty:
            self.out[].write(" ")
        return EmberJsonEnumSer[Self.W, Self.origin, Self.pretty](
            out=self.out, depth=d
        )


def to_json_string[
    T: AnyType, //, pretty: Bool = False
](value: T) raises SerializationError -> String:
    var buf = String()
    # Route writes through a stack-buffered writer instead of hitting the
    # destination `String` on every single token (`{`, `"`, `:`, `,`, ...).
    # Matches the pattern used by `emberjson.utils.write`/`write_pretty` and
    # the pre-migration `_serialize/reflection.mojo`'s `serialize` free
    # function. Must `flush()` before returning `buf` or the trailing
    # buffered bytes are silently dropped.
    var w = _WriteBufferStack(buf)
    var s = EmberJsonSerializer[type_of(w), origin_of(w), pretty](
        out=Pointer(to=w), depth=0
    )
    serialize(value, s)
    w.flush()
    return buf^
