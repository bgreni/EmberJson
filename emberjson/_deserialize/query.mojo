"""Partial-access JSON Pointer queries over raw input.

`parse_pointer(s, "/a/b/3")` navigates the raw JSON text to one RFC 6901
target and materializes only that subtree. Navigation runs on the stage-1
structural index: sibling values are skipped with bracket depth-hops over
structural positions, never visiting their tokens, so sparse queries into
large documents cost a fraction of a full parse (~3-5x faster on the
bench corpus; more the deeper the skipped content).

Contract (the price of the speed): the TARGET subtree is fully validated
and parsed like any other value, and every container/key actually
traversed is checked — but skipped bytes are only checked for string
boundaries; an unterminated enclosing container or trailing content is
not detected (`parse_pointer('{"a":1', "/a")` returns `1`), and duplicate
keys on the traversed path resolve to the first match.
`parse_pointer('{"bad": nope, "good": 1}', "/good")` succeeds. Use
`parse` when whole-document validation matters.

Pointer semantics mirror `resolve_pointer` (RFC 6901): `~0`/`~1`
unescaping, integer tokens address arrays and double as object keys via
their decimal spelling, string tokens against arrays raise. Keys are
compared against their DECODED bytes, so escaped keys in the document
match their unescaped pointer spelling.
"""

from .parser import Parser, ParseOptions
from ._parser_helper import ptr_dist, _next_backslash, copy_to_string
from emberjson._index import structural_index
from emberjson._pointer import PointerIndex
from emberjson._utf8 import is_valid_utf8
from emberjson.value import Value
from emberjson.utils import BytePtr
from emberjson.constants import `{`, `}`, `[`, `]`, `,`, `"`, `:`
from emberserde.error import DeserializationError, DerErrorKind
from std.memory import unsafe_memcmp
from std.sys.intrinsics import unlikely


@always_inline
def _q_byte(
    base: BytePtr, positions: List[UInt32], cur: Int
) raises DeserializationError -> Byte:
    if unlikely(cur >= len(positions)):
        raise DeserializationError("Unexpected EOF", DerErrorKind.InvalidValue)
    return base[unsafe_offset=Int(positions[cur])]


def _skip_value_positions(
    base: BytePtr, positions: List[UInt32], var cur: Int
) raises DeserializationError -> Int:
    """The position cursor one past the value starting at `cur`. Strings
    are exactly two positions (their quotes); containers are depth-hopped
    over structural positions without visiting token content."""
    var b = _q_byte(base, positions, cur)
    if b == `"`:
        return cur + 2
    if b == `{` or b == `[`:
        var depth = 1
        cur += 1
        var n = len(positions)
        while depth > 0:
            if unlikely(cur >= n):
                raise DeserializationError(
                    "Unexpected EOF", DerErrorKind.InvalidValue
                )
            var c = base[unsafe_offset=Int(positions[cur])]
            depth += (
                Int(c == `{`) + Int(c == `[`) - Int(c == `}`) - Int(c == `]`)
            )
            cur += 1
        return cur
    return cur + 1


def _key_matches(
    base: BytePtr, start_off: Int, end_off: Int, needle: String
) raises DeserializationError -> Bool:
    """Compares the key's DECODED bytes against `needle`; keys containing
    escapes (rare) are decoded before comparison."""
    var start = base.unsafe_offset(start_off)
    var end = base.unsafe_offset(end_off)
    var nb = needle.as_bytes()
    var bs = _next_backslash(start, end)
    if bs >= end:
        if ptr_dist(start, end) != len(nb):
            return False
        return unsafe_memcmp(start, nb.unsafe_ptr(), len(nb)) == 0
    var decoded = copy_to_string[False](start, end, True, ptr_dist(start, bs))
    return decoded == needle


def parse_pointer[
    options: ParseOptions = ParseOptions()
](s: StringSlice, path: PointerIndex) raises DeserializationError -> Value:
    """Materializes only the value at `path` from a raw JSON string.

    Parameters:
        options: The parsing options applied to the extracted subtree.

    Args:
        s: The input JSON string.
        path: The RFC 6901 pointer to the target. Pass a `String` or
            string literal directly -- the overload below builds the
            `PointerIndex` for you, typed-error and all -- or an
            already-built `PointerIndex`.

    Returns:
        The parsed target as an owned `Value`.

    Raises:
        `DeserializationError` if the path cannot be resolved, if
        anything traversed is malformed, or if the target subtree is
        invalid JSON. Bytes that are merely skipped over are NOT
        grammar-validated (see module docs).
    """
    return _parse_pointer_impl[options](s, path)


