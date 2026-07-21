"""Index-driven tape builder: simdjson's stage 2 over our stage-1 index.

A port of simdjson's stage-2 document walker (Langdale & Lemire,
arXiv:1902.08318; `src/generic/stage2/{structural_iterator,
json_iterator,tape_builder}.h`) targeting this library's tape + arena:

  * The structural iterator is a raw post-incremented pointer into the
    stage-1 position array — `advance()` is one index load and one byte
    load, with NO bounds check per token. Termination is guaranteed by
    sentinel entries appended after the real structurals: they point at
    end-of-input, where the `PaddedBuffer` NUL fails every dispatch.
  * The document walk is ITERATIVE — simdjson's goto state machine
    rendered as a state loop with an explicit scope stack (max depth
    1024, like simdjson's DEFAULT_MAX_DEPTH) — so nesting costs no call
    frames and the hot loop stays branch-predictable.
  * Whitespace is never touched, string content spans are known before
    the string is read (both quotes of every string are structurals),
    and each token is dispatched from exactly one byte load.

Output is identical to `tape.mojo`'s byte-walk builder (same tape words,
same arena layout, same strictness semantics and accept/reject
verdicts). Two checks the index makes necessary keep that parity:

  * `_check_token_end`: a number/literal must be followed by whitespace,
    a structural byte, or end-of-input — a scalar-run tail like `12x`
    (a single scalar start in the index) would otherwise go unexamined.
  * `_iscan_string`: string spans are validated for unescaped control
    characters (and, in `ignore_unicode` mode, escape names) since the
    byte-walk scanner performs those checks inline.

Requires padded input (`PaddedBuffer`): stage 1 loads whole 64-byte
chunks and the token parsers overread into NUL padding.
"""

from .parser import Parser, ParseOptions, StrictOptions
from .tape import (
    TapeSink,
    TapeTag,
    _pack_word,
    _pack_container_open,
    _payload_of,
    _arena_write,
    _push_and_check_key,
)
from ._parser_helper import (
    Bits_T,
    is_numerical_component,
    pack_into_integer,
)
from emberjson._index import structural_index
from emberjson.utils import is_space, to_string, lut, StackArray
from emberjson.simd import SIMD8_WIDTH
from emberjson.constants import (
    `"`,
    `t`,
    `f`,
    `n`,
    `{`,
    `}`,
    `[`,
    `]`,
    `,`,
    `:`,
    ` `,
    `\\`,
    acceptable_escapes,
)
from std.collections import InlineArray
from std.bit import count_trailing_zeros
from std.memory import UnsafePointer
from std.sys.intrinsics import unlikely, likely


def _gen_token_end_table(out t: StackArray[Bool, 256]):
    t = StackArray[Bool, 256](fill=False)
    t.unsafe_get(0) = True  # NUL padding at end-of-input
    t.unsafe_get(Int(` `)) = True
    t.unsafe_get(0x09) = True
    t.unsafe_get(0x0A) = True
    t.unsafe_get(0x0D) = True
    t.unsafe_get(Int(`,`)) = True
    t.unsafe_get(Int(`:`)) = True
    t.unsafe_get(Int(`[`)) = True
    t.unsafe_get(Int(`]`)) = True
    t.unsafe_get(Int(`{`)) = True
    t.unsafe_get(Int(`}`)) = True
    t.unsafe_get(Int(`"`)) = True


comptime _TOKEN_END_OK: StackArray[Bool, 256] = _gen_token_end_table()


@always_inline
def _check_token_end[
    origin: ImmutOrigin, options: ParseOptions, //
](p: Parser[origin, options]) raises:
    """After a number/literal, the next byte must terminate the token."""
    var b = p.data.unsafe_get()
    if likely(lut[_TOKEN_END_OK](Int(b))):
        return
    raise Error("Invalid json value: ", to_string(b))


def _validate_escape_names[
    origin: ImmutOrigin, options: ParseOptions, //
](p: Parser[origin, options], off: Int, end_off: Int) raises:
    """Escape-name validation for the `ignore_unicode` verbatim path (the
    decode path validates names itself)."""
    var q = p.data.start + off
    var end = p.data.start + end_off
    while q < end:
        if q[] == `\\`:
            if q + 1 >= end:
                break
            if unlikely((q + 1)[] not in acceptable_escapes):
                raise Error("Invalid escape sequence: ", to_string((q + 1)[]))
            q += 2
            continue
        q += 1


