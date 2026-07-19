from .parser import Parser, ParseOptions, StrictOptions, RawNumber
from ._parser_helper import (
    StringBlock,
    ptr_dist,
    _next_backslash,
    hex_to_u32,
    is_numerical_component,
)
from emberjson.utils import BytePtr, ByteVec, to_string
from emberjson.simd import SIMD8_WIDTH
from emberjson.constants import (
    `"`,
    `t`,
    `f`,
    `n`,
    `b`,
    `r`,
    `/`,
    `{`,
    `}`,
    `[`,
    `]`,
    `,`,
    `:`,
    `u`,
    `\\`,
    `\n`,
    `\t`,
    `\r`,
    `\b`,
    `\f`,
    acceptable_escapes,
)
from std.memory import memcpy, memcmp, alloc, UnsafePointer
from std.sys.intrinsics import unlikely, likely


#######################################################
# Tape format (simdjson-style):
#
# The tape is a flat List[UInt64]; each word is an 8-bit tag in the top
# byte and a 56-bit payload below it.
#
#   NULL/TRUE/FALSE       one word, payload unused
#   INT64/UINT64/FLOAT64  tag word (payload unused) followed by one word
#                         holding the raw 64-bit value
#   STRING                payload = byte offset into the string arena;
#                         arena entry = u32 length + bytes + NUL
#   OBJECT_OPEN/ARRAY_OPEN
#                         payload bits 0..31  = tape index one past the
#                                               matching close word,
#                         payload bits 32..55 = element count, saturated
#                                               at COUNT_SATURATED
#   OBJECT_CLOSE/ARRAY_CLOSE
#                         payload = tape index of the matching open word
#
# Object children alternate key (STRING word) / value. The arena stores
# fully unescaped bytes, so navigation returns zero-copy views with no
# decode step.
#######################################################


struct TapeTag:
    comptime NULL: Byte = 0
    comptime TRUE: Byte = 1
    comptime FALSE: Byte = 2
    # INT64/UINT64/FLOAT64 are ordered to match RawNumber.INT64/UINT64/
    # FLOAT64 so a RawNumber kind maps to its tag by addition.
    comptime INT64: Byte = 3
    comptime UINT64: Byte = 4
    comptime FLOAT64: Byte = 5
    comptime STRING: Byte = 6
    comptime OBJECT_OPEN: Byte = 7
    comptime OBJECT_CLOSE: Byte = 8
    comptime ARRAY_OPEN: Byte = 9
    comptime ARRAY_CLOSE: Byte = 10


comptime PAYLOAD_MASK: UInt64 = (1 << 56) - 1
comptime CLOSE_MASK: UInt64 = 0xFFFF_FFFF
comptime COUNT_SATURATED: UInt64 = 0xFF_FFFF


@always_inline
def _pack_word(tag: Byte, payload: UInt64) -> UInt64:
    return UInt64(tag) << 56 | payload


@always_inline
def _pack_container_open(
    tag: Byte, one_past_close: Int, count: UInt64
) -> UInt64:
    var c = count if count < COUNT_SATURATED else COUNT_SATURATED
    return _pack_word(tag, UInt64(one_past_close) | c << 32)


@always_inline
def _tag_of(word: UInt64) -> Byte:
    return Byte(word >> 56)


@always_inline
def _payload_of(word: UInt64) -> UInt64:
    return word & PAYLOAD_MASK


@always_inline
def _next_tape_idx(tape: List[UInt64], i: Int) -> Int:
    """The tape index of the sibling after the value starting at `i`."""
    var t = _tag_of(tape[i])
    if t == TapeTag.OBJECT_OPEN or t == TapeTag.ARRAY_OPEN:
        return Int(_payload_of(tape[i]) & CLOSE_MASK)
    if t == TapeTag.INT64 or t == TapeTag.UINT64 or t == TapeTag.FLOAT64:
        return i + 2
    return i + 1


