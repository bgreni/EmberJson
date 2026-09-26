from emberjson.utils import (
    BytePtr,
    CheckedPointer,
    select,
    ByteVec,
    StackArray,
    lut,
    to_string,
)
from ._errors import (
    unexpected_eof,
    invalid_value,
    plus_sign,
    literal_eof,
    bad_literal,
    expected_type,
    invalid_hex_escape,
    bad_codepoint,
    lone_surrogate,
    invalid_codepoint,
    invalid_escape,
    control_character,
)
from std.memory import unsafe_memcpy
from emberjson.simd import SIMDBool, SIMD8_WIDTH, SIMD8xT
from std.builtin.dtype import _uint_type_of_width
from emberjson.constants import (
    `0`,
    `9`,
    ` `,
    `\n`,
    `+`,
    `-`,
    `\t`,
    `\r`,
    `\\`,
    `\b`,
    `\f`,
    `"`,
    `u`,
    `e`,
    `E`,
    `l`,
    `.`,
    `a`,
    `A`,
    `b`,
    `f`,
    `F`,
    `n`,
    `r`,
    `t`,
    `/`,
    `,`,
    `:`,
    `[`,
    `]`,
    `{`,
    `}`,
    acceptable_escapes,
)
from std.memory.unsafe import bitcast, pack_bits
from std.bit import count_trailing_zeros
from std.sys.intrinsics import unlikely, llvm_intrinsic
from emberserde.error import DeserializationError, DerErrorKind

comptime smallest_power: Int64 = -342
comptime largest_power: Int64 = 308

comptime TRUE: UInt32 = _to_uint32("true")
comptime ALSE: UInt32 = _to_uint32("alse")
comptime NULL: UInt32 = _to_uint32("null")


def _to_uint32(s: StaticString) -> UInt32:
    assert s.byte_length() > 3, "string is too small"
    return s.unsafe_ptr().unsafe_bitcast[UInt32]()[]


@always_inline
def append_digit(v: Scalar, to_add: Scalar) -> type_of(v):
    return (10 * v) + to_add.cast[v.dtype]()


def isdigit(char: Byte) -> Bool:
    return `0` <= char <= `9`


@always_inline
def is_numerical_component(char: Byte) -> Bool:
    return isdigit(char) or char == `+` or char == `-`


comptime Bits_T = Scalar[_uint_type_of_width[SIMD8_WIDTH]()]


@always_inline
def get_non_space_bits(s: SIMD8xT) -> Bits_T:
    var vec = s.eq(` `) | s.eq(`\n`) | s.eq(`\t`) | s.eq(`\r`)
    return ~pack_into_integer(vec)


@always_inline
def pack_into_integer(simd: SIMDBool) -> Bits_T:
    return Bits_T(pack_bits(simd))


@always_inline
def ptr_dist(start: BytePtr, end: BytePtr) -> Int:
    return Int(end) - Int(start)


