"""Every error EmberJson's parsers raise, in one place.

The `Value` and `Document` parsers, the validator behind skips and `Lazy`,
the reflection deserializer and JSON Pointer each detect errors in their own
walk and raise them through these constructors, so the same malformed input
gets the same message and `DerErrorKind` whichever reads it
(`test/emberjson/test_error_parity.mojo` checks that).

All are `@no_inline`: they sit on failure branches, and formatting a message
inline would bloat the hot loops they are called from.
"""

from emberserde.error import DeserializationError, DerErrorKind


def _invalid(var message: String) -> DeserializationError:
    return DeserializationError(message^, DerErrorKind.InvalidValue)


def _mismatch(var message: String) -> DeserializationError:
    return DeserializationError(message^, DerErrorKind.TypeMismatch)


def shown(b: Byte) -> String:
    """`b` for a message: in quotes when printable ASCII, else as hex."""
    if b >= 0x20 and b < 0x7F:
        return String("'") + chr(Int(b)) + "'"
    comptime DIGITS = "0123456789ABCDEF"
    return (
        String("0x")
        + String(DIGITS[byte=Int(b >> 4)])
        + String(DIGITS[byte=Int(b & 0xF)])
    )


# --- structure ----------------------------------------------------------------


@no_inline
def unexpected_eof() -> DeserializationError:
    return _invalid("Unexpected EOF")


@no_inline
def invalid_value(found: Byte) -> DeserializationError:
    """A byte that cannot start a JSON value, where one is expected."""
    return _invalid(String("Invalid JSON value: ") + shown(found))


@no_inline
def after_value(found: Byte) -> DeserializationError:
    """A byte glued to the end of a number or literal (`12x`, `truex`)."""
    return _invalid(String("Unexpected ") + shown(found) + " after a value")


@no_inline
def expected_separator(close: Byte, found: Byte) -> DeserializationError:
    """Neither `,` nor the container's `close` after one of its values."""
    return _invalid(
        String("Expected ',' or ")
        + shown(close)
        + ", received: "
        + shown(found)
    )


@no_inline
def expected_token(expected: Byte, found: Byte) -> DeserializationError:
    return _invalid(
        String("Expected ") + shown(expected) + ", received: " + shown(found)
    )


@no_inline
def trailing_comma() -> DeserializationError:
    return _invalid("Illegal trailing comma")


@no_inline
def expected_key(found: Byte) -> DeserializationError:
    return _invalid(
        String("Expected an object key string, received: ") + shown(found)
    )


@no_inline
def expected_colon(found: Byte) -> DeserializationError:
    return _invalid(
        String("Expected ':' after an object key, received: ") + shown(found)
    )


@no_inline
def expected_enum_tag(found: Byte) -> DeserializationError:
    """An object that closes (`found`) before a tagged enum's tag: a
    well-formed object, but no enum."""
    return _mismatch(
        String("Expected an enum tag string, received: ") + shown(found)
    )


@no_inline
def trailing_content(rest: Pointer[Byte, _], n: Int) -> DeserializationError:
    """Anything but whitespace after the root value: the `n` bytes at
    `rest` run from its first byte to the end of the input."""
    return _invalid(
        String("Expected end of input, received trailing content: ")
        + String(from_utf8_lossy=Span(unsafe_ptr=rest, length=n))
    )


@no_inline
def too_deep() -> DeserializationError:
    return _invalid("Exceeded maximum nesting depth")


@no_inline
def duplicate_key(key: StringSlice) -> DeserializationError:
    return DeserializationError(
        String("Duplicate key: ") + key, DerErrorKind.DuplicateField
    )


@no_inline
def invalid_utf8() -> DeserializationError:
    return _invalid("Invalid UTF-8 in input")


# --- literals -------------------------------------------------------------------


@no_inline
def literal_eof(word: StaticString) -> DeserializationError:
    """Input ends inside `true`, `false` or `null`."""
    return _invalid(String('Encountered EOF when expecting "') + word + '"')


