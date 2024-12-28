from .json import JSON
from .array import Array
from .object import Object
from .value import Value, Null
from .utils import write, write_pretty
from .parser import Parser, ParseOptions


@always_inline
fn loads[options: ParseOptions = ParseOptions()](out j: JSON, s: String) raises:
    var p = Parser[options](s)
    j = p.parse()


@always_inline
fn dumps[*, pretty: Bool = False](out s: String, j: JSON):
    @parameter
    if pretty:
        s = write_pretty(j)
    else:
        s = write(j)