@fieldwise_init
struct StringBlock(TrivialRegisterPassable):
    comptime BitMask = SIMD[DType.bool, SIMD8_WIDTH]

    var bs_bits: Bits_T
    var quote_bits: Bits_T
    var unescaped_bits: Bits_T

    def __init__(
        out self, bs: Self.BitMask, qb: Self.BitMask, un: Self.BitMask
    ):
        self.bs_bits = pack_into_integer(bs)
        self.quote_bits = pack_into_integer(qb)
        self.unescaped_bits = pack_into_integer(un)

    @always_inline
    def quote_index(self) -> Bits_T:
        return count_trailing_zeros(self.quote_bits)

    @always_inline
    def bs_index(self) -> Bits_T:
        return count_trailing_zeros(self.bs_bits)

    @always_inline
    def unescaped_index(self) -> Bits_T:
        return count_trailing_zeros(self.unescaped_bits)

    @always_inline
    def has_quote_first(self) -> Bool:
        return (
            count_trailing_zeros(self.quote_bits)
            < count_trailing_zeros(self.bs_bits)
            and not self.has_unescaped()
        )

    @always_inline
    def has_backslash(self) -> Bool:
        return count_trailing_zeros(self.bs_bits) < count_trailing_zeros(
            self.quote_bits
        )

    @always_inline
    def unescaped_first(self) -> Bool:
        """Whether an unescaped control character comes before any quote
        or backslash in the block: then nothing earlier can fail first. A
        backslash before it is validated first, so a string's errors are
        reported in byte order whichever path scans it."""
        var u = count_trailing_zeros(self.unescaped_bits)
        return u < count_trailing_zeros(self.quote_bits) and u < (
            count_trailing_zeros(self.bs_bits)
        )

    @always_inline
    def has_unescaped(self) -> Bool:
        return count_trailing_zeros(self.unescaped_bits) < count_trailing_zeros(
            self.quote_bits
        )

    @staticmethod
    @always_inline
    def find(src: CheckedPointer) -> StringBlock:
        var v = src.load_chunk()
        # NOTE: ASCII first printable character ` ` https://www.ascii-code.com/
        return StringBlock(v.eq(`\\`), v.eq(`"`), v.lt(` `))

    @staticmethod
    @always_inline
    def find(src: BytePtr) -> StringBlock:
        # FIXME: Port minify to use CheckedPointer
        var v = src.unsafe_load[width=SIMD8_WIDTH]()
        # NOTE: ASCII first printable character ` ` https://www.ascii-code.com/
        return StringBlock(v.eq(`\\`), v.eq(`"`), v.lt(` `))


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
def glued(prev: Byte, b: Byte) -> Bool:
    """Whether `b`, read right after `prev`, is glued to a number or literal
    that `prev` ends (`12x`, `truex`). A byte-by-byte walker sees such a
    byte where it expects a separator, an index walker as a token that does
    not end; both report `after_value`. Numbers end in a digit, literals in
    `e` or `l`; a string or container end is never glued."""
    return (isdigit(prev) or prev == `e` or prev == `l`) and not lut[
        _TOKEN_END_OK
    ](Int(b))


@no_inline
def value_error(
    p: BytePtr, remaining: Int, what: StaticString
) -> DeserializationError:
    """The error for the `remaining` bytes at `p`, where a `what` was
    expected and does not open.

    A complete value of another type is a `TypeMismatch`. Anything else is
    malformed JSON, reported as the `Value` parser reports it there: the
    end of input, a misspelled `true`/`false`/`null`, a `+`, or a byte that
    starts no value. (A string, number or container is judged by its first
    byte.)
    """
    if remaining <= 0:
        return unexpected_eof()
    var c = p[]
    if c == `"` or c == `{` or c == `[` or c == `-` or isdigit(c):
        return expected_type(what, c)
    if c == `t`:
        if remaining < 4:
            return literal_eof("true")
        var w = p.unsafe_bitcast[UInt32]()[]
        if w != TRUE:
            return bad_literal("true", String(to_string(w)))
        return expected_type(what, c)
    if c == `f`:
        if remaining < 5:
            return literal_eof("false")
        var w = p.unsafe_offset(1).unsafe_bitcast[UInt32]()[]
        if w != ALSE:
            return bad_literal("false", String("f") + String(to_string(w)))
        return expected_type(what, c)
    if c == `n`:
        if remaining < 4:
            return literal_eof("null")
        var w = p.unsafe_bitcast[UInt32]()[]
        if w != NULL:
            return bad_literal("null", String(to_string(w)))
        return expected_type(what, c)
    if c == `+`:
        return plus_sign()
    return invalid_value(c)


@no_inline
def check_string_body(p: BytePtr, n: Int) raises DeserializationError:
    """Raises the first error in the `n` string-body bytes at `p`, in the
    order `Parser.scan_string` meets them: a backslash followed by no
    escape name, or a raw control byte. (A backslash on the last byte is
    left to the caller, whose `n` ends before its escape name.)

    For walkers whose fast checks only learn that a string is bad -- an
    index that never closes it, a control byte somewhere inside -- so
    they report the error the byte walk does.
    """
    var i = 0
    while i < n:
        var c = p[unsafe_offset=i]
        if c == `\\`:
            i += 1
            if i < n and p[unsafe_offset=i] not in acceptable_escapes:
                raise invalid_escape(p[unsafe_offset=i])
        elif c < 0x20:
            raise control_character(c)
        i += 1


