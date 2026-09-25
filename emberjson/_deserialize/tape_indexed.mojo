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
    rendered as a state loop with an explicit scope stack sized by
    `options.max_depth` (default 1024, like simdjson's DEFAULT_MAX_DEPTH)
    — so nesting costs no call frames and the hot loop stays
    branch-predictable.
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
    _arena_write,
    _push_and_check_key,
)
from ._parser_helper import (
    Bits_T,
    is_numerical_component,
    pack_into_integer,
)
from emberjson._index import structural_index
from emberjson.utils import to_string, lut, StackArray
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
from std.collections import Array
from std.bit import count_trailing_zeros
from std.sys.intrinsics import unlikely, likely
from emberserde.error import DeserializationError, DerErrorKind


def _gen_token_end_table(out t: StackArray[Bool, 256]):
    t = StackArray[Bool, 256](fill=False)
    # NUL is deliberately NOT in this table. It terminates a token only
    # when it is `PaddedBuffer`'s padding rather than a byte of the
    # input, which the table alone cannot tell apart; `_check_token_end`
    # settles that case against the logical end-of-input.
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
    origin: ImmOrigin, options: ParseOptions, //
](p: Parser[origin, options]) raises DeserializationError:
    """After a number/literal, the next byte must terminate the token."""
    var b = p.data.unsafe_get()
    if likely(lut[_TOKEN_END_OK](Int(b))):
        return
    # A NUL read at or past the logical end of input is `PaddedBuffer`'s
    # padding, which ends the token. A NUL *inside* the input is a real
    # byte and must be rejected, exactly as the byte-walk builder does —
    # otherwise `123<NUL>4` parses as `123` and the two engines disagree
    # on the same bytes.
    if b == 0 and p.data.dist() <= 0:
        return
    raise DeserializationError(
        String("Invalid json value: ") + String(to_string(b)),
        DerErrorKind.InvalidValue,
    )


def _validate_escape_names[
    origin: ImmOrigin, options: ParseOptions, //
](
    p: Parser[origin, options], off: Int, end_off: Int
) raises DeserializationError:
    """Escape-name validation for the `ignore_unicode` verbatim path (the
    decode path validates names itself)."""
    var q = p.data.start.unsafe_offset(off)
    var end = p.data.start.unsafe_offset(end_off)
    while q < end:
        if q[] == `\\`:
            if q.unsafe_offset(1) >= end:
                break
            if unlikely((q.unsafe_offset(1))[] not in acceptable_escapes):
                raise DeserializationError(
                    String("Invalid escape sequence: ")
                    + String(to_string((q.unsafe_offset(1))[])),
                    DerErrorKind.InvalidValue,
                )
            q = q.unsafe_offset(2)
            continue
        q = q.unsafe_offset(1)


