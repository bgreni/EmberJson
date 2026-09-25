from std.collections.string.string_span import get_static_string

from emberjson._deserialize import Parser, ParseOptions, StrictOptions
from emberjson._deserialize._parser_helper import copy_to_string, ptr_dist
from emberjson.constants import (
    `[`,
    `]`,
    `{`,
    `}`,
    `"`,
    `:`,
    `,`,
    `n`,
)
from emberjson.value import Value

from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializer,
    RawKind,
    SelfDescribingDeserializer,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
)
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.field_meta import field_index
from emberserde.utils import Base

# JSON `Deserializer` format over EmberJson's existing hand-written `Parser`
# (`emberjson/_deserialize/parser.mojo`), ported to sit on top of
# emberserde's format-agnostic traits (`emberserde/emberserde/deserialize/
# __init__.mojo`). Structurally this mirrors `emberserde/test/_json_format.
# mojo`'s `JsonDeserializer`, but drives EmberJson's own byte-walking parser
# instead of a hand-rolled cursor. Since F16 the `Parser`'s token methods
# (`expect`, `expect_open`, `expect_string`, `expect_int`, `expect_float`,
# `expect_bool`, `expect_null`, `skip_value`, `read_string`, ...) declare
# `raises DeserializationError` and pick the `DerErrorKind` at the failure
# site, so this layer calls them directly: no try/except scaffolding, and
# no second, external guess at what the byte at the cursor meant.
# `_invalid`/`_mismatch` survive only for conditions THIS layer detects on
# its own (a trailing comma, a missing enum tag, an unusable `raw_bytes`
# request).
#
# Two origins, like the toy format's `Pointer[JsonCursor, origin]`, but
# split in two because `Parser` itself is generic over the origin of the
# input it borrows: `origin` is that input origin, `ptr_origin` is the
# origin of the pointer to the `Parser` instance itself (sub-deserializers
# share one `Parser` via this pointer, exactly like the toy shares one
# `JsonCursor`). `options` rides as a struct parameter since the
# `Deserializer` trait has no parameter channel of its own.
#
# Depth: each `begin_*` counts its container on the shared `Parser`'s
# `depth` (`enter_container`, against `options.max_depth`) and the matching
# `end` releases it; a raise abandons the parse, so nothing unwinds.
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
    var first: Bool

    def has_next(mut self) raises DeserializationError -> Bool:
        self.p[].skip_whitespace()
        if self.p[].peek() == `]`:
            return False
        if not self.first:
            # A separator is required between elements (`expect` raises
            # on anything else), and a separator followed by the closing
            # bracket is a trailing comma -- legal only when the options
            # say so. Mirrors `Parser.parse_array` exactly.
            self.p[].expect(`,`)
            if self.p[].peek() == `]`:
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    in Self.options.strict_mode
                ):
                    return False
                else:
                    raise _invalid("Illegal trailing comma")
        self.first = False
        return True

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.p[].expect(`]`)
        self.p[].depth -= 1


@fieldwise_init
struct EmberJsonMapDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](MapDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]
    var first: Bool
    # Strict mode only: keys already seen in this object (RFC 8259 §4 lets a
    # parser reject duplicates; `Value`/`Document` do, so `Dict` must too).
    var seen: Dict[String, Bool]

    def has_next(mut self) raises DeserializationError -> Bool:
        self.p[].skip_whitespace()
        if self.p[].peek() == `}`:
            return False
        if not self.first:
            # See `EmberJsonSeqDe.has_next`: required separator, trailing
            # comma legal only under `ALLOW_TRAILING_COMMA`.
            self.p[].expect(`,`)
            if self.p[].peek() == `}`:
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    in Self.options.strict_mode
                ):
                    return False
                else:
                    raise _invalid("Illegal trailing comma")
        self.first = False
        return True

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        # `has_next` has already skipped whitespace and any separating
        # comma, so the parser sits at the key token. EmberJson's `Dict`
        # deserialize path only ever asks for `String` keys (JSON object
        # keys are always strings), so this delegates straight through.
        var sub = EmberJsonDeserializer(p=self.p)
        comptime if T == String and not (
            StrictOptions.ALLOW_DUPLICATE_KEYS in Self.options.strict_mode
        ):
            comptime assert conforms_to(T, Base), "unreachable: T == String"
            var key = deserialize[T](sub)
            ref name = rebind[String](key)
            if name in self.seen:
                raise DeserializationError(
                    "Duplicate key: " + name, DerErrorKind.DuplicateField
                )
            self.seen[name] = True
            return key^
        else:
            return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.p[].expect(`:`)
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.p[].expect(`}`)
        self.p[].depth -= 1


