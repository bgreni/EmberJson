from .utils import to_byte

alias `"` = to_byte('"')
alias `t` = to_byte("t")
alias `f` = to_byte("f")
alias `n` = to_byte("n")
alias `{` = to_byte("{")
alias `}` = to_byte("}")
alias `[` = to_byte("[")
alias `]` = to_byte("]")
alias `:` = to_byte(":")
alias `,` = to_byte(",")

alias `\n` = to_byte("\n")
alias `\t` = to_byte("\t")
alias ` ` = to_byte(" ")
alias `\r` = to_byte("\r")
alias `\\` = to_byte("\\")

alias `e` = to_byte("e")
alias `E` = to_byte("E")
