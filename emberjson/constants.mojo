comptime `"` = _to_byte('"')
comptime `t` = _to_byte("t")
comptime `f` = _to_byte("f")
comptime `n` = _to_byte("n")
comptime `b` = _to_byte("b")
comptime `r` = _to_byte("r")
comptime `u` = _to_byte("u")
comptime `{` = _to_byte("{")
comptime `}` = _to_byte("}")
comptime `[` = _to_byte("[")
comptime `]` = _to_byte("]")
comptime `:` = _to_byte(":")
comptime `,` = _to_byte(",")

comptime `\n` = _to_byte("\n")
comptime `\t` = _to_byte("\t")
comptime ` ` = _to_byte(" ")
comptime `\r` = _to_byte("\r")
comptime `\\` = _to_byte("\\")
comptime `\b` = _to_byte("\b")
comptime `\f` = _to_byte("\f")

comptime `e` = _to_byte("e")
comptime `E` = _to_byte("E")

comptime `/` = _to_byte("/")

# fmt: off
comptime acceptable_escapes = SIMD[DType.uint8, 16](
    `"`, `\\`, `/`, `b`, `f`, `n`, `r`, `t`,
    `u`, `u`, `u`, `u`, `u`, `u`, `u`, `u`
)
# fmt: on
comptime `.` = _to_byte(".")
comptime `+` = _to_byte("+")
comptime `-` = _to_byte("-")
comptime `0` = _to_byte("0")
comptime `9` = _to_byte("9")
comptime `1` = _to_byte("1")


@always_inline
fn _to_byte(s: StringSlice) -> Byte:
    debug_assert(s.byte_length() > 0, "string is too small")
    return s.as_bytes()[0]