@no_inline
def string_error(p: BytePtr, remaining: Int) -> DeserializationError:
    """The error for the string whose body starts at `p`, `remaining`
    bytes before the end of input, when it holds a control byte or never
    closes: `check_string_body`'s first error, else the end of input."""
    try:
        check_string_body(p, remaining)
    except e:
        return e^
    return unexpected_eof()


@always_inline
def is_hex_digits(c: ByteVec[4]) -> Bool:
    return (
        (c.ge(`0`) & c.le(`9`))
        | (c.ge(`a`) & c.le(`f`))
        | (c.ge(`A`) & c.le(`F`))
    ).reduce_and()


@always_inline
def hex_to_u32(p: BytePtr) raises DeserializationError -> UInt32:
    var bytes = p.unsafe_load[width=4]()

    if unlikely(not is_hex_digits(bytes)):
        raise invalid_hex_escape()

    var v = bytes.cast[DType.uint32]()
    v = (v & 0xF) + 9 * (v >> 6)
    comptime shifts = SIMD[DType.uint32, 4](12, 8, 4, 0)
    v <<= shifts
    return v.reduce_or()


@always_inline
def decode_codepoint[
    o1: ImmOrigin, o2: ImmOrigin, //
](mut p: BytePtr[o1], end: BytePtr[o2]) raises DeserializationError -> UInt32:
    """Decodes the `XXXX` at `p` (plus the low-surrogate escape that must
    follow a high surrogate), advancing `p` past everything consumed."""
    # TODO: is this check necessary or just being paranoid?
    # because theoretically no string can be built with "\u" only
    # But if this points to bytes received over the wire, it makes sense
    # unless we use _is_valid_utf8 at the beginning of where this is called
    if unlikely(p.unsafe_offset(3) >= end):
        raise bad_codepoint()
    var c1 = hex_to_u32(p)
    p = p.unsafe_offset(4)

    if unlikely(c1 >= 0xDC00 and c1 < 0xE000):
        raise lone_surrogate()
    # NOTE: incredibly, this is part of the JSON standard (thanks javascript...)
    # ECMA-404 2nd Edition / December 2017. Section 9:
    # To escape a code point that is not in the Basic Multilingual Plane, the
    # character may be represented as a twelve-character sequence, encoding the
    # UTF-16 surrogate pair corresponding to the code point. So for example, a
    # string containing only the G clef character (U+1D11E) may be represented
    # as "\uD834\uDD1E". However, whether a processor of JSON texts interprets
    # such a surrogate pair as a single code point or as an explicit surrogate
    # pair is a semantic decision that is determined by the specific processor.
    if c1 >= 0xD800 and c1 < 0xDC00:
        # TODO: same as the above TODO
        if unlikely(p.unsafe_offset(5) >= end):
            raise bad_codepoint()
        elif unlikely(not (p[] == `\\` and p[unsafe_offset=1] == `u`)):
            raise bad_codepoint()

        p = p.unsafe_offset(2)
        var c2 = hex_to_u32(p)

        if unlikely(c2 < 0xDC00 or c2 >= 0xE000):
            raise bad_codepoint()

        c1 = (((c1 - 0xD800) << 10) | (c2 - 0xDC00)) | 0x10000
        p = p.unsafe_offset(4)

    if unlikely(c1 > 0x10FFFF):
        raise invalid_codepoint()

    return c1


def handle_unicode_codepoint(
    mut p: BytePtr, mut dest: List[UInt8], end: BytePtr
) raises DeserializationError:
    var c1 = decode_codepoint(p, end)
    if c1 < 0x80:
        dest.append(UInt8(c1))
    elif c1 < 0x800:
        dest.append(UInt8(0xC0 | (c1 >> 6)))
        dest.append(UInt8(0x80 | (c1 & 0x3F)))
    elif c1 < 0x10000:
        dest.append(UInt8(0xE0 | (c1 >> 12)))
        dest.append(UInt8(0x80 | ((c1 >> 6) & 0x3F)))
        dest.append(UInt8(0x80 | (c1 & 0x3F)))
    else:
        dest.append(UInt8(0xF0 | (c1 >> 18)))
        dest.append(UInt8(0x80 | ((c1 >> 12) & 0x3F)))
        dest.append(UInt8(0x80 | ((c1 >> 6) & 0x3F)))
        dest.append(UInt8(0x80 | (c1 & 0x3F)))