def _iscan_string[
    origin: ImmutOrigin, options: ParseOptions, //
](p: Parser[origin, options], start_off: Int, end_off: Int) raises -> Tuple[
    Bool, Int
]:
    """Validates the string content span and locates its first escape.

    Returns (found_escaped, first_escape offset within the span). Raises
    on unescaped control characters, mirroring the byte-walk scanner.
    """
    var base = p.data.start + start_off
    var n = end_off - start_off
    var i = 0
    var found = False
    var first = 0
    while i < n:
        # Padded input: a full-width load past the span is safe.
        var chunk = (base + i).load[width=SIMD8_WIDTH]()
        var ctrl = pack_into_integer(chunk.lt(` `))
        var bs = pack_into_integer(chunk.eq(`\\`))
        var valid = n - i
        if valid < SIMD8_WIDTH:
            var lanemask = (Bits_T(1) << Bits_T(valid)) - 1
            ctrl &= lanemask
            bs &= lanemask
        if unlikely(ctrl != 0):
            raise Error(
                "Control characters must be escaped: ",
                String(count_trailing_zeros(ctrl)),
            )
        if bs != 0 and not found:
            found = True
            first = i + Int(count_trailing_zeros(bs))
        i += SIMD8_WIDTH

    comptime if options.ignore_unicode:
        if found:
            _validate_escape_names(p, start_off + first, end_off)
    return (found, first)


# One scope per open container, mirroring simdjson's
# `open_containers[depth]` (tape position + element count) plus this
# library's strict-mode duplicate-key scratch base.
@fieldwise_init
struct _Scope(TrivialRegisterPassable):
    var tape_idx: UInt32
    var count: UInt32
    var dup_base: UInt32
    var is_object: Bool


comptime _MAX_DEPTH = 1024

# Walk states (simdjson's goto labels).
comptime _OBJECT_BEGIN: Int = 0
comptime _OBJECT_CONTINUE: Int = 1
comptime _ARRAY_BEGIN: Int = 2
comptime _ARRAY_CONTINUE: Int = 3
comptime _SCOPE_END: Int = 4


def parse_document_tape_indexed[
    origin: ImmutOrigin, options: ParseOptions, //
](mut p: Parser[origin, options], mut sink: TapeSink) raises:
    """Stage-1 + stage-2 parse of the parser's whole input.

    Same tape/arena output and verdicts as `parse_document_tape`.
    Requires `PaddedBuffer`-backed input.
    """
    var positions = List[UInt32]()
    structural_index[True](p.data.start, p.size, positions)
    var n_structurals = len(positions)
    if unlikely(n_structurals == 0):
        raise Error("Invalid json value")
    # Sentinels (simdjson stage-1 convention): entries past the real
    # structurals point at end-of-input, where the padding NUL fails
    # every dispatch — this is what lets `advance` skip bounds checks.
    for _ in range(3):
        positions.append(UInt32(p.size))
    _walk_tape_from_index(p, sink, positions.unsafe_ptr(), n_structurals)


