from .utils import branchless_ternary


fn do_write_int[W: Writer](v: Scalar, mut writer: W, neg: Bool):
    @parameter
    if v.element_type.is_unsigned():
        if v >= 10:
            do_write_int(v / 10, writer, neg)
    else:
        if v >= 10 or v <= -10:
            do_write_int(v / 10, writer, neg)
    writer.write(branchless_ternary(abs(v % -10), v % 10, neg))


@always_inline
fn write_int[W: Writer](v: Scalar, mut writer: W):
    """A trivial int formatter than prints digits in order without additional
    intermediate copies.

    Parameters:
        W: The type of the output writer.

    Args:
        v: The integer to format.
        writer: The output writer.
    """
    # TODO: Investigate if this is actually better than just writing to a
    # stack array and writing that to a string backwards
    constrained[v.element_type.is_integral(), "Expected integral value"]()
    if v == 0:
        writer.write(0)
    else:
        var neg: Bool

        @parameter
        if v.element_type.is_unsigned():
            neg = False
        else:
            neg = v < 0

        if neg:
            writer.write("-")
        do_write_int(v, writer, neg)