@fieldwise_init
struct EmberJsonStructDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](StructDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]
    var first: Bool

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        self.p[].skip_whitespace()
        if self.p[].peek() == `}`:
            # End of struct: leave the `}` for `end()` to consume.
            return None
        if not self.first:
            # See `EmberJsonSeqDe.has_next`: required separator, trailing
            # comma legal only under `ALLOW_TRAILING_COMMA`.
            self.p[].expect(`,`)
            if self.p[].peek() == `}`:
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    in Self.options.strict_mode
                ):
                    return None
                else:
                    raise _invalid("Illegal trailing comma")
        self.first = False
        # A key is a grammar position, not a value position: whatever sits
        # here instead of a quote is malformed JSON, never "a value of the
        # wrong type", so this stays a deserializer-detected `_invalid`.
        if self.p[].peek() != `"`:
            raise _invalid("expected an object key string")
        # `scan_string` is the scanner under `read_string`, the reader
        # `Parser.parse_object` uses for its keys. An escape-free key
        # resolves as a slice of the input, no `String` per field; an
        # escaped one decodes exactly as `read_string` would -- including
        # the `ignore_unicode` opt-out -- so it matches `parse()`.
        var scan = self.p[].scan_string()
        self.p[].expect(`:`)
        if scan.found_escaped:
            return field_index[T](
                copy_to_string[Self.options.ignore_unicode](
                    scan.start, scan.end, True, scan.first_escape
                )
            )
        return field_index[T](
            StringSlice(
                unsafe_from_utf8=Span(
                    unsafe_ptr=scan.start,
                    length=ptr_dist(scan.start, scan.end),
                )
            )
        )

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        self.p[].skip_value()

    def end(mut self) raises DeserializationError:
        self.p[].expect(`}`)
        self.p[].depth -= 1


@fieldwise_init
struct EmberJsonTupleDe[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](TupleDerState):
    var p: Pointer[Parser[Self.origin, Self.options], Self.ptr_origin]
    var first: Bool

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        self.p[].skip_whitespace()
        if not self.first:
            self.p[].expect(`,`)
        self.first = False
        var sub = EmberJsonDeserializer(p=self.p)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.p[].expect(`]`)
        self.p[].depth -= 1


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
        self.p[].expect(`}`)
        self.p[].depth -= 1