def _gen_escape_decode(out table: StackArray[Byte, 256]):
    table = StackArray[Byte, 256](fill=0)
    table.unsafe_get(Int(`"`)) = `"`
    table.unsafe_get(Int(`\\`)) = `\\`
    table.unsafe_get(Int(`/`)) = `/`
    table.unsafe_get(Int(`b`)) = `\b`
    table.unsafe_get(Int(`f`)) = `\f`
    table.unsafe_get(Int(`n`)) = `\n`
    table.unsafe_get(Int(`r`)) = `\r`
    table.unsafe_get(Int(`t`)) = `\t`


comptime _ESCAPE_DECODE: StackArray[Byte, 256] = _gen_escape_decode()


@always_inline
def decode_escape(c: Byte) raises DeserializationError -> Byte:
    """The byte a single-character escape (`\\n`, `\\"`, ...) stands for.
    `\\u` is not one of them; callers dispatch it first."""
    var decoded = lut[_ESCAPE_DECODE](Int(c))
    if unlikely(decoded == 0):
        raise invalid_escape(c)
    return decoded


@always_inline
def _next_backslash[
    o1: ImmOrigin, o2: ImmOrigin, //
](var p: BytePtr[o1], end: BytePtr[o2]) -> BytePtr[o1]:
    """Returns a pointer to the next backslash in [p, end), or `end`.

    Reads SIMD chunks only while they fit inside the range, so it is safe
    for unpadded buffers.
    """
    while ptr_dist(p, end) >= SIMD8_WIDTH:
        var bs = pack_into_integer(p.unsafe_load[width=SIMD8_WIDTH]().eq(`\\`))
        if bs != 0:
            return p.unsafe_offset(Int(count_trailing_zeros(bs)))
        p = p.unsafe_offset(SIMD8_WIDTH)
    while p < end and p[] != `\\`:
        p = p.unsafe_offset(1)
    return p


@always_inline
def copy_to_string[
    ignore_unicode: Bool = False
](
    start: BytePtr,
    end: BytePtr,
    found_escaped: Bool = True,
    first_escape: Int = 0,
) raises DeserializationError -> String:
    """Materializes the string bytes in [start, end) into a `String`.

    `first_escape` is the offset of the first backslash when the caller
    already located it (see `Parser.find`); the escaped-decode path then
    bulk-copies that clean prefix instead of re-scanning it byte by byte.
    Zero (the default) preserves the scan-from-start behaviour.
    """
    var length = ptr_dist(start, end)

    @__parameter
    def decode_escaped() raises DeserializationError -> String:
        # This will usually slightly overallocate if the string contains
        # escaped unicode
        var dest = List[UInt8](capacity=length)
        var p = start.unsafe_offset(first_escape)

        if first_escape > 0:
            dest.resize(first_escape, 0)
            unsafe_memcpy(dest=dest.unsafe_ptr(), src=start, count=first_escape)

        while p < end:
            # Fast scan for next backslash
            var chunk_start = p
            p = _next_backslash(p, end)

            # Bulk copy non-escaped chunk
            if p > chunk_start:
                var chunk_len = ptr_dist(chunk_start, p)
                var old_size = len(dest)
                dest.resize(old_size + chunk_len, 0)
                unsafe_memcpy(
                    dest=dest.unsafe_ptr().unsafe_offset(old_size),
                    src=chunk_start,
                    count=chunk_len,
                )

            # If we hit backslash, handle escape
            if p < end:
                p = p.unsafe_offset(1)  # skip backslash
                if p < end:
                    var c = p[]
                    p = p.unsafe_offset(1)
                    if c == `u`:
                        handle_unicode_codepoint(p, dest, end)
                    else:
                        dest.append(decode_escape(c))
        return String(unsafe_from_utf8=dest^)

    comptime if not ignore_unicode:
        if found_escaped:
            return decode_escaped()
        else:
            return String(
                StringSlice(
                    unsafe_from_utf8=Span(unsafe_ptr=start, length=length)
                )
            )
    else:
        return String(
            StringSlice(unsafe_from_utf8=Span(unsafe_ptr=start, length=length))
        )


