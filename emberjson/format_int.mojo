from .utils import select


fn do_write_int(v: Scalar, mut writer: Some[Writer], neg: Bool):
    comptime if v.dtype.is_unsigned():
        if v >= 10:
            do_write_int(v / 10, writer, neg)
    else:
        if v >= 10 or v <= -10:
            do_write_int(v / 10, writer, neg)
    writer.write(select(neg, abs(v % -10), v % 10))


@always_inline
fn write_int(v: Scalar, mut writer: Some[Writer]):
    """A trivial int formatter than prints digits in order without additional
    intermediate copies.

    Args:
        v: The integer to format.
        writer: The output writer.
    """
    # TODO: Investigate if this is actually better than just writing to a
    # stack array and writing that to a string backwards
    constrained[v.dtype.is_integral(), "Expected integral value"]()
    if v == 0:
        writer.write(0)
    else:
        var neg: Bool

        comptime if v.dtype.is_unsigned():
            neg = False
        else:
            neg = v < 0

        if neg:
            writer.write("-")
        do_write_int(v, writer, neg)
