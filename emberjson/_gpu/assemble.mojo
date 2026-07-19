"""Host-side assembly for GPU stage 2 (Phase 4).

`assemble_line` is the CPU walker (`_walk_tape_from_index`) re-cast over
GPU-precomputed TOKEN TYPES instead of raw bytes: the same simdjson
state machine, the same error messages, the same duplicate-key and
depth handling — but strings, numbers, and literals are already
materialized in the device-built tape/arena blobs, so the walk only
validates grammar, patches container open/close payloads + counts, and
handles the rare TOK_REDO tokens by re-running exactly that token
through the CPU parser (which supplies both slow-path values and
bit-exact error verdicts).

The per-line tape span is bulk-copied into the sink and patched in
place; the arena span is bulk-copied verbatim (STRING payloads are
line-local offsets). Output is byte-identical to the CPU engine's
sink — enforced by the differential gates.
"""

from std.memory import UnsafePointer, memcpy

from emberjson._deserialize.parser import Parser, ParseOptions, StrictOptions
from emberjson._deserialize.tape import (
    TapeSink,
    _arena_str_eq,
    _arena_view,
    _key_disc,
    TapeTag,
    _pack_container_open,
    _pack_word,
    _push_and_check_key,
)
from emberjson._deserialize.tape_indexed import (
    _MAX_DEPTH,
    _check_token_end,
    _iscan_string,
)
from .stage2 import (
    TOK_BAD,
    TOK_CLOSE_ARR,
    TOK_CLOSE_OBJ,
    TOK_COLON,
    TOK_COMMA,
    TOK_FALSE,
    TOK_KIND_MASK,
    TOK_NULL,
    TOK_NUMBER,
    TOK_OPEN_ARR,
    TOK_OPEN_OBJ,
    TOK_REDO,
    TOK_SENTINEL,
    TOK_STRING,
    TOK_STRING_CLOSE,
    TOK_TRUE,
    tok_tape_width,
)

comptime PAYLOAD_MASK: UInt64 = (1 << 56) - 1


@fieldwise_init
struct _AScope(TrivialRegisterPassable):
    var tape_idx: UInt32
    var count: UInt32
    var dup_base: UInt32
    var is_object: Bool


def _redo_token[
    origin: ImmutOrigin, options: ParseOptions, //
](
    mut p: Parser[origin, options],
    tape_p: UnsafePointer[UInt64, MutAnyOrigin],
    slot: Int,
    ty: UInt8,
    at: Int,
    line_positions: UnsafePointer[UInt32, _],
    cnt: Int,
    line_end: Int,
) raises:
    """Re-runs a flagged token through the CPU parser (rare path, kept
    OUT of the walk loop so its large body — the full number parser and
    string validator — does not bloat the per-token code): slow-path
    numbers get patched in place; invalid tokens raise the exact CPU
    verdict."""
    var base = p.data.start
    var off = Int(line_positions[at])
    var kind = ty & TOK_KIND_MASK
    p.data.p = base + off
    if kind == TOK_NUMBER:
        var r = p._parse_number_raw()
        _check_token_end(p)
        tape_p[slot] = _pack_word(TapeTag.INT64 + r.kind, 0)
        tape_p[slot + 1] = r.bits
        return
    if kind == TOK_TRUE:
        _ = p.parse_true()
        _check_token_end(p)
    elif kind == TOK_FALSE:
        _ = p.parse_false()
        _check_token_end(p)
    elif kind == TOK_NULL:
        _ = p.parse_null()
        _check_token_end(p)
    elif kind == TOK_STRING:
        # The close quote is the next token when one exists; an
        # unterminated string at line end uses the line's sentinel
        # (where the delimiter/padding byte is not a quote).
        var close: Int
        if at + 1 < cnt:
            close = Int(line_positions[at + 1])
        else:
            close = line_end
        if base[close] != UInt8(ord('"')):
            raise Error("Unexpected EOF")
        _ = _iscan_string(p, off + 1, close)
    # The device flagged this token but the CPU accepts it: that is
    # an engine divergence, which the differential gates treat as a
    # hard bug — fail loudly rather than guess.
    raise Error("gpu stage-2 redo diverged from CPU verdict")


