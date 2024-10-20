from .utils import to_byte

alias QUOTE = to_byte('"')
alias T = to_byte("t")
alias F = to_byte("f")
alias N = to_byte("n")
alias LCURLY = to_byte("{")
alias RCURLY = to_byte("}")
alias LBRACKET = to_byte("[")
alias RBRACKET = to_byte("]")
alias COLON = to_byte(":")
alias COMMA = to_byte(",")

alias NEWLINE = to_byte("\n")
alias TAB = to_byte("\t")
alias SPACE = to_byte(" ")
alias LINE_FEED = to_byte("\r")
alias RSOL = to_byte("\\")