def check_escapes[
    o1: ImmOrigin, o2: ImmOrigin, //
](var p: BytePtr[o1], end: BytePtr[o2]) raises DeserializationError:
    """Raises what decoding the escapes in the scanned string content
    `[p, end)` raises in `copy_to_string` (`p` at or before the first
    backslash), without decoding: validators accept exactly the strings
    the parsers read. `scan_string` has already checked the escape names,
    so only `\\u` escapes are left to fail."""
    while True:
        p = _next_backslash(p, end)
        if p >= end:
            return
        p = p.unsafe_offset(1)
        if p >= end:
            return
        var c = p[]
        p = p.unsafe_offset(1)
        if c == `u`:
            _ = decode_codepoint(p, end)


@always_inline
def is_exp_char(char: Byte) -> Bool:
    return char == `e` or char == `E`


@always_inline
def unsafe_is_made_of_eight_digits_fast(src: BytePtr) -> Bool:
    """Don't ask me how this works.

    Safety:
        This is only safe if there are at least 8 bytes remaining.
    """
    var val = src.unsafe_bitcast[UInt64]()[]
    return (
        (val & 0xF0F0F0F0F0F0F0F0)
        | (((val + 0x0606060606060606) & 0xF0F0F0F0F0F0F0F0) >> 4)
    ) == 0x3333333333333333


@always_inline
def to_double(
    var mantissa: UInt64, real_exponent: UInt64, negative: Bool
) -> Float64:
    comptime `1 << 52` = 1 << 52
    mantissa &= ~(`1 << 52`)
    mantissa |= real_exponent << 52
    mantissa |= UInt64(negative) << 63
    return bitcast[DType.float64](mantissa)


@always_inline
def unsafe_parse_eight_digits(out val: UInt64, p: BytePtr):
    """Don't ask me how this works.

    Safety:
        This is only safe if there are at least 8 bytes remaining.
    """
    val = p.unsafe_bitcast[UInt64]()[]
    val = (val & 0x0F0F0F0F0F0F0F0F) * 2561 >> 8
    val = (val & 0x00FF00FF00FF00FF) * 6553601 >> 16
    val = (val & 0x0000FFFF0000FFFF) * 42949672960001 >> 32


# --- x86 SSE digit runs ---------------------------------------------------

comptime _U8x16 = SIMD[DType.uint8, 16]


def _make_digit_align() -> StackArray[_U8x16, 17]:
    """Entry n is a PSHUFB control moving lanes 0..n-1 to lanes 16-n..15
    and zeroing the rest (control bit 7 set)."""
    var t = StackArray[_U8x16, 17](fill=_U8x16(0))
    for n in range(17):
        var m = _U8x16(0x80)
        for lane in range(16 - n, 16):
            m[lane] = UInt8(lane - (16 - n))
        t[n] = m
    return t^


comptime _DIGIT_ALIGN = _make_digit_align()

comptime POW10_U64: StackArray[UInt64, 17] = [
    1,
    10,
    100,
    1_000,
    10_000,
    100_000,
    1_000_000,
    10_000_000,
    100_000_000,
    1_000_000_000,
    10_000_000_000,
    100_000_000_000,
    1_000_000_000_000,
    10_000_000_000_000,
    100_000_000_000_000,
    1_000_000_000_000_000,
    10_000_000_000_000_000,
]


