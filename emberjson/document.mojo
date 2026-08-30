from .value import Value, Null
from .object import Object
from .array import Array
from .utils import PaddedBuffer, PAD_INPUT_THRESHOLD, write_escaped_string
from ._deserialize.parser import Parser, ParseOptions, StrictOptions
from ._deserialize.tape import (
    parse_document_tape,
    TapeSink,
)
from ._deserialize.tape_indexed import parse_document_tape_indexed
from ._deserialize.tape import (
    TapeTag,
    CLOSE_MASK,
    COUNT_SATURATED,
    _tag_of,
    _payload_of,
    _next_tape_idx,
    _arena_len,
    _Arena,
)
from .teju import write_float
from ._utf8 import is_valid_utf8
from std.format._utils import _WriteBufferStack
from std.memory import unsafe_memcmp
from std.memory.unsafe import bitcast
from std.sys.intrinsics import unlikely, likely


struct Document(Movable, Writable):
    """An immutable, self-contained parse of a JSON document onto a flat
    tape plus a shared string arena (simdjson-style).

    Compared to `parse` -> `Value`, a `Document` performs no per-node
    allocation: containers are tape spans and every string lives in one
    arena, which is what makes `parse_document` several times faster on
    document-heavy inputs. The trade-offs:

    - The tree is read-only. To mutate (or to keep a subtree beyond the
      `Document`'s lifetime), materialize it with `to_value()` — that is
      exactly the tree-build work `parse` would have done up front.
    - Navigation values (`DocValue`/`DocObject`/`DocArray`) borrow the
      `Document` and cannot outlive it; the origin system enforces this
      at compile time.
    - Object field lookup scans the tape (the mutable `Object` already
      scans a list, so complexity is unchanged).

    The `Document` owns all of its data: the input buffer may be freed as
    soon as `parse_document` returns.
    """

    var _tape: List[UInt64]
    var _strings: _Arena
    # True when the document was parsed with ALLOW_DUPLICATE_KEYS, in
    # which case duplicate keys coexist on the tape and lookups return
    # the last match to preserve the DOM's last-write-wins semantics.
    var _dup_keys_possible: Bool

    def __init__(
        out self,
        var tape: List[UInt64],
        var strings: _Arena,
        dup_keys_possible: Bool,
    ):
        self._tape = tape^
        self._strings = strings^
        self._dup_keys_possible = dup_keys_possible

    @always_inline
    def root(self) -> DocValue[origin_of(self)]:
        """The document's top-level value. Borrows `self`."""
        return DocValue(Pointer(to=self), 0)

    def to_value(self) raises -> Value:
        """Materializes the document into an owned, mutable `Value` tree."""
        return _tape_to_value(self, 0)

    def write_to(self, mut writer: Some[Writer]):
        _ = _write_tape_value(self, 0, writer)

    def to_string(self, out s: String):
        s = String()
        var writer = _WriteBufferStack(s)
        self.write_to(writer)
        writer.flush()