struct _Arena(Movable):
    """A raw growable byte buffer for the string arena.

    Deliberately not a `List`: string writes are the hottest allocation
    path in the tape builder, and `List.resize` both zero-fills the new
    region (the memcpy right after overwrites it anyway) and re-checks
    capacity per call. Here capacity is checked once per string and
    content is written exactly once."""

    var _ptr: UnsafePointer[Byte, MutUntrackedOrigin]
    var _len: Int
    var _cap: Int

    def __init__(out self, *, capacity: Int):
        self._cap = capacity if capacity > 64 else 64
        self._ptr = alloc[Byte](self._cap)
        self._len = 0

    def __del__(deinit self):
        self._ptr.free()

    @no_inline
    def _grow(mut self, needed: Int):
        var new_cap = self._cap * 2
        if new_cap < needed:
            new_cap = needed
        var new_ptr = alloc[Byte](new_cap)
        memcpy(dest=new_ptr, src=self._ptr, count=self._len)
        self._ptr.free()
        self._ptr = new_ptr
        self._cap = new_cap

    @always_inline
    def reserve_extra(mut self, extra: Int):
        """Guarantees `extra` writable bytes past `_len`."""
        if unlikely(self._len + extra > self._cap):
            self._grow(self._len + extra)


@always_inline
def _arena_len(strings: _Arena, off: Int) -> Int:
    return Int((strings._ptr + off).bitcast[UInt32]()[])


@always_inline
def _arena_view(strings: _Arena, off: Int) -> StringSlice[ImmutAnyOrigin]:
    var n = _arena_len(strings, off)
    var ptr = (
        (strings._ptr + off + 4)
        .as_immutable()
        .unsafe_origin_cast[ImmutAnyOrigin]()
    )
    var span = Span[Byte, ImmutAnyOrigin](ptr=ptr, length=n)
    return StringSlice(unsafe_from_utf8=span)


@always_inline
def _arena_str_eq(strings: _Arena, off_a: Int, off_b: Int) -> Bool:
    var len_a = _arena_len(strings, off_a)
    if len_a != _arena_len(strings, off_b):
        return False
    return (
        memcmp(strings._ptr + off_a + 4, strings._ptr + off_b + 4, len_a) == 0
    )


struct TapeSink(Movable):
    """The tape builder's output plus its shared scratch state."""

    var tape: List[UInt64]
    var strings: _Arena
    # Scratch stacks for strict-mode duplicate-key detection, shared by
    # every object in the parse (stack discipline: each object records the
    # length on entry and truncates back to it on exit) so small objects
    # never allocate. Keys compare hash-first, memcmp on hash match —
    # the same short-circuit the DOM parser gets from KeyValuePair.
    var key_hashes: List[UInt64]
    var key_offs: List[UInt32]

    def __init__(out self, *, tape_capacity: Int, strings_capacity: Int):
        self.tape = List[UInt64](capacity=tape_capacity)
        self.strings = _Arena(capacity=strings_capacity)
        self.key_hashes = List[UInt64]()
        self.key_offs = List[UInt32]()


def _handle_unicode_codepoint_ptr[
    o1: ImmutOrigin, o2: ImmutOrigin, //
](
    mut p: BytePtr[o1],
    mut w: UnsafePointer[Byte, MutUntrackedOrigin],
    end: BytePtr[o2],
) raises:
    """`handle_unicode_codepoint` retargeted at a raw write pointer.

    Safety:
        The caller must have reserved enough space behind `w`; a decoded
        codepoint never emits more bytes than its escape sequence spans.
    """
    if unlikely(p + 3 >= end):
        raise Error("Bad unicode codepoint")
    var c1 = hex_to_u32(p)
    p += 4

    if unlikely(c1 >= 0xDC00 and c1 < 0xE000):
        raise Error("Invalid unicode: lone surrogate")
    if c1 >= 0xD800 and c1 < 0xDC00:
        if unlikely(p + 5 >= end):
            raise Error("Bad unicode codepoint")
        elif unlikely(not (p[0] == `\\` and p[1] == `u`)):
            raise Error("Bad unicode codepoint")

        p += 2
        var c2 = hex_to_u32(p)

        if unlikely(c2 < 0xDC00 or c2 >= 0xE000):
            raise Error("Bad unicode codepoint")

        c1 = (((c1 - 0xD800) << 10) | (c2 - 0xDC00)) | 0x10000
        p += 4

    if unlikely(c1 > 0x10FFFF):
        raise Error("Invalid unicode")

    if c1 < 0x80:
        w[0] = UInt8(c1)
        w += 1
    elif c1 < 0x800:
        w[0] = UInt8(0xC0 | (c1 >> 6))
        w[1] = UInt8(0x80 | (c1 & 0x3F))
        w += 2
    elif c1 < 0x10000:
        w[0] = UInt8(0xE0 | (c1 >> 12))
        w[1] = UInt8(0x80 | ((c1 >> 6) & 0x3F))
        w[2] = UInt8(0x80 | (c1 & 0x3F))
        w += 3
    else:
        w[0] = UInt8(0xF0 | (c1 >> 18))
        w[1] = UInt8(0x80 | ((c1 >> 12) & 0x3F))
        w[2] = UInt8(0x80 | ((c1 >> 6) & 0x3F))
        w[3] = UInt8(0x80 | (c1 & 0x3F))
        w += 4