def _iscan_string[
    origin: ImmOrigin, options: ParseOptions, //
](
    p: Parser[origin, options], start_off: Int, end_off: Int
) raises DeserializationError -> Tuple[Bool, Int]:
    """Validates the string content span and locates its first escape.

    Returns (found_escaped, first_escape offset within the span). Raises
    on unescaped control characters, mirroring the byte-walk scanner.
    """
    var base = p.data.start.unsafe_offset(start_off)
    var n = end_off - start_off
    var i = 0
    var found = False
    var first = 0
    while i < n:
        # Padded input: a full-width load past the span is safe.
        var chunk = (base.unsafe_offset(i)).unsafe_load[width=SIMD8_WIDTH]()
        var ctrl = pack_into_integer(chunk.lt(` `))
        var bs = pack_into_integer(chunk.eq(`\\`))
        var valid = n - i
        if valid < SIMD8_WIDTH:
            var lanemask = (Bits_T(1) << Bits_T(valid)) - 1
            ctrl &= lanemask
            bs &= lanemask
        if unlikely(ctrl != 0):
            raise DeserializationError(
                String("Control characters must be escaped: ")
                + String(String(count_trailing_zeros(ctrl))),
                DerErrorKind.InvalidValue,
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


# Walk states (simdjson's goto labels).
comptime _OBJECT_BEGIN: Int = 0
comptime _OBJECT_CONTINUE: Int = 1
comptime _ARRAY_BEGIN: Int = 2
comptime _ARRAY_CONTINUE: Int = 3
comptime _SCOPE_END: Int = 4


def parse_document_tape_indexed[
    origin: ImmOrigin, options: ParseOptions, //
](
    mut p: Parser[origin, options], mut sink: TapeSink
) raises DeserializationError:
    """Stage-1 + stage-2 parse of the parser's whole input.

    Same tape/arena output and verdicts as `parse_document_tape`.
    Requires `PaddedBuffer`-backed input.
    """
    var positions = List[UInt32]()
    structural_index[True](p.data.start, p.size, positions)
    var n_structurals = len(positions)
    if unlikely(n_structurals == 0):
        raise DeserializationError(
            "Invalid json value", DerErrorKind.InvalidValue
        )
    # Sentinels (simdjson stage-1 convention): entries past the real
    # structurals point at end-of-input, where the padding NUL fails
    # every dispatch — this is what lets `advance` skip bounds checks.
    for _ in range(3):
        positions.append(UInt32(p.size))
    _walk_tape_from_index(p, sink, positions.unsafe_ptr(), n_structurals)


def _walk_tape_from_index[
    origin: ImmOrigin, options: ParseOptions, //
](
    mut p: Parser[origin, options],
    mut sink: TapeSink,
    idx_start: Pointer[UInt32, _],
    n_structurals: Int,
) raises DeserializationError:
    """Stage-2 walk over a precomputed structural index.

    Pointer contract: entries `[0, n_structurals)` are strictly ascending
    byte offsets `< p.size` (as produced by `structural_index[True]` or
    a batch producer); entries `[n_structurals, n_structurals + 3)` equal
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
    var idx_last = idx_start.unsafe_offset(n_structurals)

    # ponytail: reserved up front at 16 B/level, so a huge `max_depth` costs
    # stack even on shallow input; spill to the heap past some bound if
    # limits far above the default ever matter.
    var stack = Array[_Scope, options.max_depth](uninitialized=True)
    var depth = 0

    @__parameter
    @always_inline
    def advance(out off: Int):
        off = Int(idx[])
        idx = idx.unsafe_offset(1)

    @__parameter
    @always_inline
    def visit_string(off: Int, out arena_off: Int) raises DeserializationError:
        """The string opening at `off`: its closing quote is the next
        structural (escaped quotes are masked out of the index)."""
        var close = Int(idx[])
        idx = idx.unsafe_offset(1)
        if unlikely(base[unsafe_offset=close] != `"`):
            raise DeserializationError(
                "Unexpected EOF", DerErrorKind.InvalidValue
            )
        var scan = _iscan_string(p, off + 1, close)
        arena_off = _arena_write[options.ignore_unicode](
            sink.strings,
            base.unsafe_offset(off).unsafe_offset(1),
            base.unsafe_offset(close),
            scan[0],
            scan[1],
        )
        sink.tape.append(_pack_word(TapeTag.STRING, UInt64(arena_off)))

    @__parameter
    @always_inline
    def visit_primitive(b: Byte, off: Int) raises DeserializationError:
        if b == `"`:
            _ = visit_string(off)
        elif is_numerical_component(b):
            p.data.p = base.unsafe_offset(off)
            var r = p._parse_number_raw()
            # RawNumber kinds are ordered to match the number tags.
            sink.tape.append(_pack_word(TapeTag.INT64 + r.kind, 0))
            sink.tape.append(r.bits)
            _check_token_end(p)
        elif b == `t`:
            p.data.p = base.unsafe_offset(off)
            _ = p.parse_true()
            sink.tape.append(_pack_word(TapeTag.TRUE, 0))
            _check_token_end(p)
        elif b == `f`:
            p.data.p = base.unsafe_offset(off)
            _ = p.parse_false()
            sink.tape.append(_pack_word(TapeTag.FALSE, 0))
            _check_token_end(p)
        elif b == `n`:
            p.data.p = base.unsafe_offset(off)
            _ = p.parse_null()
            sink.tape.append(_pack_word(TapeTag.NULL, 0))
            _check_token_end(p)
        else:
            raise DeserializationError(
                "Invalid json value", DerErrorKind.InvalidValue
            )

    @__parameter
    @always_inline
    def emit_empty(open_tag: Byte, close_tag: Byte) raises DeserializationError:
        # An empty container never pushes a `_Scope` (there is nothing to
        # recurse into), but it is still one level deeper than its parent,
        # so it must be checked against the same limit as `push_scope` —
        # otherwise a chain of nested containers ending in an empty `[]`/`{}`
        # could dodge the depth guard entirely.
        # `>=` here (against a not-yet-incremented `depth`) pairs with the
        # recursive parser's increment-then-`>` check in `parser.mojo`
        # (`enter_container`), so both strategies admit exactly
        # `options.max_depth` levels.
        if unlikely(depth >= options.max_depth):
            raise DeserializationError(
                "Exceeded maximum nesting depth", DerErrorKind.InvalidValue
            )
        var open_idx = len(sink.tape)
        sink.tape.append(0)
        sink.tape.append(_pack_word(close_tag, UInt64(open_idx)))
        sink.tape[open_idx] = _pack_container_open(open_tag, len(sink.tape), 0)

    @__parameter
    @always_inline
    def push_scope(is_object: Bool) raises DeserializationError:
        if unlikely(depth >= options.max_depth):
            raise DeserializationError(
                "Exceeded maximum nesting depth", DerErrorKind.InvalidValue
            )
        var dup_base: UInt32 = 0
        comptime if strict_dups:
            dup_base = UInt32(len(sink.key_hashes))
        stack.unsafe_get(depth) = _Scope(
            UInt32(len(sink.tape)), 0, dup_base, is_object
        )
        sink.tape.append(0)  # patched at scope end
        depth += 1

    @__parameter
    @always_inline
    def visit_key(off: Int) raises DeserializationError:
        var arena_off = visit_string(off)
        comptime if strict_dups:
            _push_and_check_key(
                sink,
                Int(stack.unsafe_get(depth - 1).dup_base),
                arena_off,
            )

    # ---- root dispatch (simdjson walk_document) ----
    var off = advance()
    var b = base[unsafe_offset=off]
    var state: Int
    if b == `{`:
        if base[unsafe_offset=Int(idx[])] == `}`:
            idx = idx.unsafe_offset(1)
            emit_empty(TapeTag.OBJECT_OPEN, TapeTag.OBJECT_CLOSE)
            state = -1
        else:
            push_scope(True)
            state = _OBJECT_BEGIN
    elif b == `[`:
        if base[unsafe_offset=Int(idx[])] == `]`:
            idx = idx.unsafe_offset(1)
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
            if unlikely(base[unsafe_offset=off] != `"`):
                raise DeserializationError(
                    "Invalid identifier", DerErrorKind.InvalidValue
                )
            visit_key(off)
            # object_field: colon then value.
            off = advance()
            if unlikely(base[unsafe_offset=off] != `:`):
                raise DeserializationError(
                    "Invalid identifier", DerErrorKind.InvalidValue
                )
            stack.unsafe_get(depth - 1).count += 1
            off = advance()
            b = base[unsafe_offset=off]
            if b == `{`:
                if base[unsafe_offset=Int(idx[])] == `}`:
                    idx = idx.unsafe_offset(1)
                    emit_empty(TapeTag.OBJECT_OPEN, TapeTag.OBJECT_CLOSE)
                    state = _OBJECT_CONTINUE
                else:
                    push_scope(True)
                    state = _OBJECT_BEGIN
            elif b == `[`:
                if base[unsafe_offset=Int(idx[])] == `]`:
                    idx = idx.unsafe_offset(1)
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
            b = base[unsafe_offset=off]
            if b == `,`:
                if base[unsafe_offset=Int(idx[])] == `}`:
                    comptime if allow_trailing:
                        idx = idx.unsafe_offset(1)
                        state = _SCOPE_END
                        continue
                    raise DeserializationError(
                        "Illegal trailing comma", DerErrorKind.InvalidValue
                    )
                state = _OBJECT_BEGIN
            elif b == `}`:
                state = _SCOPE_END
            else:
                raise DeserializationError(
                    "Expected ',' or '}'", DerErrorKind.InvalidValue
                )
        elif state == _ARRAY_BEGIN:
            # Next element of a non-empty array.
            stack.unsafe_get(depth - 1).count += 1
            off = advance()
            b = base[unsafe_offset=off]
            if b == `{`:
                if base[unsafe_offset=Int(idx[])] == `}`:
                    idx = idx.unsafe_offset(1)
                    emit_empty(TapeTag.OBJECT_OPEN, TapeTag.OBJECT_CLOSE)
                    state = _ARRAY_CONTINUE
                else:
                    push_scope(True)
                    state = _OBJECT_BEGIN
            elif b == `[`:
                if base[unsafe_offset=Int(idx[])] == `]`:
                    idx = idx.unsafe_offset(1)
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
            b = base[unsafe_offset=off]
            if b == `,`:
                if base[unsafe_offset=Int(idx[])] == `]`:
                    comptime if allow_trailing:
                        idx = idx.unsafe_offset(1)
                        state = _SCOPE_END
                        continue
                    raise DeserializationError(
                        "Illegal trailing comma", DerErrorKind.InvalidValue
                    )
                state = _ARRAY_BEGIN
            elif b == `]`:
                state = _SCOPE_END
            else:
                raise DeserializationError(
                    "Expected ',' or ']'", DerErrorKind.InvalidValue
                )
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
        raise DeserializationError(
            "Invalid json, expected end of input", DerErrorKind.InvalidValue
        )