struct DocValue[origin: ImmOrigin](Sized, TrivialRegisterPassable):
    """A read-only view of one value inside a `Document`."""

    var _doc: Pointer[Document, Self.origin]
    var _idx: Int

    @always_inline
    def __init__(out self, doc: Pointer[Document, Self.origin], idx: Int):
        self._doc = doc
        self._idx = idx

    @always_inline
    def _word(self) -> UInt64:
        return self._doc[]._tape[self._idx]

    @always_inline
    def tag(self) -> Byte:
        return _tag_of(self._word())

    @always_inline
    def is_int(self) -> Bool:
        return self.tag() == TapeTag.INT64

    @always_inline
    def is_uint(self) -> Bool:
        return self.tag() == TapeTag.UINT64

    @always_inline
    def is_float(self) -> Bool:
        return self.tag() == TapeTag.FLOAT64

    @always_inline
    def is_string(self) -> Bool:
        return self.tag() == TapeTag.STRING

    @always_inline
    def is_bool(self) -> Bool:
        return self.tag() == TapeTag.TRUE or self.tag() == TapeTag.FALSE

    @always_inline
    def is_null(self) -> Bool:
        return self.tag() == TapeTag.NULL

    @always_inline
    def is_object(self) -> Bool:
        return self.tag() == TapeTag.OBJECT_OPEN

    @always_inline
    def is_array(self) -> Bool:
        return self.tag() == TapeTag.ARRAY_OPEN

    @always_inline
    def _payload_word(self) -> UInt64:
        return self._doc[]._tape[self._idx + 1]

    def int(self) raises -> Int64:
        if self.is_int():
            return bitcast[DType.int64](self._payload_word())
        elif self.is_uint():
            return Int64(self._payload_word())
        raise Error("DocValue is not an integer")

    def uint(self) raises -> UInt64:
        if self.is_uint():
            return self._payload_word()
        elif self.is_int():
            return UInt64(bitcast[DType.int64](self._payload_word()))
        raise Error("DocValue is not an integer")

    def float(self) raises -> Float64:
        if unlikely(not self.is_float()):
            raise Error("DocValue is not a float")
        return bitcast[DType.float64](self._payload_word())

    def bool(self) raises -> Bool:
        if self.tag() == TapeTag.TRUE:
            return True
        elif self.tag() == TapeTag.FALSE:
            return False
        raise Error("DocValue is not a bool")

    def string_slice(self) raises -> StringSlice[Self.origin]:
        """A zero-copy view of the (already unescaped) string bytes."""
        if unlikely(not self.is_string()):
            raise Error("DocValue is not a string")
        return _arena_slice[Self.origin](
            self._doc[]._strings, Int(_payload_of(self._word()))
        )

    @always_inline
    def string(self) raises -> String:
        """An owned copy of the string value."""
        return String(self.string_slice())

    def object(self) raises -> DocObject[Self.origin]:
        if unlikely(not self.is_object()):
            raise Error("DocValue is not an object")
        return DocObject(self._doc, self._idx)

    def array(self) raises -> DocArray[Self.origin]:
        if unlikely(not self.is_array()):
            raise Error("DocValue is not an array")
        return DocArray(self._doc, self._idx)

    def __getitem__(self, key: StringSlice) raises -> DocValue[Self.origin]:
        return self.object()[key]

    def __getitem__(self, idx: Int) raises -> DocValue[Self.origin]:
        return self.array()[idx]

    def __len__(self) -> Int:
        """Element count for containers, byte length for strings, -1
        otherwise (mirroring `Value.__len__`)."""
        var t = self.tag()
        if t == TapeTag.OBJECT_OPEN or t == TapeTag.ARRAY_OPEN:
            return _container_count(self._doc[]._tape, self._idx)
        if t == TapeTag.STRING:
            return _arena_len(
                self._doc[]._strings, Int(_payload_of(self._word()))
            )
        return -1

    @always_inline
    def to_value(self) raises -> Value:
        """Materializes this subtree into an owned, mutable `Value`."""
        return _tape_to_value(self._doc[], self._idx)

    def write_to(self, mut writer: Some[Writer]):
        _ = _write_tape_value(self._doc[], self._idx, writer)


@fieldwise_init
struct DocEntry[origin: ImmOrigin](TrivialRegisterPassable):
    """One key-value pair yielded when iterating a `DocObject`."""

    var key: StringSlice[Self.origin]
    var value: DocValue[Self.origin]