@fieldwise_init
struct EmberJsonDeserializer[
    origin: ImmOrigin, options: ParseOptions, ptr_origin: MutOrigin
](BorrowingDeserializer, SelfDescribingDeserializer):
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
    comptime Value = Value

    # The three scalar entry points below are one call each: the `Parser`
    # method skips whitespace, parses, and on failure decides between
    # `TypeMismatch` (another COMPLETE value opens at the cursor) and
    # `InvalidValue` itself -- see `Parser._other_value_opens_here`. The
    # external classifier this layer used to run before every scalar is
    # gone: it duplicated the parser's own lookahead and could only guess
    # at conditions (integer overflow) the parser sees directly.
    def expect_bool(mut self) raises DeserializationError -> Bool:
        return self.p[].expect_bool()

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        comptime if DT.is_floating_point():
            return self.p[].expect_float[DT]()
        else:
            return self.p[].expect_int[DT]()

    def expect_string(mut self) raises DeserializationError -> String:
        return self.p[].expect_string()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        # No shape check here: `Optional` never rejects a shape on its own
        # -- anything other than `null` is handed to `deserialize[T]`
        # below, which does its own (possibly typed-mismatch) validation.
        self.p[].skip_whitespace()
        if self.p[].peek() == `n`:
            self.p[].expect_null()
            return Optional[T]()
        return Optional[T](deserialize[T](self))

    # `expect_open` is `expect` for a bracket standing at a VALUE position:
    # an absent value (EOF) is a grammar failure -- there is no byte to
    # disagree about -- while a different complete value opener is a shape
    # mismatch. `expect` itself stays grammar-only, for `:`/`,` and the
    # closing brackets.
    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        self.p[].expect_open(`[`)
        self.p[].enter_container()
        return EmberJsonSeqDe(p=self.p, first=True)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.p[].expect_open(`{`)
        self.p[].enter_container()
        return EmberJsonMapDe(p=self.p, first=True, seen=Dict[String, Bool]())

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        # Field names are read off the wire, so `T` is unused here;
        # `expect_field_index` resolves each key against it.
        self.p[].expect_open(`{`)
        self.p[].enter_container()
        return EmberJsonStructDe(p=self.p, first=True)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self.p[].expect_open(`[`)
        self.p[].enter_container()
        return EmberJsonTupleDe(p=self.p, first=True)

    # Externally tagged `{"Arm":payload}`: consume up to and including the
    # `:`, resolve the arm name to an index; the closing `}` is `end`'s job.
    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        # Only the opening `{` is a shape check (`expect_open`); a missing
        # tag string once inside an object is a grammar failure, not a
        # different-type mismatch, so it stays a deserializer-detected
        # `_invalid`.
        self.p[].expect_open(`{`)
        self.p[].enter_container()
        if self.p[].peek() != `"`:
            raise _invalid("expected an enum tag string")
        # Same decoding as `EmberJsonStructDe.expect_field_index` -- see
        # the comment there.
        var name = self.p[].read_string()
        self.p[].expect(`:`)
        var idx = -1
        # `comptime for` over the interned candidates: no per-value list.
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and name == an:
                idx = i
        return EmberJsonEnumDe(p=self.p, idx=idx)

    # `BorrowingDeserializer`: a `comptime if` dispatch over `Parser`'s six
    # existing byte-extractor entry points — one validated skip per kind, so
    # a kind mismatch (e.g. `Integer` against `1.5`) fails fast here instead
    # of deferring to whatever later tries to interpret the bytes. Each
    # `Parser` method returns `Span[Byte, Self.origin]`; the trait erases
    # that to `ImmUntrackedOrigin` (see `BorrowingDeserializer`'s doc
    # comment in emberserde) and the caller re-ties it.
    #
    # `expect_string_bytes` is the one extractor that does not skip leading
    # whitespace or validate the opening quote itself (its other call sites
    # — `_expect_key_and_colon`, `_expect_validated_bytes` — already do
    # both before calling it), so `Str` mirrors `expect_string` above and
    # does that positioning by hand. The other five extractors already
    # handle their own whitespace/shape validation.
    #
    # `_assume_padded` options mean `self.p` was built over a
    # `PaddedBuffer` (`_padded()`, set only by the entry points that copy
    # inputs at or above `PAD_INPUT_THRESHOLD` — see `Value.__init__(*,
    # parse_bytes=...)` in `emberjson/value.mojo`). That buffer does not
    # outlive the parse call, so a borrowed span into it would dangle.
    # Refuse here, at the format layer that knows the buffer's provenance,
    # rather than pushing the check onto every borrowing type built on
    # `raw_bytes` — this used to be `Lazy`'s own `comptime assert` in
    # `emberjson/lazy.mojo` before it moved here. The gate keys on the
    # padded flag alone: every other option (`ignore_unicode`,
    # `strict_mode`, `validate_utf8`) borrows from the caller's own buffer
    # and is safe. `comptime if` keeps the check free outside the padded
    # specialization's compiled code.
    def raw_bytes[
        kind: RawKind
    ](mut self) raises DeserializationError -> Span[Byte, ImmUntrackedOrigin]:
        comptime if Self.options._assume_padded:
            raise _invalid(
                "raw_bytes requires an unpadded input buffer -- borrowing is"
                " incompatible with the padded-buffer path"
            )
        comptime if kind == RawKind.Any:
            return rebind[Span[Byte, ImmUntrackedOrigin]](
                self.p[].expect_value_bytes()
            )
        elif kind == RawKind.Integer:
            return rebind[Span[Byte, ImmUntrackedOrigin]](
                self.p[].expect_int_bytes()
            )
        elif kind == RawKind.Float:
            return rebind[Span[Byte, ImmUntrackedOrigin]](
                self.p[].expect_float_bytes()
            )
        elif kind == RawKind.Str:
            # `expect_string_bytes` assumes its caller has already validated
            # the opening quote (its other call sites do), so position and
            # shape-check here. Anything but a quote at a value position
            # where a string was requested is a kind mismatch.
            self.p[].skip_whitespace()
            if self.p[].peek() != `"`:
                raise _mismatch("Expected a string")
            return rebind[Span[Byte, ImmUntrackedOrigin]](
                self.p[].expect_string_bytes()
            )
        elif kind == RawKind.Seq:
            return rebind[Span[Byte, ImmUntrackedOrigin]](
                self.p[].expect_array_bytes()
            )
        else:
            return rebind[Span[Byte, ImmUntrackedOrigin]](
                self.p[].expect_object_bytes()
            )

    # `SelfDescribingDeserializer`: `Value` (`emberjson/value.mojo`) already
    # has a fast, hand-written recursive-descent path for "parse whatever is
    # here" — `Parser.parse_value`, the same one `Value`'s old `from_json`
    # called. Reusing it beats re-deriving the shape from `begin_seq`/
    # `begin_map`/etc. token by token (as the toy `_json_format.mojo` does,
    # for lack of a real parser to lean on).
    def deserialize_any(mut self) raises DeserializationError -> Value:
        return self.p[].parse_value()