def _arena_write[
    ignore_unicode: Bool
](
    mut strings: _Arena,
    start: BytePtr,
    end: BytePtr,
    found_escaped: Bool,
    first_escape: Int,
) raises -> Int:
    """Appends the string bytes in [start, end) to the arena as
    `u32 length + bytes + NUL`, returning the entry's offset.

    Escape decoding only ever shrinks the byte count, so one capacity
    reservation up front covers the whole entry. The extra 8 bytes keep
    `_key_disc`'s 8-byte loads inside the allocation for short keys."""
    var raw_len = ptr_dist(start, end)
    strings.reserve_extra(5 + raw_len + 8)

    var off = strings._len
    var content = strings._ptr + off + 4
    var final_len: Int

    comptime decode = not ignore_unicode
    if decode and found_escaped:
        var w = content
        var p = start + first_escape

        if first_escape > 0:
            memcpy(dest=w, src=start, count=first_escape)
            w += first_escape

        while p < end:
            # Fast scan for next backslash, bulk-copying the clean run.
            var chunk_start = p
            p = _next_backslash(p, end)

            if p > chunk_start:
                var chunk_len = ptr_dist(chunk_start, p)
                memcpy(dest=w, src=chunk_start, count=chunk_len)
                w += chunk_len

            if p < end:
                p += 1  # skip backslash
                if p < end:
                    var c = p[0]
                    if c == `u`:
                        p += 1
                        _handle_unicode_codepoint_ptr(p, w, end)
                    elif c == `"`:
                        w[0] = `"`
                        w += 1
                        p += 1
                    elif c == `\\`:
                        w[0] = `\\`
                        w += 1
                        p += 1
                    elif c == `/`:
                        w[0] = `/`
                        w += 1
                        p += 1
                    elif c == `b`:
                        w[0] = `\b`
                        w += 1
                        p += 1
                    elif c == `f`:
                        w[0] = `\f`
                        w += 1
                        p += 1
                    elif c == `n`:
                        w[0] = `\n`
                        w += 1
                        p += 1
                    elif c == `r`:
                        w[0] = `\r`
                        w += 1
                        p += 1
                    elif c == `t`:
                        w[0] = `\t`
                        w += 1
                        p += 1
                    else:
                        raise Error("Invalid escape sequence")
        final_len = Int(w) - Int(content)
    else:
        memcpy(dest=content, src=start, count=raw_len)
        final_len = raw_len

    (strings._ptr + off).bitcast[UInt32]()[] = UInt32(final_len)
    content[final_len] = 0
    strings._len = off + 4 + final_len + 1
    return off