struct DocObject[origin: ImmOrigin](Sized, TrivialRegisterPassable):
    """A read-only view of an object inside a `Document`."""

    var _doc: Pointer[Document, Self.origin]
    var _open_idx: Int

    @always_inline
    def __init__(out self, doc: Pointer[Document, Self.origin], open_idx: Int):
        self._doc = doc
        self._open_idx = open_idx

    @always_inline
    def _close_idx(self) -> Int:
        return (
            Int(_payload_of(self._doc[]._tape[self._open_idx]) & CLOSE_MASK) - 1
        )

    @always_inline
    def __len__(self) -> Int:
        return _container_count(self._doc[]._tape, self._open_idx)

    def _find(self, key: StringSlice) -> Int:
        """The tape index of `key`'s value, or -1. Scans pairs with O(1)
        sibling hops; for documents parsed with ALLOW_DUPLICATE_KEYS the
        last match wins (matching the DOM's last-write-wins collapse)."""
        var needle = key.as_bytes()
        var n = len(needle)
        var close = self._close_idx()
        var k = self._open_idx + 1
        var found = -1
        while k < close:
            var off = Int(_payload_of(self._doc[]._tape[k]))
            if (
                _arena_len(self._doc[]._strings, off) == n
                and unsafe_memcmp(
                    self._doc[]
                    ._strings._ptr.unsafe_offset(off)
                    .unsafe_offset(4),
                    needle.unsafe_ptr(),
                    n,
                )
                == 0
            ):
                found = k + 1
                if not self._doc[]._dup_keys_possible:
                    return found
            k = _next_tape_idx(self._doc[]._tape, k + 1)
        return found

    def __getitem__(self, key: StringSlice) raises -> DocValue[Self.origin]:
        var idx = self._find(key)
        if unlikely(idx < 0):
            raise Error("KeyError: ", key)
        return DocValue(self._doc, idx)

    @always_inline
    def __contains__(self, key: StringSlice) -> Bool:
        return self._find(key) >= 0

    @always_inline
    def items(self) -> _DocObjectIter[Self.origin]:
        return _DocObjectIter(self._doc, self._open_idx + 1, self._close_idx())

    @always_inline
    def __iter__(self) -> _DocObjectIter[Self.origin]:
        return self.items()


struct DocArray[origin: ImmOrigin](Sized, TrivialRegisterPassable):
    """A read-only view of an array inside a `Document`."""

    var _doc: Pointer[Document, Self.origin]
    var _open_idx: Int

    @always_inline
    def __init__(out self, doc: Pointer[Document, Self.origin], open_idx: Int):
        self._doc = doc
        self._open_idx = open_idx

    @always_inline
    def _close_idx(self) -> Int:
        return (
            Int(_payload_of(self._doc[]._tape[self._open_idx]) & CLOSE_MASK) - 1
        )

    @always_inline
    def __len__(self) -> Int:
        return _container_count(self._doc[]._tape, self._open_idx)

    def __getitem__(self, idx: Int) raises -> DocValue[Self.origin]:
        """The element at `idx`. O(idx) sibling hops (containers are
        skipped in O(1) via their close-index words)."""
        var close = self._close_idx()
        var k = self._open_idx + 1
        var remaining = idx
        while k < close:
            if remaining == 0:
                return DocValue(self._doc, k)
            remaining -= 1
            k = _next_tape_idx(self._doc[]._tape, k)
        raise Error("index out of bounds")

    @always_inline
    def __iter__(self) -> _DocArrayIter[Self.origin]:
        return _DocArrayIter(self._doc, self._open_idx + 1, self._close_idx())


struct _DocArrayIter[origin: ImmOrigin](Sized, TrivialRegisterPassable):
    var _doc: Pointer[Document, Self.origin]
    var _cur: Int
    var _close: Int

    @always_inline
    def __init__(
        out self, doc: Pointer[Document, Self.origin], cur: Int, close: Int
    ):
        self._doc = doc
        self._cur = cur
        self._close = close

    @always_inline
    def __iter__(self) -> Self:
        return self

    def __next__(mut self) raises StopIteration -> DocValue[Self.origin]:
        if self._cur >= self._close:
            raise StopIteration()
        var idx = self._cur
        self._cur = _next_tape_idx(self._doc[]._tape, idx)
        return DocValue(self._doc, idx)

    def __len__(self) -> Int:
        var n = 0
        var k = self._cur
        while k < self._close:
            n += 1
            k = _next_tape_idx(self._doc[]._tape, k)
        return n