@no_inline
def bad_literal(word: StaticString, found: String) -> DeserializationError:
    """`found` spells neither `word` nor its prefix."""
    return _invalid(
        String("Expected '") + word + "', received: '" + found + "'"
    )


# --- strings --------------------------------------------------------------------


@no_inline
def control_character(found: Byte) -> DeserializationError:
    return _invalid(
        String("Control characters must be escaped: ") + shown(found)
    )


@no_inline
def invalid_escape(found: Byte) -> DeserializationError:
    """A backslash followed by `found`, which names no escape."""
    return _invalid(
        String("Invalid escape sequence: backslash followed by ") + shown(found)
    )


@no_inline
def invalid_hex_escape() -> DeserializationError:
    return _invalid("Invalid hex digit encountered")


@no_inline
def bad_codepoint() -> DeserializationError:
    return _invalid("Bad unicode codepoint")


@no_inline
def lone_surrogate() -> DeserializationError:
    return _invalid("Invalid unicode: lone surrogate")


@no_inline
def invalid_codepoint() -> DeserializationError:
    return _invalid("Invalid unicode")


@no_inline
def malformed_string() -> DeserializationError:
    """A string the index and the scanner delimit differently; not
    expected in practice."""
    return _invalid("Invalid string")


# --- numbers --------------------------------------------------------------------


@no_inline
def invalid_number() -> DeserializationError:
    return _invalid("Invalid number")


@no_inline
def double_exponent_sign() -> DeserializationError:
    return _invalid("Invalid float: Double sign for exponent")


@no_inline
def plus_sign() -> DeserializationError:
    return _invalid('Expected digit or "-", found "+"')


@no_inline
def infinite_float() -> DeserializationError:
    """A number whose magnitude rounds to infinity as a Float64."""
    return _invalid("Infinite float")


@no_inline
def float_overflow() -> DeserializationError:
    """A finite Float64 that overflows a narrower float target."""
    return _invalid("float overflow")


@no_inline
def found_float() -> DeserializationError:
    return _mismatch("Expected integer, found float")


@no_inline
def found_negative() -> DeserializationError:
    return _mismatch("Expected unsigned integer, found negative")


@no_inline
def int_overflow() -> DeserializationError:
    return _mismatch("integer overflow")


# --- shape mismatches (reflection) ----------------------------------------------


@no_inline
def expected_type(what: StaticString, found: Byte) -> DeserializationError:
    """A complete value of another type where `what` was expected:
    well-formed JSON the target cannot hold."""
    return _mismatch(String("Expected ") + what + ", received: " + shown(found))


@no_inline
def expected_length(n: Int) -> DeserializationError:
    """A well-formed array with more or fewer than the `n` elements a
    tuple reads."""
    return _mismatch(String("Expected an array of ", n, " elements"))


@no_inline
def expected_single_key() -> DeserializationError:
    """A well-formed object with more than the one key a tagged enum is."""
    return _mismatch("Expected an object with a single key (an enum tag)")


@no_inline
def expected_value(what: StaticString) -> DeserializationError:
    """A parsed `Value` that is not `what`, for a target that holds one."""
    return _mismatch(String("Expected ") + what)


# --- JSON Pointer ---------------------------------------------------------------


@no_inline
def key_not_found(key: StringSlice) -> DeserializationError:
    return _invalid(String("Key not found: ") + key)


@no_inline
def index_out_of_bounds() -> DeserializationError:
    return _invalid("Index out of bounds")


@no_inline
def invalid_array_index(token: StringSlice) -> DeserializationError:
    return _invalid(String("Invalid array index: ") + token)


@no_inline
def cannot_traverse(token: StringSlice, by_key: Bool) -> DeserializationError:
    return _invalid(
        String("Primitive value cannot be traversed with ")
        + ("key: " if by_key else "index: ")
        + token
    )