def parse_pointer[
    options: ParseOptions = ParseOptions()
](s: StringSlice, path: String) raises DeserializationError -> Value:
    """Overload of `parse_pointer` taking the pointer as a plain `String`
    (or string literal, which adapts to `String` directly).

    `PointerIndex`'s own constructor still raises a bare `Error` (RFC 6901
    syntax like a bad `~` escape or a missing leading `/`); building it
    HERE, inside its own narrow `try`, keeps that translated to a typed
    `DeserializationError` too -- so `parse_pointer(doc, "/a/b")` stays
    fully typed end-to-end, exactly like passing a `PointerIndex` built
    ahead of time. The resolve itself is NOT wrapped: `_parse_pointer_impl`
    is typed now and re-wrapping it would stringify a typed error into a
    second kind suffix.
    """
    var idx: PointerIndex
    try:
        idx = PointerIndex(path)
    except e:
        raise DeserializationError(String(e), DerErrorKind.InvalidValue)
    return _parse_pointer_impl[options](s, idx)


def _parse_pointer_impl[
    options: ParseOptions = ParseOptions()
](s: StringSlice, path: PointerIndex) raises DeserializationError -> Value:
    comptime if options.validate_utf8:
        if not is_valid_utf8(s):
            raise DeserializationError(
                "Invalid UTF-8 in input", DerErrorKind.InvalidValue
            )
    # An empty pointer addresses the whole document: parse it normally
    # (full validation, no index needed).
    if len(path.tokens) == 0:
        var whole = Parser[options=options](s)
        return whole.parse()

    var base = Pointer(s.unsafe_ptr())
    var positions = List[UInt32]()
    structural_index[False](base, s.byte_length(), positions)
    if unlikely(len(positions) == 0):
        raise DeserializationError(
            "Invalid json value", DerErrorKind.InvalidValue
        )

    var cur = 0
    for ti in range(len(path.tokens)):
        ref token = path.tokens[ti]
        var b = _q_byte(base, positions, cur)
        if b == `{`:
            # Integer tokens double as object keys via their decimal
            # spelling, mirroring `resolve_pointer`.
            var needle: String
            if token.isa[String]():
                needle = token[String].copy()
            else:
                needle = String(token[Int])
            cur += 1
            while True:
                var kb = _q_byte(base, positions, cur)
                if kb == `}`:
                    raise DeserializationError(
                        "Key not found: " + needle, DerErrorKind.InvalidValue
                    )
                if unlikely(kb != `"`):
                    raise DeserializationError(
                        "Invalid identifier", DerErrorKind.InvalidValue
                    )
                var k_start = Int(positions[cur]) + 1
                if unlikely(_q_byte(base, positions, cur + 1) != `"`):
                    raise DeserializationError(
                        "Unexpected EOF", DerErrorKind.InvalidValue
                    )
                var k_end = Int(positions[cur + 1])
                cur += 2
                if unlikely(_q_byte(base, positions, cur) != `:`):
                    raise DeserializationError(
                        "Invalid identifier", DerErrorKind.InvalidValue
                    )
                cur += 1
                if _key_matches(base, k_start, k_end, needle):
                    break
                cur = _skip_value_positions(base, positions, cur)
                var after = _q_byte(base, positions, cur)
                if after == `,`:
                    cur += 1
                elif after == `}`:
                    raise DeserializationError(
                        "Key not found: " + needle, DerErrorKind.InvalidValue
                    )
                else:
                    raise DeserializationError(
                        "Expected ',' or '}'", DerErrorKind.InvalidValue
                    )
        elif b == `[`:
            if not token.isa[Int]():
                raise DeserializationError(
                    "Invalid array index: " + token[String],
                    DerErrorKind.InvalidValue,
                )
            var remaining = token[Int]
            cur += 1
            if _q_byte(base, positions, cur) == `]`:
                raise DeserializationError(
                    "Index out of bounds", DerErrorKind.InvalidValue
                )
            while remaining > 0:
                cur = _skip_value_positions(base, positions, cur)
                var after = _q_byte(base, positions, cur)
                if after == `,`:
                    cur += 1
                elif after == `]`:
                    raise DeserializationError(
                        "Index out of bounds", DerErrorKind.InvalidValue
                    )
                else:
                    raise DeserializationError(
                        "Expected ',' or ']'", DerErrorKind.InvalidValue
                    )
                remaining -= 1
        else:
            if token.isa[String]():
                raise DeserializationError(
                    "Primitive value cannot be traversed with key: "
                    + token[String],
                    DerErrorKind.InvalidValue,
                )
            raise DeserializationError(
                "Primitive value cannot be traversed with index: "
                + String(token[Int]),
                DerErrorKind.InvalidValue,
            )

    # Materialize (and fully validate) just the target subtree. `cur` runs
    # one past the end when the pointer's last token was matched by the final
    # `"key":` of a truncated document, so guard it like `_q_byte` does.
    if unlikely(cur >= len(positions)):
        raise DeserializationError("Unexpected EOF", DerErrorKind.InvalidValue)
    var off = Int(positions[cur])
    var p = Parser[options=options](
        ptr=base.unsafe_offset(off), length=s.byte_length() - off
    )
    return p.parse_value()


@always_inline
def try_parse_pointer[
    options: ParseOptions = ParseOptions()
](s: StringSlice, path: String) -> Optional[Value]:
    try:
        return parse_pointer[options](s, path)
    except:
        return {}