def _tape_string[
    origin: ImmutOrigin, options: ParseOptions, //
](mut p: Parser[origin, options], mut sink: TapeSink) raises:
    """Scans the string at the cursor (mirroring `Parser.find` /
    `Parser.read_serial`) and appends it to the arena + tape."""
    p.data += 1
    var start = p.data
    var end_ptr: BytePtr[origin]
    var found_escaped = False
    var first_escape = 0

    # compile time interpreter is incompatible with the SIMD accelerated
    # path, so fallback to the serial implementation (see read_string)
    if p.can_load_chunk():
        while True:
            var block: StringBlock
            comptime if options._assume_padded:
                block = StringBlock.find(p.data.p)
            else:
                block = StringBlock.find(p.data)
            if block.has_quote_first():
                p.data += block.quote_index()
                end_ptr = p.data.p
                p.data += 1
                break
            elif unlikely(p.data.p >= p.data.end):
                raise Error("Unexpected EOF")

            if unlikely(block.has_unescaped()):
                raise Error(
                    "Control characters must be escaped: ",
                    to_string(p.load_chunk()),
                    " : ",
                    String(block.unescaped_index()),
                )
            if not block.has_backslash():
                p.data += SIMD8_WIDTH
                continue
            p.data += block.bs_index()

            if not found_escaped:
                first_escape = ptr_dist(start.p, p.data.p)
            found_escaped = True
            while True:
                p.data += 1
                if p.cur() == `u`:
                    p.data += 1
                    break
                else:
                    if unlikely(p.cur() not in acceptable_escapes):
                        raise Error(
                            "Invalid escape sequence: ",
                            to_string(p.data[-1]),
                            to_string(p.cur()),
                        )
                p.data += 1
                if p.cur() != `\\`:
                    break
    else:
        while True:
            if unlikely(not p.has_more()):
                raise Error("Invalid String")
            if p.data[] == `"`:
                end_ptr = p.data.p
                p.data += 1
                break
            if p.data[] == `\\`:
                p.data += 1
                if unlikely(p.data[] not in acceptable_escapes):
                    raise Error(
                        "Invalid escape sequence: ",
                        to_string(p.data[-1]),
                        to_string(p.data[]),
                    )
                found_escaped = True
            comptime control_chars = ByteVec[4](`\n`, `\t`, `\r`, `\r`)
            if unlikely(p.data[] in control_chars):
                raise Error(
                    "Control characters must be escaped: ",
                    String(p.data[]),
                )
            p.data += 1

    var off = _arena_write[options.ignore_unicode](
        sink.strings, start.p, end_ptr, found_escaped, first_escape
    )
    sink.tape.append(_pack_word(TapeTag.STRING, UInt64(off)))


comptime _DISC_PRIME: UInt64 = 0x9E3779B185EBCA87


@always_inline
def _key_disc(strings: _Arena, off: Int) -> UInt64:
    """A cheap 64-bit discriminator over a key's arena bytes.

    Not a quality hash — collisions only cost a confirming memcmp in
    `_push_and_check_key`, so all that matters is that equal keys map to
    equal values and typical distinct keys (including sequential numeric
    ids) usually differ. Short keys are one masked load; longer keys use
    8-byte chunks with an overlapping final load. `_arena_write` reserves
    8 spare bytes so the short-key load stays inside the allocation."""
    var n = _arena_len(strings, off)
    var p = strings._ptr + off + 4
    if n <= 8:
        if n == 0:
            return _DISC_PRIME
        var w = p.bitcast[UInt64]()[]
        var mask_shift = UInt64(64 - 8 * n)
        w = (w << mask_shift) >> mask_shift
        return (w ^ UInt64(n)) * _DISC_PRIME
    var acc = UInt64(n) * _DISC_PRIME
    var i = 0
    while i + 8 <= n:
        acc = (acc ^ (p + i).bitcast[UInt64]()[]) * _DISC_PRIME
        i += 8
    if i < n:
        acc = (acc ^ (p + n - 8).bitcast[UInt64]()[]) * _DISC_PRIME
    return acc


def _push_and_check_key(mut sink: TapeSink, base: Int, key_off: Int) raises:
    """Strict-mode duplicate detection for the key at `key_off`, against
    the keys recorded since `base` (this object's slice of the shared
    scratch stacks)."""
    var h = _key_disc(sink.strings, key_off)
    for i in range(base, len(sink.key_hashes)):
        if unlikely(
            sink.key_hashes[i] == h
            and _arena_str_eq(sink.strings, Int(sink.key_offs[i]), key_off)
        ):
            raise Error("Duplicate key: ", _arena_view(sink.strings, key_off))
    sink.key_hashes.append(h)
    sink.key_offs.append(UInt32(key_off))


