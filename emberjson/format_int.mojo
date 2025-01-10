from .utils import branchless_ternary


fn do_write_int[W: Writer](v: Int64, mut writer: W, neg: Bool):
    if v >= 10 or v <= -10:
        do_write_int(v / 10, writer, neg)
    writer.write(branchless_ternary(abs(v % -10), v % 10, neg))


@always_inline
fn write_int[W: Writer](v: Int64, mut writer: W):
    """A trivial int formatter than prints digits in order without additional
    intermediate copies.

    Parameters:
        W: The type of the output writer.

    Args:
        v: The integer to format.
        writer: The output writer.
    """
    if v == 0:
        writer.write(0)
    else:
        var neg = v < 0
        if neg:
            writer.write("-")
        do_write_int(v, writer, neg)