def assemble_line[
    origin: ImmutOrigin, options: ParseOptions, //
](
    mut p: Parser[origin, options],
    mut sink: TapeSink,
    types: UnsafePointer[UInt8, _],
    cnt: Int,
    line_positions: UnsafePointer[UInt32, _],
    line_end: Int,
    tape_src: UnsafePointer[UInt64, _],
    tape_words: Int,
    arena_src: UnsafePointer[UInt8, _],
    arena_bytes: Int,
) raises:
    """Validates + patches one line's prebuilt tape into `sink`.

    `p` is the whole-input padded parser (used only to reposition for
    TOK_REDO re-parses); `line_positions` are the line's absolute token
    positions. Raises with the CPU walker's verdicts."""
    comptime assert (
        options._assume_padded
    ), "the assembler requires padded input"
    comptime strict_dups = (
        StrictOptions.ALLOW_DUPLICATE_KEYS not in options.strict_mode
    )
    comptime allow_trailing = (
        StrictOptions.ALLOW_TRAILING_COMMA in options.strict_mode
    )

    # Bulk-copy the prebuilt spans. All tape access below goes through
    # the raw pointer: the length is fixed here, and the walker-grade hot
    # loop cannot afford bounds-checked List indexing per token.
    sink.tape.resize(unsafe_uninit_length=tape_words)
    var tape_p = sink.tape.unsafe_ptr()
    if tape_words > 0:
        memcpy(dest=tape_p, src=tape_src, count=tape_words)
    sink.strings.reserve_extra(arena_bytes + 8)
    if arena_bytes > 0:
        memcpy(dest=sink.strings._ptr, src=arena_src, count=arena_bytes)
    sink.strings._len = arena_bytes

    var tok = 0
    var slot = 0

    # Duplicate-key scratch as raw pointers + lengths: List operations
    # through the closure captures cost ~13x (field reloads defeat
    # hoisting), so the stacks live in a preallocated local and the hot
    # scan runs on pointers. Every key consumes >= 3 tokens, so cnt/3+1
    # bounds the key count.
    var _key_cap = cnt // 3 + 1
    var _kh_store = List[UInt64](unsafe_uninit_length=_key_cap)
    var _ko_store = List[UInt32](unsafe_uninit_length=_key_cap)
    var kh = _kh_store.unsafe_ptr()
    var ko = _ko_store.unsafe_ptr()
    var kh_len = 0

    var stack = InlineArray[_AScope, _MAX_DEPTH](uninitialized=True)
    var depth = 0

    @parameter
    @always_inline
    def advance(out ty: UInt8):
        if tok < cnt:
            ty = types[tok]
        else:
            ty = TOK_SENTINEL
        tok += 1

    @parameter
    @always_inline
    def peek(out ty: UInt8):
        if tok < cnt:
            ty = types[tok]
        else:
            ty = TOK_SENTINEL

    @parameter
    @always_inline
    def redo(ty: UInt8, at: Int) raises:
        _redo_token(p, tape_p, slot, ty, at, line_positions, cnt, line_end)

    @parameter
    @always_inline
    def visit_string(at: Int, is_key: Bool) raises:
        """Consumes the string token + its close-quote token; pushes the
        dup-key hash when `is_key`."""
        var ty = types[at]
        if (ty & TOK_REDO) != 0:
            redo(ty, at)
        var word = tape_p[slot]
        var close = advance()
        if close != TOK_STRING_CLOSE:
            # Only possible for a string left open at the end of the
            # line — the CPU walker's sentinel dispatch verdict.
            raise Error("Unexpected EOF")
        comptime if strict_dups:
            if is_key:
                var key_off = Int(word & PAYLOAD_MASK)
                var h = _key_disc(sink.strings, key_off)
                var dup_base = Int(stack.unsafe_get(depth - 1).dup_base)
                for i in range(dup_base, kh_len):
                    if kh[i] == h and _arena_str_eq(
                        sink.strings, Int(ko[i]), key_off
                    ):
                        raise Error(
                            "Duplicate key: ",
                            _arena_view(sink.strings, key_off),
                        )
                kh[kh_len] = h
                ko[kh_len] = UInt32(key_off)
                kh_len += 1
        slot += 1

    @parameter
    @always_inline
    def visit_primitive(ty: UInt8, at: Int) raises:
        var kind = ty & TOK_KIND_MASK
        if kind == TOK_STRING:
            visit_string(at, False)
            return
        if (ty & TOK_REDO) != 0:
            redo(ty, at)
            slot += tok_tape_width(kind)
            return
        if kind == TOK_NUMBER:
            slot += 2
        elif kind == TOK_TRUE or kind == TOK_FALSE or kind == TOK_NULL:
            slot += 1
        else:
            # TOK_BAD, punctuation in value position, or the sentinel:
            # same verdict as the walker's byte dispatch.
            raise Error("Invalid json value")

    @parameter
    @always_inline
    def emit_empty() raises:
        """Open + close tokens already own adjacent slots; patch both."""
        var open_slot = slot
        var open_tag = _tag_of_slot(tape_p[open_slot])
        var close_tag = open_tag + 1
        tape_p[open_slot + 1] = _pack_word(close_tag, UInt64(open_slot))
        tape_p[open_slot] = _pack_container_open(open_tag, open_slot + 2, 0)
        slot += 2

    @parameter
    @always_inline
    def push_scope(is_object: Bool) raises:
        if depth >= _MAX_DEPTH:
            raise Error("Exceeded maximum nesting depth")
        var dup_base: UInt32 = 0
        comptime if strict_dups:
            dup_base = UInt32(kh_len)
        stack.unsafe_get(depth) = _AScope(UInt32(slot), 0, dup_base, is_object)
        slot += 1
        depth += 1

    @parameter
    @always_inline
    def visit_key(at: Int) raises:
        var ty = types[at]
        if (ty & TOK_KIND_MASK) != TOK_STRING:
            raise Error("Invalid identifier")
        visit_string(at, True)

    # ---- root dispatch (mirrors _walk_tape_from_index) ----
    comptime _OBJECT_BEGIN = 0
    comptime _OBJECT_CONTINUE = 1
    comptime _ARRAY_BEGIN = 2
    comptime _ARRAY_CONTINUE = 3
    comptime _SCOPE_END = 4

    var ty = advance()
    var state: Int
    if (ty & TOK_KIND_MASK) == TOK_OPEN_OBJ:
        if peek() == TOK_CLOSE_OBJ:
            _ = advance()
            emit_empty()
            state = -1
        else:
            push_scope(True)
            state = _OBJECT_BEGIN
    elif (ty & TOK_KIND_MASK) == TOK_OPEN_ARR:
        if peek() == TOK_CLOSE_ARR:
            _ = advance()
            emit_empty()
            state = -1
        else:
            push_scope(False)
            state = _ARRAY_BEGIN
    else:
        visit_primitive(ty, tok - 1)
        state = -1

    while state >= 0:
        if state == _OBJECT_BEGIN:
            ty = advance()
            if (ty & TOK_KIND_MASK) != TOK_STRING:
                raise Error("Invalid identifier")
            visit_key(tok - 1)
            ty = advance()
            if ty != TOK_COLON:
                raise Error("Invalid identifier")
            stack.unsafe_get(depth - 1).count += 1
            ty = advance()
            var k = ty & TOK_KIND_MASK
            if k == TOK_OPEN_OBJ:
                if peek() == TOK_CLOSE_OBJ:
                    _ = advance()
                    emit_empty()
                    state = _OBJECT_CONTINUE
                else:
                    push_scope(True)
                    state = _OBJECT_BEGIN
            elif k == TOK_OPEN_ARR:
                if peek() == TOK_CLOSE_ARR:
                    _ = advance()
                    emit_empty()
                    state = _OBJECT_CONTINUE
                else:
                    push_scope(False)
                    state = _ARRAY_BEGIN
            else:
                visit_primitive(ty, tok - 1)
                state = _OBJECT_CONTINUE
        elif state == _OBJECT_CONTINUE:
            ty = advance()
            if ty == TOK_COMMA:
                if peek() == TOK_CLOSE_OBJ:
                    comptime if allow_trailing:
                        _ = advance()
                        state = _SCOPE_END
                        continue
                    raise Error("Illegal trailing comma")
                state = _OBJECT_BEGIN
            elif ty == TOK_CLOSE_OBJ:
                state = _SCOPE_END
            else:
                raise Error("Expected ',' or '}'")
        elif state == _ARRAY_BEGIN:
            stack.unsafe_get(depth - 1).count += 1
            ty = advance()
            var k = ty & TOK_KIND_MASK
            if k == TOK_OPEN_OBJ:
                if peek() == TOK_CLOSE_OBJ:
                    _ = advance()
                    emit_empty()
                    state = _ARRAY_CONTINUE
                else:
                    push_scope(True)
                    state = _OBJECT_BEGIN
            elif k == TOK_OPEN_ARR:
                if peek() == TOK_CLOSE_ARR:
                    _ = advance()
                    emit_empty()
                    state = _ARRAY_CONTINUE
                else:
                    push_scope(False)
                    state = _ARRAY_BEGIN
            else:
                visit_primitive(ty, tok - 1)
                state = _ARRAY_CONTINUE
        elif state == _ARRAY_CONTINUE:
            ty = advance()
            if ty == TOK_COMMA:
                if peek() == TOK_CLOSE_ARR:
                    comptime if allow_trailing:
                        _ = advance()
                        state = _SCOPE_END
                        continue
                    raise Error("Illegal trailing comma")
                state = _ARRAY_BEGIN
            elif ty == TOK_CLOSE_ARR:
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
                    kh_len = Int(scope.dup_base)
            else:
                open_tag = TapeTag.ARRAY_OPEN
                close_tag = TapeTag.ARRAY_CLOSE
            tape_p[slot] = _pack_word(close_tag, UInt64(open_idx))
            slot += 1
            tape_p[open_idx] = _pack_container_open(
                open_tag, slot, UInt64(scope.count)
            )
            if depth == 0:
                state = -1
            elif stack.unsafe_get(depth - 1).is_object:
                state = _OBJECT_CONTINUE
            else:
                state = _ARRAY_CONTINUE

    # document_end: every token consumed, every slot accounted for.
    if tok != cnt:
        raise Error("Invalid json, expected end of input")
    if slot != tape_words:
        raise Error("gpu stage-2: tape layout mismatch")


@always_inline
def _tag_of_slot(word: UInt64) -> Byte:
    return Byte(word >> 56)