def _tape_object[
    origin: ImmutOrigin, options: ParseOptions, //
](mut p: Parser[origin, options], mut sink: TapeSink) raises:
    p.data += 1
    p.skip_whitespace()

    var open_idx = len(sink.tape)
    sink.tape.append(0)  # patched with _pack_container_open below
    var count: UInt64 = 0
    var dup_base = len(sink.key_hashes)

    if unlikely(p.cur() == `}`):
        pass
    else:
        while True:
            if unlikely(p.cur() != `"`):
                raise Error("Invalid identifier")
            _tape_string(p, sink)
            comptime if (
                StrictOptions.ALLOW_DUPLICATE_KEYS not in options.strict_mode
            ):
                _push_and_check_key(
                    sink,
                    dup_base,
                    Int(_payload_of(sink.tape[len(sink.tape) - 1])),
                )
            p.skip_whitespace()
            if unlikely(p.cur() != `:`):
                raise Error("Invalid identifier : ", p.remaining())
            p.data += 1
            _tape_value(p, sink)
            count += 1
            p.skip_whitespace()
            var has_comma = False
            if p.cur() == `,`:
                p.data += 1
                p.skip_whitespace()
                has_comma = True

            if p.cur() == `}`:
                comptime if (
                    not StrictOptions.ALLOW_TRAILING_COMMA
                    in options.strict_mode
                ):
                    if has_comma:
                        raise Error("Illegal trailing comma")
                break
            elif not has_comma:
                raise Error("Expected ',' or '}'")
            if unlikely(p.bytes_remaining() == 0):
                raise Error("Expected '}'")

    p.data += 1
    p.skip_whitespace()
    sink.tape.append(_pack_word(TapeTag.OBJECT_CLOSE, UInt64(open_idx)))
    sink.tape[open_idx] = _pack_container_open(
        TapeTag.OBJECT_OPEN, len(sink.tape), count
    )
    comptime if StrictOptions.ALLOW_DUPLICATE_KEYS not in options.strict_mode:
        sink.key_hashes.resize(dup_base, 0)
        sink.key_offs.resize(dup_base, 0)


def _tape_array[
    origin: ImmutOrigin, options: ParseOptions, //
](mut p: Parser[origin, options], mut sink: TapeSink) raises:
    p.data += 1
    p.skip_whitespace()

    var open_idx = len(sink.tape)
    sink.tape.append(0)  # patched with _pack_container_open below
    var count: UInt64 = 0

    if unlikely(p.cur() == `]`):
        pass
    else:
        while True:
            _tape_value(p, sink)
            count += 1
            p.skip_whitespace()
            var has_comma = False
            if p.cur() == `,`:
                p.data += 1
                has_comma = True
                p.skip_whitespace()
            if p.cur() == `]`:
                comptime if (
                    StrictOptions.ALLOW_TRAILING_COMMA
                    not in options.strict_mode
                ):
                    if has_comma:
                        raise Error("Illegal trailing comma")
                break
            elif unlikely(not has_comma):
                raise Error("Expected ',' or ']'")
            if unlikely(not p.has_more()):
                raise Error("Expected ']'")

    p.data += 1
    p.skip_whitespace()
    sink.tape.append(_pack_word(TapeTag.ARRAY_CLOSE, UInt64(open_idx)))
    sink.tape[open_idx] = _pack_container_open(
        TapeTag.ARRAY_OPEN, len(sink.tape), count
    )


def _tape_value[
    origin: ImmutOrigin, options: ParseOptions, //
](mut p: Parser[origin, options], mut sink: TapeSink) raises:
    p.skip_whitespace()
    var b = p.cur()
    if b == `"`:
        _tape_string(p, sink)
    elif b == `t`:
        _ = p.parse_true()
        sink.tape.append(_pack_word(TapeTag.TRUE, 0))
    elif b == `f`:
        _ = p.parse_false()
        sink.tape.append(_pack_word(TapeTag.FALSE, 0))
    elif b == `n`:
        _ = p.parse_null()
        sink.tape.append(_pack_word(TapeTag.NULL, 0))
    elif b == `{`:
        _tape_object(p, sink)
    elif b == `[`:
        _tape_array(p, sink)
    elif is_numerical_component(b):
        var r = p._parse_number_raw()
        # RawNumber kinds are ordered to match the number tags.
        sink.tape.append(_pack_word(TapeTag.INT64 + r.kind, 0))
        sink.tape.append(r.bits)
    else:
        raise Error("Invalid json value")


def parse_document_tape[
    origin: ImmutOrigin, options: ParseOptions, //
](mut p: Parser[origin, options], mut sink: TapeSink) raises:
    """Parses the parser's whole input onto `sink`, enforcing the same
    grammar, strictness and trailing-input rules as `Parser.parse`."""
    p.skip_whitespace()
    _tape_value(p, sink)

    p.skip_whitespace()
    if unlikely(p.has_more()):
        raise Error(
            "Invalid json, expected end of input, recieved: ",
            p.remaining(),
        )