def from_json_bytewalk[
    o: ImmOrigin,
    //,
    T: Movable & Deinitable,
    options: ParseOptions = ParseOptions(),
](s: StringSlice[o], out result: T) raises DeserializationError:
    """Deserializes `s` into `T` through emberserde's framework, driven by
    `EmberJsonDeserializer` over EmberJson's hand-written `Parser`.

    This is the reference path: `from_json` (`indexed.mojo`) tries the
    structural-index deserializer first and falls back to this one for the
    error it reports.

    Parameters:
        T: The type to deserialize into.
        options: The parsing options handed to the underlying `Parser`.
            This is reflection's `ParseOptions` channel -- the deserializer
            is already parameterized on them, so `ignore_unicode`,
            `strict_mode` and friends reach the parser from here.

    Args:
        s: The input JSON text.

    Returns:
        The deserialized value.

    Raises:
        `DeserializationError` if `s` is not valid JSON, does not match
        the shape of `T`, or carries non-whitespace content after the
        root value.
    """
    # `_assume_padded` options are unconstructible from a plain slice
    # (`Parser.__init__` asserts on it), and `validate_utf8` is the
    # caller's to apply -- `emberjson.from_json` does, this private entry
    # point does not.
    var p = Parser[options=options](s)
    var d = EmberJsonDeserializer(p=Pointer(to=p))
    result = deserialize[T](d)
    # `parse()` rejects content after the root value; this entry point must
    # agree, or the two public paths accept different documents.
    p.skip_whitespace()
    if p.has_more():
        raise _invalid("trailing content after top-level JSON value")