def _walk_tape_from_index[
    origin: ImmutOrigin, options: ParseOptions, //
](
    mut p: Parser[origin, options],
    mut sink: TapeSink,
    idx_start: UnsafePointer[UInt32, _],
    n_structurals: Int,
) raises:
    """Stage-2 walk over a precomputed structural index.

    Pointer contract: entries `[0, n_structurals)` are strictly ascending
    byte offsets `< p.size` (as produced by `structural_index[True]` or
    the GPU pipeline); entries `[n_structurals, n_structurals + 3)` equal
    `p.size`; and the byte at `base[p.size]` must fail every token
    dispatch (the padding NUL — or a `\\n`/`\\r` line delimiter when
    walking one line of a whole-file buffer in batch mode).
    """
    comptime assert (
        options._assume_padded
    ), "the indexed tape builder requires padded input"
    comptime strict_dups = (
        StrictOptions.ALLOW_DUPLICATE_KEYS not in options.strict_mode
    )
    comptime allow_trailing = (
        StrictOptions.ALLOW_TRAILING_COMMA in options.strict_mode
    )

    var base = p.data.start
    var idx = idx_start
    var idx_last = idx_start + n_structurals

    var stack = InlineArray[_Scope, _MAX_DEPTH](uninitialized=True)
    var depth = 0

    @parameter
    @always_inline
    def advance(out off: Int):
        off = Int(idx[0])
        idx += 1

    @parameter
    @always_inline
    def visit_string(off: Int, out arena_off: Int) raises:
        """The string opening at `off`: its closing quote is the next
        structural (escaped quotes are masked out of the index)."""
        var close = Int(idx[0])
        idx += 1
        if unlikely(base[close] != `"`):
            raise Error("Unexpected EOF")
        var scan = _iscan_string(p, off + 1, close)
        arena_off = _arena_write[options.ignore_unicode](
            sink.strings, base + off + 1, base + close, scan[0], scan[1]
        )
        sink.tape.append(_pack_word(TapeTag.STRING, UInt64(arena_off)))

    @parameter
    @always_inline
    def visit_primitive(b: Byte, off: Int) raises:
        if b == `"`:
            _ = visit_string(off)
        elif is_numerical_component(b):
            p.data.p = base + off
            var r = p._parse_number_raw()
            # RawNumber kinds are ordered to match the number tags.
            sink.tape.append(_pack_word(TapeTag.INT64 + r.kind, 0))
            sink.tape.append(r.bits)
            _check_token_end(p)
        elif b == `t`:
            p.data.p = base + off
            _ = p.parse_true()
            sink.tape.append(_pack_word(TapeTag.TRUE, 0))
            _check_token_end(p)
        elif b == `f`:
            p.data.p = base + off
            _ = p.parse_false()
            sink.tape.append(_pack_word(TapeTag.FALSE, 0))
            _check_token_end(p)
        elif b == `n`:
            p.data.p = base + off
            _ = p.parse_null()
            sink.tape.append(_pack_word(TapeTag.NULL, 0))
            _check_token_end(p)
        else:
            raise Error("Invalid json value")

    @parameter
    @always_inline
    def emit_empty(open_tag: Byte, close_tag: Byte):
        var open_idx = len(sink.tape)
        sink.tape.append(0)
        sink.tape.append(_pack_word(close_tag, UInt64(open_idx)))
        sink.tape[open_idx] = _pack_container_open(open_tag, len(sink.tape), 0)

    @parameter
    @always_inline
    def push_scope(is_object: Bool) raises:
        if unlikely(depth >= _MAX_DEPTH):
            raise Error("Exceeded maximum nesting depth")
        var dup_base: UInt32 = 0
        comptime if strict_dups:
            dup_base = UInt32(len(sink.key_hashes))
        stack.unsafe_get(depth) = _Scope(
            UInt32(len(sink.tape)), 0, dup_base, is_object
        )
        sink.tape.append(0)  # patched at scope end
        depth += 1

    @parameter
    @always_inline
    def visit_key(off: Int) raises:
        var arena_off = visit_string(off)
        comptime if strict_dups:
            _push_and_check_key(
                sink,
                Int(stack.unsafe_get(depth - 1).dup_base),
                arena_off,
            )

    # ---- root dispatch (simdjson walk_document) ----
    var off = advance()
    var b = base[off]
    var state: Int
    if b == `{`:
        if base[Int(idx[0])] == `}`:
            idx += 1
            emit_empty(TapeTag.OBJECT_OPEN, TapeTag.OBJECT_CLOSE)
            state = -1
        else:
            push_scope(True)
            state = _OBJECT_BEGIN
    elif b == `[`:
        if base[Int(idx[0])] == `]`:
            idx += 1
            emit_empty(TapeTag.ARRAY_OPEN, TapeTag.ARRAY_CLOSE)
            state = -1
        else:
            push_scope(False)
            state = _ARRAY_BEGIN
    else:
        visit_primitive(b, off)
        state = -1

    while state >= 0:
        if state == _OBJECT_BEGIN:
            # First key of a non-empty object.
            off = advance()
            if unlikely(base[off] != `"`):
                raise Error("Invalid identifier")
            visit_key(off)
            # object_field: colon then value.
            off = advance()
            if unlikely(base[off] != `:`):
                raise Error("Invalid identifier")
            stack.unsafe_get(depth - 1).count += 1
            off = advance()
            b = base[off]
            if b == `{`:
                if base[Int(idx[0])] == `}`:
                    idx += 1
                    emit_empty(TapeTag.OBJECT_OPEN, TapeTag.OBJECT_CLOSE)
                    state = _OBJECT_CONTINUE
                else:
                    push_scope(True)
                    state = _OBJECT_BEGIN
            elif b == `[`:
                if base[Int(idx[0])] == `]`:
                    idx += 1
                    emit_empty(TapeTag.ARRAY_OPEN, TapeTag.ARRAY_CLOSE)
                    state = _OBJECT_CONTINUE
                else:
                    push_scope(False)
                    state = _ARRAY_BEGIN
            else:
                visit_primitive(b, off)
                state = _OBJECT_CONTINUE
        elif state == _OBJECT_CONTINUE:
            off = advance()
            b = base[off]
            if b == `,`:
                if base[Int(idx[0])] == `}`:
                    comptime if allow_trailing:
                        idx += 1
                        state = _SCOPE_END
                        continue
                    raise Error("Illegal trailing comma")
                state = _OBJECT_BEGIN
            elif b == `}`:
                state = _SCOPE_END
            else:
                raise Error("Expected ',' or '}'")
        elif state == _ARRAY_BEGIN:
            # Next element of a non-empty array.
            stack.unsafe_get(depth - 1).count += 1
            off = advance()
            b = base[off]
            if b == `{`:
                if base[Int(idx[0])] == `}`:
                    idx += 1
                    emit_empty(TapeTag.OBJECT_OPEN, TapeTag.OBJECT_CLOSE)
                    state = _ARRAY_CONTINUE
                else:
                    push_scope(True)
                    state = _OBJECT_BEGIN
            elif b == `[`:
                if base[Int(idx[0])] == `]`:
                    idx += 1
                    emit_empty(TapeTag.ARRAY_OPEN, TapeTag.ARRAY_CLOSE)
                    state = _ARRAY_CONTINUE
                else:
                    push_scope(False)
                    state = _ARRAY_BEGIN
            else:
                visit_primitive(b, off)
                state = _ARRAY_CONTINUE
        elif state == _ARRAY_CONTINUE:
            off = advance()
            b = base[off]
            if b == `,`:
                if base[Int(idx[0])] == `]`:
                    comptime if allow_trailing:
                        idx += 1
                        state = _SCOPE_END
                        continue
                    raise Error("Illegal trailing comma")
                state = _ARRAY_BEGIN
            elif b == `]`:
                state = _SCOPE_END
            else:
                raise Error("Expected ',' or ']'")
        else:  # _SCOPE_END
            depth -= 1
            ref scope = stack.unsafe_get(depth)
            var open_idx = Int(scope.tape_idx)
            var open_tag: Byte
            var close_tag: Byte
            if scope.is_object:
                open_tag = TapeTag.OBJECT_OPEN
                close_tag = TapeTag.OBJECT_CLOSE
                comptime if strict_dups:
                    sink.key_hashes.resize(Int(scope.dup_base), 0)
                    sink.key_offs.resize(Int(scope.dup_base), 0)
            else:
                open_tag = TapeTag.ARRAY_OPEN
                close_tag = TapeTag.ARRAY_CLOSE
            sink.tape.append(_pack_word(close_tag, UInt64(open_idx)))
            sink.tape[open_idx] = _pack_container_open(
                open_tag, len(sink.tape), UInt64(scope.count)
            )
            if depth == 0:
                state = -1
            elif stack.unsafe_get(depth - 1).is_object:
                state = _OBJECT_CONTINUE
            else:
                state = _ARRAY_CONTINUE

    # document_end: every real structural must have been consumed.
    if unlikely(idx != idx_last):
        raise Error("Invalid json, expected end of input")