struct _DocObjectIter[origin: ImmOrigin](Sized, TrivialRegisterPassable):
    var _doc: Pointer[Document, Self.origin]
    var _cur: Int
    var _close: Int

    @always_inline
    def __init__(
        out self, doc: Pointer[Document, Self.origin], cur: Int, close: Int
    ):
        self._doc = doc
        self._cur = cur
        self._close = close

    @always_inline
    def __iter__(self) -> Self:
        return self

    def __next__(mut self) raises StopIteration -> DocEntry[Self.origin]:
        if self._cur >= self._close:
            raise StopIteration()
        var key_idx = self._cur
        var value_idx = key_idx + 1
        self._cur = _next_tape_idx(self._doc[]._tape, value_idx)
        return DocEntry(
            _arena_slice[Self.origin](
                self._doc[]._strings,
                Int(_payload_of(self._doc[]._tape[key_idx])),
            ),
            DocValue(self._doc, value_idx),
        )

    def __len__(self) -> Int:
        var n = 0
        var k = self._cur
        while k < self._close:
            n += 1
            k = _next_tape_idx(self._doc[]._tape, k + 1)
        return n


@always_inline
def _arena_slice[
    origin: ImmOrigin
](strings: _Arena, off: Int) -> StringSlice[origin]:
    var n = _arena_len(strings, off)
    var ptr = (
        (strings._ptr.unsafe_offset(off).unsafe_offset(4))
        .as_imm()
        .unsafe_origin_cast[origin]()
    )
    var span = Span[Byte, origin](unsafe_ptr=ptr, length=n)
    return StringSlice(unsafe_from_utf8=span)


def _container_count(tape: List[UInt64], open_idx: Int) -> Int:
    var payload = _payload_of(tape[open_idx])
    var count = payload >> 32
    if likely(count < COUNT_SATURATED):
        return Int(count)
    # Saturated: count exactly by walking siblings.
    var close = Int(payload & CLOSE_MASK) - 1
    var is_object = _tag_of(tape[open_idx]) == TapeTag.OBJECT_OPEN
    var n = 0
    var k = open_idx + 1
    while k < close:
        n += 1
        k = _next_tape_idx(tape, k + 1 if is_object else k)
    return n


def _tape_to_value(doc: Document, idx: Int, out v: Value) raises:
    var word = doc._tape[idx]
    var t = _tag_of(word)
    if t == TapeTag.STRING:
        v = String(
            _arena_slice[ImmutAnyOrigin](doc._strings, Int(_payload_of(word)))
        )
    elif t == TapeTag.INT64:
        v = bitcast[DType.int64](doc._tape[idx + 1])
    elif t == TapeTag.UINT64:
        v = doc._tape[idx + 1]
    elif t == TapeTag.FLOAT64:
        v = bitcast[DType.float64](doc._tape[idx + 1])
    elif t == TapeTag.TRUE:
        v = True
    elif t == TapeTag.FALSE:
        v = False
    elif t == TapeTag.NULL:
        v = Null()
    elif t == TapeTag.ARRAY_OPEN:
        var close = Int(_payload_of(word) & CLOSE_MASK) - 1
        var arr = Array(capacity=_container_count(doc._tape, idx))
        var k = idx + 1
        while k < close:
            arr.append(_tape_to_value(doc, k))
            k = _next_tape_idx(doc._tape, k)
        v = arr^
    else:
        var close = Int(_payload_of(word) & CLOSE_MASK) - 1
        var obj = Object(capacity=_container_count(doc._tape, idx))
        var k = idx + 1
        while k < close:
            var key = String(
                _arena_slice[ImmutAnyOrigin](
                    doc._strings, Int(_payload_of(doc._tape[k]))
                )
            )
            var item = _tape_to_value(doc, k + 1)
            # Strict-mode tapes cannot contain duplicate keys, so the
            # duplicate scan is skipped; lenient tapes collapse through
            # `_upsert` with last-write-wins, matching the DOM parser.
            if doc._dup_keys_possible:
                obj[key^] = item^
            else:
                obj._append_unchecked(key^, item^)
            k = _next_tape_idx(doc._tape, k + 1)
        v = obj^


def _write_arena_string(doc: Document, off: Int, mut writer: Some[Writer]):
    write_escaped_string(
        _arena_slice[ImmutAnyOrigin](doc._strings, off), writer
    )