@always_inline
def unsafe_parse_digit_run16(p: BytePtr) -> Tuple[UInt64, Int]:
    """The value and length of the run of ASCII digits at `p`, up to 16.

    x86 only (SSSE3 + SSE4.1; callers gate on AVX2). One 16-byte load and
    compare find the run length, PSHUFB right-aligns the run (the zeroed
    lanes before it read as leading zeros), and simdjson's
    PMADDUBSW/PMADDWD/PACKUSDW/PMADDWD chain combines it. Every constant
    is a vector, so unlike the SWAR helpers this holds no 64-bit
    immediates in general-purpose registers.

    Safety:
        Reads 16 bytes at `p`.
    """
    var d = p.unsafe_load[width=16]() - _U8x16(0x30)
    var mask = UInt32(pack_bits(d.le(_U8x16(9))))
    var n = Int(count_trailing_zeros(~mask))
    var aligned = llvm_intrinsic["llvm.x86.ssse3.pshuf.b.128", _U8x16](
        d, lut[_DIGIT_ALIGN](n)
    )
    var pairs = llvm_intrinsic[
        "llvm.x86.ssse3.pmadd.ub.sw.128", SIMD[DType.int16, 8]
    ](
        aligned,
        SIMD[DType.int8, 16](
            10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1
        ),
    )
    var quads = llvm_intrinsic["llvm.x86.sse2.pmadd.wd", SIMD[DType.int32, 4]](
        pairs, SIMD[DType.int16, 8](100, 1, 100, 1, 100, 1, 100, 1)
    )
    var packed = llvm_intrinsic[
        "llvm.x86.sse41.packusdw", SIMD[DType.int16, 8]
    ](quads, quads)
    var octs = llvm_intrinsic["llvm.x86.sse2.pmadd.wd", SIMD[DType.int32, 4]](
        packed, SIMD[DType.int16, 8](10000, 1, 10000, 1, 10000, 1, 10000, 1)
    )
    return (
        UInt64(octs[0]) * 100_000_000 + UInt64(octs[1]),
        n,
    )


@always_inline
def unsafe_is_made_of_four_digits_fast(src: BytePtr) -> Bool:
    """`unsafe_is_made_of_eight_digits_fast` for four bytes.

    Safety:
        This is only safe if there are at least 4 bytes remaining.
    """
    var val = src.unsafe_bitcast[UInt32]()[]
    return (
        (val & 0xF0F0F0F0) | (((val + 0x06060606) & 0xF0F0F0F0) >> 4)
    ) == 0x33333333


@always_inline
def unsafe_parse_four_digits(src: BytePtr) -> UInt64:
    """Safety:
    This is only safe if there are at least 4 bytes remaining.
    """
    var val = UInt64(src.unsafe_bitcast[UInt32]()[])
    val = (val & 0x0F0F0F0F) * 2561 >> 8
    val = (val & 0x00FF00FF) * 6553601 >> 16
    return val & 0xFFFF


@always_inline
def parse_digit[
    assume_padded: Bool = False
](out dig: Bool, p: CheckedPointer, mut i: Scalar):
    comptime if not assume_padded:
        if p.dist() <= 0:
            return False
    # In padded mode the EOF check is skipped: reads at/past end return the
    # NUL padding, which is not a digit, so the loop terminates the same way.
    dig = isdigit(p.unsafe_get())
    i = select(dig, i * 10 + (p.unsafe_get() - `0`).cast[i.dtype](), i)


@always_inline
def at_or_nul[assume_padded: Bool = False](p: CheckedPointer) -> Byte:
    """The byte at `p`, or NUL when at/past end-of-input.

    In padded mode this is a bare read (the padding provides the NULs);
    otherwise an explicit bounds check substitutes the NUL. Callers compare
    the result against token characters, so EOF falls into the same "not
    the byte I wanted" branch either way.
    """
    comptime if assume_padded:
        return p.unsafe_get()
    else:
        return 0 if p.dist() <= 0 else p.unsafe_get()


@always_inline
def significant_digits(p: BytePtr, digit_count: Int) -> Int:
    """`digit_count` (the digits from `p`, not counting a `.` among them)
    less the leading zeros, which do not limit precision. Reads only
    within those digits."""
    var q = p
    var n = digit_count
    while n > 0 and (q[] == `0` or q[] == `.`):
        n -= Int(q[] == `0`)
        q = q.unsafe_offset(1)
    return n
