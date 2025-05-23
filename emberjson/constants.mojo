alias `"` = _to_byte('"')
alias `t` = _to_byte("t")
alias `f` = _to_byte("f")
alias `n` = _to_byte("n")
alias `{` = _to_byte("{")
alias `}` = _to_byte("}")
alias `[` = _to_byte("[")
alias `]` = _to_byte("]")
alias `:` = _to_byte(":")
alias `,` = _to_byte(",")

alias `\n` = _to_byte("\n")
alias `\t` = _to_byte("\t")
alias ` ` = _to_byte(" ")
alias `\r` = _to_byte("\r")
alias `\\` = _to_byte("\\")

alias `e` = _to_byte("e")
alias `E` = _to_byte("E")

alias `/` = _to_byte("/")
alias `b` = _to_byte("b")
alias `r` = _to_byte("r")
alias `u` = _to_byte("u")
# fmt: off
alias acceptable_escapes = SIMD[DType.uint8, 16](
    `"`, `\\`, `/`, `b`, `f`, `n`, `r`, `t`,
    `u`, `u`, `u`, `u`, `u`, `u`, `u`, `u`
)
# fmt: on
alias `.` = _to_byte(".")
alias `+` = _to_byte("+")
alias `-` = _to_byte("-")
alias `0` = _to_byte("0")
alias `9` = _to_byte("9")
alias `1` = _to_byte("1")


@always_inline
fn _to_byte(s: StringSlice) -> Byte:
    debug_assert(s.byte_length() > 0, "string is too small")
    return s.as_bytes()[0]