def _write_tape_value(doc: Document, idx: Int, mut writer: Some[Writer]) -> Int:
    """Serializes the value starting at `idx`, returning the index one past
    it. Mirrors `Value.write_to` output byte for byte."""
    var word = doc._tape[idx]
    var t = _tag_of(word)
    if t == TapeTag.STRING:
        _write_arena_string(doc, Int(_payload_of(word)), writer)
        return idx + 1
    elif t == TapeTag.INT64:
        writer.write(bitcast[DType.int64](doc._tape[idx + 1]))
        return idx + 2
    elif t == TapeTag.UINT64:
        writer.write(doc._tape[idx + 1])
        return idx + 2
    elif t == TapeTag.FLOAT64:
        write_float(bitcast[DType.float64](doc._tape[idx + 1]), writer)
        return idx + 2
    elif t == TapeTag.TRUE:
        writer.write("true")
        return idx + 1
    elif t == TapeTag.FALSE:
        writer.write("false")
        return idx + 1
    elif t == TapeTag.NULL:
        writer.write("null")
        return idx + 1
    elif t == TapeTag.ARRAY_OPEN:
        var close = Int(_payload_of(word) & CLOSE_MASK) - 1
        writer.write("[")
        var k = idx + 1
        var first = True
        while k < close:
            if not first:
                writer.write(",")
            first = False
            k = _write_tape_value(doc, k, writer)
        writer.write("]")
        return close + 1
    else:
        var close = Int(_payload_of(word) & CLOSE_MASK) - 1
        writer.write("{")
        var k = idx + 1
        var first = True
        while k < close:
            if not first:
                writer.write(",")
            first = False
            _write_arena_string(doc, Int(_payload_of(doc._tape[k])), writer)
            writer.write(":")
            k = _write_tape_value(doc, k + 1, writer)
        writer.write("}")
        return close + 1


def _parse_document_root[
    options: ParseOptions
](s: StringSlice) raises -> Document:
    """`parse_document`'s parse, with the UTF-8 pre-pass removed.

    Split out so `emberjson.from_json` can run the pre-pass once at the
    top and dispatch here without paying for it twice. Callers are
    responsible for having validated the input (or for deliberately
    skipping validation).
    """
    var sink = TapeSink(
        tape_capacity=s.byte_length() // 3 + 8,
        strings_capacity=s.byte_length() // 2 + 16,
    )
    # See `emberjson.from_json`: pad-and-copy enables unchecked hot loops;
    # tiny inputs skip the copy since it would cost more than the parse.
    if s.byte_length() < PAD_INPUT_THRESHOLD:
        var p = Parser[options=options](s)
        parse_document_tape(p, sink)
    else:
        # Padded inputs take the two-stage engine (structural index +
        # simdjson-style stage-2 walk); it beats the byte-walk on every
        # corpus workload.
        var buf = PaddedBuffer(s.as_bytes())
        var p = Parser[options=options._padded()](padded=buf)
        parse_document_tape_indexed(p, sink)
    return _finish_document[options](sink^)


def parse_document[
    options: ParseOptions = ParseOptions()
](s: StringSlice) raises -> Document:
    """Parses a JSON document onto an immutable tape `Document`.

    Several times faster than `parse` on document-heavy inputs because it
    performs no per-node allocation; see `Document` for the trade-offs.

    Parameters:
        options: The parsing options to be applied.

    Args:
        s: The input String.

    Returns:
        The parsed `Document`, which owns all of its data.

    Raises:
        If an invalid JSON string is provided.
    """
    comptime if options.validate_utf8:
        if not is_valid_utf8(s):
            raise Error("Invalid UTF-8 in input")
    return _parse_document_root[options._utf8_validated()](s)


def _finish_document[options: ParseOptions](var sink: TapeSink) -> Document:
    """Moves a finished sink's outputs into a `Document`.

    Swaps the outputs out of the sink rather than moving its fields:
    partial field moves of a struct with a destructor are rejected by
    the compiler's destruction analysis.
    """
    var tape = List[UInt64]()
    var strings = _Arena(capacity=0)
    swap(tape, sink.tape)
    swap(strings, sink.strings)
    return Document(
        tape^,
        strings^,
        StrictOptions.ALLOW_DUPLICATE_KEYS in options.strict_mode,
    )


@always_inline
def try_parse_document[
    options: ParseOptions = ParseOptions()
](s: StringSlice) -> Optional[Document]:
    try:
        return parse_document[options](s)
    except:
        return {}
