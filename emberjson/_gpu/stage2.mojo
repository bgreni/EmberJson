"""GPU stage 2 (Phase 4): device-side tape + arena materialization.

Consumes the stage-1 output (positions + the in-string mask plane) and
pre-builds everything expensive about stage 2 on the GPU:

  K6 tokenize    thread/token: classify each structural position into a
                 token type, validate literals and strings (control
                 chars, escape names, \\uXXXX including surrogate
                 pairing), and measure each string's unescaped arena
                 footprint. Anything the device cannot fully decide is
                 marked TOK_REDO — the host re-runs exactly that token
                 through the CPU parser for the value or the verdict.
  K7a-c layout   multi-block exclusive scan over packed
                 (tape width, arena length) pairs -> every token's tape
                 slot + arena offset, plus grand totals.
  K7d bases      thread/segment: per-line tape/arena base offsets (for
                 line-local payloads) via binary search.
  K8 materialize thread/token: parse numbers (integer Eisel-Lemire via
                 `numbers.mojo`; slow paths -> TOK_REDO), unescape
                 strings into the concatenated arena (u32 len + bytes +
                 NUL, exactly `_arena_write`'s layout), and stamp tape
                 words. Container words are placeholders — the host
                 assembler patches close indexes and counts during its
                 grammar walk (`assemble.mojo`).

The tape and arena blobs are CONCATENATED per line with line-local
payload offsets, so the host slices each line's spans with two memcpys.
Token widths: numbers 2 words, other value tokens 1, punctuation and
close-quotes 0 — matching the CPU tape layout exactly.
"""

from std.bit import count_leading_zeros
from std.math import ceildiv
from layout import row_major, stack_allocation
from std.sys import has_accelerator
from std.gpu import barrier, global_idx, thread_idx
from std.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from std.gpu.memory import AddressSpace

from emberjson._deserialize.tape import TapeTag, _pack_word
from emberjson._deserialize._parser_helper import (
    largest_power,
    smallest_power,
)
from std.sys.info import is_nvidia_gpu
from ._tensor import Vec, vec
from .numbers import device_write_float_bits
from .stage1 import (
    BLOCK,
    _SWAR_HIGH,
    _SWAR_ONES,
    _load_u64 as _load_u64_any,
    _seg_of,
    _swar_eq_mask,
)

# ---------------------------------------------------------------------
# Token model
# ---------------------------------------------------------------------

comptime TOK_OPEN_OBJ: UInt8 = 0
comptime TOK_CLOSE_OBJ: UInt8 = 1
comptime TOK_OPEN_ARR: UInt8 = 2
comptime TOK_CLOSE_ARR: UInt8 = 3
comptime TOK_COLON: UInt8 = 4
comptime TOK_COMMA: UInt8 = 5
comptime TOK_STRING: UInt8 = 6
comptime TOK_STRING_CLOSE: UInt8 = 7
comptime TOK_NUMBER: UInt8 = 8
comptime TOK_TRUE: UInt8 = 9
comptime TOK_FALSE: UInt8 = 10
comptime TOK_NULL: UInt8 = 11
comptime TOK_BAD: UInt8 = 12
comptime TOK_SENTINEL: UInt8 = 13  # host-side only: past end of line
comptime TOK_REDO: UInt8 = 0x80  # OR-flag: re-run this token on the CPU
comptime TOK_CLEAN: UInt8 = 0x40  # OR-flag: string with no escapes/controls
comptime TOK_KIND_MASK: UInt8 = 0x3F


@always_inline
def tok_tape_width(t: UInt8) -> Int:
    """Tape words a token owns (matches the CPU tape encoding)."""
    var k = t & TOK_KIND_MASK
    if k == TOK_NUMBER:
        return 2
    if k == TOK_COLON or k == TOK_COMMA or k == TOK_STRING_CLOSE:
        return 0
    if k == TOK_BAD:
        return 0
    return 1


# Token-end membership (mirror of `tape_indexed._TOKEN_END_OK`) as four
# u64 words — comptime StackArrays don't link into Metal kernels.
@always_inline
def _token_end_ok(b: UInt8) -> Bool:
    comptime W0: UInt64 = (
        (1 << 0x00)
        | (1 << 0x09)
        | (1 << 0x0A)
        | (1 << 0x0D)
        | (1 << 0x20)
        | (1 << 0x22)
        | (1 << 0x2C)
        | (1 << 0x3A)
    )
    comptime W1: UInt64 = (
        (1 << (0x5B - 64))
        | (1 << (0x5D - 64))
        | (1 << (0x7B - 64))
        | (1 << (0x7D - 64))
    )
    var w = Int(b) >> 6
    var bit = UInt64(1) << UInt64(Int(b) & 63)
    if w == 0:
        return (W0 & bit) != 0
    if w == 1:
        return (W1 & bit) != 0
    return False


# ---------------------------------------------------------------------
# Device string validation / measurement / unescape
# (mirrors `_iscan_string` + `_arena_write` + the codepoint decoder)
# ---------------------------------------------------------------------


@always_inline
def _hex4(inp: Vec[DType.uint8], off: Int) -> Tuple[UInt32, Bool]:
    """Four hex digits -> value; mirrors `hex_to_u32` (which raises).

    Single-exit shape: early returns inside loops miscompile on Metal
    (duplicated-inline instances get corrupted) — see the module note.
    """
    var v: UInt32 = 0
    var ok = True
    comptime for k in range(4):
        var b = inp[off + k]
        if b >= UInt8(ord("0")) and b <= UInt8(ord("9")):
            v = (v << 4) | UInt32(b - UInt8(ord("0")))
        elif b >= UInt8(ord("a")) and b <= UInt8(ord("f")):
            v = (v << 4) | (UInt32(b - UInt8(ord("a"))) + 10)
        elif b >= UInt8(ord("A")) and b <= UInt8(ord("F")):
            v = (v << 4) | (UInt32(b - UInt8(ord("A"))) + 10)
        else:
            ok = False
    return (v, ok)


@always_inline
def _is_acceptable_escape(c: UInt8) -> Bool:
    return (
        c == UInt8(ord('"'))
        or c == UInt8(ord("\\"))
        or c == UInt8(ord("/"))
        or c == UInt8(ord("b"))
        or c == UInt8(ord("f"))
        or c == UInt8(ord("n"))
        or c == UInt8(ord("r"))
        or c == UInt8(ord("t"))
        or c == UInt8(ord("u"))
    )


@always_inline
def _device_string_pass[
    write: Bool, ignore_unicode: Bool
](
    src: Vec[DType.uint8],
    src_off: Int,
    n: Int,
    dst: Vec[DType.uint8],
    dst_off: Int,
) -> Tuple[Int, Bool]:
    """Validate + measure (write=False) or decode (write=True) the string
    content span. Returns (unescaped length, ok).

    Mirrors `_iscan_string` (control-char rejection; escape-name checks)
    plus `_arena_write`'s decode (`ignore_unicode` keeps escapes
    verbatim). Both passes share this one implementation so the measured
    length always matches the written length.

    METAL CONSTRAINT: single-exit, flag-carrying control flow only.
    Early `return`/`continue` inside this runtime-bounded loop makes the
    Metal compiler silently corrupt one of the inlined instances
    (probed; the flat shape is the reliable one).
    """
    var i = 0
    var w = 0
    var ok = True
    while ok and i < n:
        var c = src[src_off + i]
        if c < 0x20:
            ok = False
        elif c != UInt8(ord("\\")):
            comptime if write:
                dst[dst_off + w] = c
            w += 1
            i += 1
        elif i + 1 >= n:
            ok = False
        else:
            var e = src[src_off + i + 1]
            if not _is_acceptable_escape(e):
                ok = False
            else:
                comptime if ignore_unicode:
                    # Verbatim: keep the escape bytes (names validated).
                    comptime if write:
                        dst[dst_off + w] = c
                        dst[dst_off + w + 1] = e
                    w += 2
                    i += 2
                else:
                    if e != UInt8(ord("u")):
                        var out: UInt8
                        if e == UInt8(ord("b")):
                            out = 0x08
                        elif e == UInt8(ord("f")):
                            out = 0x0C
                        elif e == UInt8(ord("n")):
                            out = 0x0A
                        elif e == UInt8(ord("r")):
                            out = 0x0D
                        elif e == UInt8(ord("t")):
                            out = 0x09
                        else:
                            out = e  # " \ /
                        comptime if write:
                            dst[dst_off + w] = out
                        w += 1
                        i += 2
                    elif i + 5 >= n:
                        ok = False
                    else:
                        # \uXXXX (possibly a surrogate pair).
                        var h = _hex4(src, src_off + i + 2)
                        var cp = h[0]
                        var have = h[1]
                        if not have:
                            ok = False
                        i += 6
                        if ok and cp >= 0xDC00 and cp < 0xE000:
                            ok = False  # lone low surrogate
                        if ok and cp >= 0xD800 and cp < 0xDC00:
                            # High surrogate: require \uXXXX low pair.
                            if i + 5 >= n + 1:
                                ok = False
                            elif not (
                                src[src_off + i] == UInt8(ord("\\"))
                                and src[src_off + i + 1] == UInt8(ord("u"))
                            ):
                                ok = False
                            else:
                                var h2 = _hex4(src, src_off + i + 2)
                                if not h2[1]:
                                    ok = False
                                elif h2[0] < 0xDC00 or h2[0] >= 0xE000:
                                    ok = False
                                else:
                                    cp = (
                                        ((cp - 0xD800) << 10) | (h2[0] - 0xDC00)
                                    ) | 0x10000
                                    i += 6
                        if ok and cp > 0x10FFFF:
                            ok = False
                        if ok:
                            if cp < 0x80:
                                comptime if write:
                                    dst[dst_off + w] = UInt8(cp)
                                w += 1
                            elif cp < 0x800:
                                comptime if write:
                                    dst[dst_off + w] = UInt8(0xC0 | (cp >> 6))
                                    dst[dst_off + w + 1] = UInt8(
                                        0x80 | (cp & 0x3F)
                                    )
                                w += 2
                            elif cp < 0x10000:
                                comptime if write:
                                    dst[dst_off + w] = UInt8(0xE0 | (cp >> 12))
                                    dst[dst_off + w + 1] = UInt8(
                                        0x80 | ((cp >> 6) & 0x3F)
                                    )
                                    dst[dst_off + w + 2] = UInt8(
                                        0x80 | (cp & 0x3F)
                                    )
                                w += 3
                            else:
                                comptime if write:
                                    dst[dst_off + w] = UInt8(0xF0 | (cp >> 18))
                                    dst[dst_off + w + 1] = UInt8(
                                        0x80 | ((cp >> 12) & 0x3F)
                                    )
                                    dst[dst_off + w + 2] = UInt8(
                                        0x80 | ((cp >> 6) & 0x3F)
                                    )
                                    dst[dst_off + w + 3] = UInt8(
                                        0x80 | (cp & 0x3F)
                                    )
                                w += 4
    return (w, ok)


# ---------------------------------------------------------------------
# Device number parsing (mirror of `Parser._parse_number_raw`)
# ---------------------------------------------------------------------


@always_inline
def _load_u64_le(inp: Vec[DType.uint8], off: Int) -> UInt64:
    """Byte-wise unaligned u64 load: Metal silently rounds misaligned
    typed loads down to their natural alignment."""
    var v: UInt64 = 0
    comptime for k in range(8):
        v |= UInt64(inp[off + k]) << UInt64(8 * k)
    return v


@always_inline
def _swar_eight_digits(inp: Vec[DType.uint8], off: Int) -> Bool:
    var val = _load_u64_le(inp, off)
    return (
        (val & 0xF0F0F0F0F0F0F0F0)
        | (((val + 0x0606060606060606) & 0xF0F0F0F0F0F0F0F0) >> 4)
    ) == 0x3333333333333333


@always_inline
def _swar_parse_eight(inp: Vec[DType.uint8], off: Int) -> UInt64:
    var val = _load_u64_le(inp, off)
    val = (val & 0x0F0F0F0F0F0F0F0F) * 2561 >> 8
    val = (val & 0x00FF00FF00FF00FF) * 6553601 >> 16
    val = (val & 0x0000FFFF0000FFFF) * 42949672960001 >> 32
    return val


@always_inline
def _isdigit(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("9"))


@always_inline
def _significant_digits(
    inp: Vec[DType.uint8], off: Int, digit_count: Int
) -> Int:
    """Mirror of `_parser_helper.significant_digits`: strip leading
    zeros (and the radix point while leading)."""
    var start = off
    var count = digit_count
    while count > 0:
        var b = inp[start]
        if b == UInt8(ord("0")) or b == UInt8(ord(".")):
            start += 1
            count -= 1
        else:
            break
    return count


@always_inline
def device_parse_number(
    inp: Vec[DType.uint8],
    pos: Int,
    five_table: Vec[DType.uint64],
) -> Tuple[UInt8, UInt64, Bool]:
    """(kind: 0 int64 / 1 uint64 / 2 float64 — RawNumber order, bits,
    ok). The input is padded, so 8-byte reads are always in-bounds
    (mirroring the CPU's `padded` mode). Any grammar error or slow path
    -> not ok (the host redo reproduces the exact value/verdict)."""
    var p = pos
    if inp[p] == UInt8(ord("+")):
        return (UInt8(0), UInt64(0), False)
    var neg = inp[p] == UInt8(ord("-"))
    p += Int(neg)

    var start_digits = p
    var i: UInt64 = 0
    while _swar_eight_digits(inp, p):
        i = i * 100_000_000 + _swar_parse_eight(inp, p)
        p += 8
    while _isdigit(inp[p]):
        i = i * 10 + UInt64(inp[p] - UInt8(ord("0")))
        p += 1

    var digit_count = p - start_digits
    if digit_count == 0 or (
        inp[start_digits] == UInt8(ord("0")) and digit_count > 1
    ):
        return (UInt8(0), UInt64(0), False)

    var exponent: Int64 = 0
    var is_float = False

    if inp[p] == UInt8(ord(".")):
        is_float = True
        p += 1
        var first_after = p
        while _swar_eight_digits(inp, p):
            i = i * 100_000_000 + _swar_parse_eight(inp, p)
            p += 8
        while _isdigit(inp[p]):
            i = i * 10 + UInt64(inp[p] - UInt8(ord("0")))
            p += 1
        exponent = Int64(first_after - p)
        if exponent == 0:
            return (UInt8(0), UInt64(0), False)
        digit_count = p - start_digits

    if inp[p] == UInt8(ord("e")) or inp[p] == UInt8(ord("E")):
        is_float = True
        p += 1
        var neg_exp = inp[p] == UInt8(ord("-"))
        p += Int(neg_exp or inp[p] == UInt8(ord("+")))
        if inp[p] == UInt8(ord("e")) or inp[p] == UInt8(ord("E")):
            return (UInt8(0), UInt64(0), False)
        var start_exp = p
        var exp_number: Int64 = 0
        while _isdigit(inp[p]):
            exp_number = exp_number * 10 + Int64(inp[p] - UInt8(ord("0")))
            p += 1
        if p == start_exp:
            return (UInt8(0), UInt64(0), False)
        if p > start_exp + 18:
            while inp[start_exp] == UInt8(ord("0")):
                start_exp += 1
            if p > start_exp + 18:
                exp_number = 999999999999999999
        exponent += -exp_number if neg_exp else exp_number

    # Token end: the byte after the number must terminate it.
    if not _token_end_ok(inp[p]):
        return (UInt8(0), UInt64(0), False)

    if is_float:
        var long_digits = (
            digit_count > 19
            and _significant_digits(inp, start_digits, digit_count) > 19
        )
        var f = device_write_float_bits(
            exponent, i, neg, long_digits, five_table
        )
        if not f[1]:
            return (UInt8(0), UInt64(0), False)
        return (UInt8(2), f[0], True)

    var longest = 19 if neg else 20
    comptime SIGNED_OVERFLOW = UInt64(Int64.MAX)
    if digit_count > longest:
        return (UInt8(0), UInt64(0), False)
    if digit_count == longest:
        if neg:
            if i > SIGNED_OVERFLOW + 1:
                return (UInt8(0), UInt64(0), False)
            return (UInt8(0), ~i + 1, True)
        elif inp[pos] != UInt8(ord("1")) or i <= SIGNED_OVERFLOW:
            return (UInt8(0), UInt64(0), False)

    if i > SIGNED_OVERFLOW:
        return (UInt8(1), i, True)
    return (UInt8(0), (~i + 1) if neg else i, True)


# ---------------------------------------------------------------------
# K6: token classification + validation + measurement
# ---------------------------------------------------------------------


def tokenize_kernel[
    ignore_unicode: Bool
](
    inp: Vec[DType.uint8],
    positions: Vec[DType.uint32],
    masks: Vec[DType.uint64],
    seg_chunk_off: Vec[DType.uint32],
    seg_starts: Vec[DType.uint32],
    types: Vec[DType.uint8],
    pairs: Vec[DType.uint64],
    num_segs: Int,
    stride: Int,
):
    """Per structural position: type + (tape width << 32 | arena len)."""
    var num_tokens = types.layout.size()
    var t = global_idx.x
    if t >= num_tokens:
        return
    var pos = Int(positions[t])
    var b = inp[pos]

    var ty: UInt8
    var alen: Int = 0

    if b == UInt8(ord("{")):
        ty = TOK_OPEN_OBJ
    elif b == UInt8(ord("}")):
        ty = TOK_CLOSE_OBJ
    elif b == UInt8(ord("[")):
        ty = TOK_OPEN_ARR
    elif b == UInt8(ord("]")):
        ty = TOK_CLOSE_ARR
    elif b == UInt8(ord(":")):
        ty = TOK_COLON
    elif b == UInt8(ord(",")):
        ty = TOK_COMMA
    elif b == UInt8(ord('"')):
        # Open vs close quote via the stage-1 in-string plane: the
        # opening quote's bit is set (inclusive prefix XOR), the closing
        # quote's is clear. Position -> chunk via the segment geometry.
        var s = _byte_seg_of(seg_starts, num_segs, pos)
        var local_chunk = (pos - Int(seg_starts[s])) // 64
        var c = Int(seg_chunk_off[s]) + local_chunk
        var bit = (pos - Int(seg_starts[s])) % 64
        var in_str = (masks[4 * stride + c] >> UInt64(bit)) & 1
        if in_str == 1:
            ty = TOK_STRING
            var close = Int(positions[t + 1])
            if inp[close] != UInt8(ord('"')):
                # Unterminated at end of line; host redo raises.
                ty = TOK_STRING | TOK_REDO
            else:
                # Fast path: most strings have no escapes and no control
                # bytes — one wide sweep decides, and K8 then
                # bulk-copies instead of running the decode loop. On
                # NVIDIA the sweep is u64 SWAR (byte-vector ops
                # scalarize in PTX); the boolean-only classic HasLess
                # trick is safe here because a false positive can only
                # sit above a true positive.
                var sp = pos + 1
                var nn = close - pos - 1
                var clean = True
                var j = 0
                comptime if is_nvidia_gpu():
                    while clean and j + 8 <= nn:
                        var x = _load_u64_any(inp, sp + j)
                        var lt20 = (x - 0x20 * _SWAR_ONES) & ~x & _SWAR_HIGH
                        if (lt20 | _swar_eq_mask(x, 0x5C)) != 0:
                            clean = False
                        else:
                            j += 8
                else:
                    while clean and j + 16 <= nn:
                        var v = inp.raw_load[width=16](sp + j)
                        var bad = v.lt(SIMD[DType.uint8, 16](0x20)) | v.eq(
                            SIMD[DType.uint8, 16](0x5C)
                        )
                        if bad.cast[DType.uint8]().reduce_max() != 0:
                            clean = False
                        else:
                            j += 16
                while clean and j < nn:
                    var c2 = inp[sp + j]
                    if c2 < 0x20 or c2 == UInt8(0x5C):
                        clean = False
                    else:
                        j += 1
                if clean:
                    ty = TOK_STRING | TOK_CLEAN
                    alen = 4 + nn + 1
                else:
                    var r = _device_string_pass[False, ignore_unicode](
                        inp, sp, nn, inp, 0
                    )
                    if r[1]:
                        alen = 4 + r[0] + 1
                    else:
                        ty = TOK_STRING | TOK_REDO
        else:
            ty = TOK_STRING_CLOSE
    elif b == UInt8(ord("t")):
        ty = TOK_TRUE
        if not (
            inp[pos + 1] == UInt8(ord("r"))
            and inp[pos + 2] == UInt8(ord("u"))
            and inp[pos + 3] == UInt8(ord("e"))
            and _token_end_ok(inp[pos + 4])
        ):
            ty = TOK_TRUE | TOK_REDO
    elif b == UInt8(ord("f")):
        ty = TOK_FALSE
        if not (
            inp[pos + 1] == UInt8(ord("a"))
            and inp[pos + 2] == UInt8(ord("l"))
            and inp[pos + 3] == UInt8(ord("s"))
            and inp[pos + 4] == UInt8(ord("e"))
            and _token_end_ok(inp[pos + 5])
        ):
            ty = TOK_FALSE | TOK_REDO
    elif b == UInt8(ord("n")):
        ty = TOK_NULL
        if not (
            inp[pos + 1] == UInt8(ord("u"))
            and inp[pos + 2] == UInt8(ord("l"))
            and inp[pos + 3] == UInt8(ord("l"))
            and _token_end_ok(inp[pos + 4])
        ):
            ty = TOK_NULL | TOK_REDO
    elif (
        _isdigit(b)
        or b == UInt8(ord("-"))
        or b == UInt8(ord("+"))
        or b == UInt8(ord("."))
    ):
        ty = TOK_NUMBER
    else:
        ty = TOK_BAD

    types[t] = ty
    pairs[t] = (UInt64(tok_tape_width(ty & TOK_KIND_MASK)) << 32) | UInt64(alen)


@always_inline
def _byte_seg_of(
    seg_starts: Vec[DType.uint32],
    num_segs: Int,
    pos: Int,
) -> Int:
    """Binary search over segment CONTENT start offsets. Positions are
    always within some segment's content."""
    var lo = 0
    var hi = num_segs
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if Int(seg_starts[mid]) <= pos:
            lo = mid
        else:
            hi = mid
    return lo


# ---------------------------------------------------------------------
# K7: layout scans (multi-block, u64 packed pair sums)
# ---------------------------------------------------------------------


def pair_scan_block_kernel(
    pairs: Vec[DType.uint64],
    excl: Vec[DType.uint64],
    block_aggs: Vec[DType.uint64],
):
    """K7a: per-block exclusive scan; writes block totals."""
    var n = pairs.layout.size()
    var tid = thread_idx.x
    var g = global_idx.x
    var v: UInt64 = 0
    if g < n:
        v = pairs[g]
    var shared = stack_allocation[
        DType.uint64, address_space=AddressSpace.SHARED
    ](row_major[BLOCK]())
    shared[tid] = v
    barrier()
    var offset = 1
    while offset < BLOCK:
        var u: UInt64 = 0
        if tid >= offset:
            u = shared[tid - offset]
        barrier()
        shared[tid] += u
        barrier()
        offset <<= 1
    if g < n:
        excl[g] = shared[tid] - v
    if tid == BLOCK - 1:
        block_aggs[g // BLOCK] = shared[tid]


def pair_scan_aggs_kernel(
    block_aggs: Vec[DType.uint64],
    block_bases: Vec[DType.uint64],
    totals: Vec[DType.uint64],
):
    """K7b: single-threadgroup scan of block totals + grand total."""
    var num_blocks = block_aggs.layout.size()
    var tid = thread_idx.x
    var shared = stack_allocation[
        DType.uint64, address_space=AddressSpace.SHARED
    ](row_major[BLOCK]())
    var carried: UInt64 = 0
    var tile = 0
    while tile < num_blocks:
        var n_tile = min(BLOCK, num_blocks - tile)
        if tid < n_tile:
            shared[tid] = block_aggs[tile + tid]
        barrier()
        var offset = 1
        while offset < BLOCK:
            var u: UInt64 = 0
            var have = tid >= offset and tid < n_tile
            if have:
                u = shared[tid - offset]
            barrier()
            if have:
                shared[tid] += u
            barrier()
            offset <<= 1
        if tid < n_tile:
            var prefix = carried
            if tid > 0:
                prefix += shared[tid - 1]
            block_bases[tile + tid] = prefix
        barrier()
        carried += shared[n_tile - 1]
        tile += BLOCK
    if tid == 0:
        totals[0] = carried


def pair_scan_apply_kernel(
    excl: Vec[DType.uint64],
    block_bases: Vec[DType.uint64],
):
    """K7c: add each block's base to its exclusive prefixes."""
    var n = excl.layout.size()
    var g = global_idx.x
    if g < n:
        excl[g] += block_bases[g // BLOCK]


def line_bases_kernel(
    positions: Vec[DType.uint32],
    excl: Vec[DType.uint64],
    totals: Vec[DType.uint64],
    seg_starts: Vec[DType.uint32],
    line_tape_base: Vec[DType.uint32],
    line_arena_base: Vec[DType.uint32],
    num_segs: Int,
):
    """K7d: per segment, the tape/arena offsets of its first token."""
    var num_tokens = excl.layout.size()
    var s = global_idx.x
    if s >= num_segs:
        return
    var seg_start = seg_starts[s]
    # First token at position >= this segment's content start.
    var lo = 0
    var hi = num_tokens
    while lo < hi:
        var mid = (lo + hi) // 2
        if positions[mid] < seg_start:
            lo = mid + 1
        else:
            hi = mid
    var v: UInt64
    if lo < num_tokens:
        v = excl[lo]
    else:
        v = totals[0]
    line_tape_base[s] = UInt32(v >> 32)
    line_arena_base[s] = UInt32(v & 0xFFFFFFFF)


# ---------------------------------------------------------------------
# K8: materialization
# ---------------------------------------------------------------------


def materialize_kernel[
    ignore_unicode: Bool
](
    inp: Vec[DType.uint8],
    positions: Vec[DType.uint32],
    types: Vec[DType.uint8],
    excl: Vec[DType.uint64],
    seg_starts: Vec[DType.uint32],
    line_arena_base: Vec[DType.uint32],
    tape_blob: Vec[DType.uint64],
    arena_blob: Vec[DType.uint8],
    five_table: Vec[DType.uint64],
    num_segs: Int,
):
    var num_tokens = types.layout.size()
    var t = global_idx.x
    if t >= num_tokens:
        return
    var ty = types[t]
    var kind = ty & TOK_KIND_MASK
    var slot = Int(excl[t] >> 32)
    var pos = Int(positions[t])

    if kind == TOK_NUMBER and (ty & TOK_REDO) == 0:
        var r = device_parse_number(inp, pos, five_table)
        if r[2]:
            tape_blob[slot] = _pack_word(TapeTag.INT64 + r[0], 0)
            tape_blob[slot + 1] = r[1]
        else:
            types[t] = ty | TOK_REDO
    elif kind == TOK_TRUE:
        tape_blob[slot] = _pack_word(TapeTag.TRUE, 0)
    elif kind == TOK_FALSE:
        tape_blob[slot] = _pack_word(TapeTag.FALSE, 0)
    elif kind == TOK_NULL:
        tape_blob[slot] = _pack_word(TapeTag.NULL, 0)
    elif kind == TOK_STRING and (ty & TOK_REDO) == 0:
        var arena_g = Int(excl[t] & 0xFFFFFFFF)
        var s = _byte_seg_of(seg_starts, num_segs, pos)
        var local_off = arena_g - Int(line_arena_base[s])
        var close = Int(positions[t + 1])
        var content = arena_g + 4
        var wlen: Int
        if (ty & TOK_CLEAN) != 0:
            var sp = pos + 1
            var nn = close - pos - 1
            var j = 0
            while j + 16 <= nn:
                arena_blob.raw_store[width=16](
                    content + j, inp.raw_load[width=16](sp + j)
                )
                j += 16
            while j < nn:
                arena_blob[content + j] = inp[sp + j]
                j += 1
            wlen = nn
        else:
            var r = _device_string_pass[True, ignore_unicode](
                inp, pos + 1, close - pos - 1, arena_blob, content
            )
            wlen = r[0]
        # Byte-wise little-endian length: the arena is a packed byte
        # stream, and Metal silently rounds MISALIGNED typed stores down
        # to their natural alignment (probed via corrupted neighbors).
        var w = arena_g
        var l = UInt32(wlen)
        arena_blob[w] = UInt8(l & 0xFF)
        arena_blob[w + 1] = UInt8((l >> 8) & 0xFF)
        arena_blob[w + 2] = UInt8((l >> 16) & 0xFF)
        arena_blob[w + 3] = UInt8((l >> 24) & 0xFF)
        arena_blob[content + wlen] = 0
        tape_blob[slot] = _pack_word(TapeTag.STRING, UInt64(local_off))
    elif kind == TOK_OPEN_OBJ:
        tape_blob[slot] = _pack_word(TapeTag.OBJECT_OPEN, 0)
    elif kind == TOK_CLOSE_OBJ:
        tape_blob[slot] = _pack_word(TapeTag.OBJECT_CLOSE, 0)
    elif kind == TOK_OPEN_ARR:
        tape_blob[slot] = _pack_word(TapeTag.ARRAY_OPEN, 0)
    elif kind == TOK_CLOSE_ARR:
        tape_blob[slot] = _pack_word(TapeTag.ARRAY_CLOSE, 0)
    # Punctuation, close quotes, BAD, and REDO'd tokens write nothing.


# ---------------------------------------------------------------------
# Buffers + orchestration
# ---------------------------------------------------------------------


struct Stage2Buffers(Movable):
    """Reusable device buffers for stage-2 materialization."""

    var types: DeviceBuffer[DType.uint8]
    var pairs: DeviceBuffer[DType.uint64]
    var excl: DeviceBuffer[DType.uint64]
    var block_aggs: DeviceBuffer[DType.uint64]
    var block_bases: DeviceBuffer[DType.uint64]
    var totals: DeviceBuffer[DType.uint64]
    var line_tape_base: DeviceBuffer[DType.uint32]
    var line_arena_base: DeviceBuffer[DType.uint32]
    var tape_blob: DeviceBuffer[DType.uint64]
    var arena_blob: DeviceBuffer[DType.uint8]
    var five_table: DeviceBuffer[DType.uint64]
    var types_host: HostBuffer[DType.uint8]
    var tape_host: HostBuffer[DType.uint64]
    var arena_host: HostBuffer[DType.uint8]
    var tape_bases_host: HostBuffer[DType.uint32]
    var arena_bases_host: HostBuffer[DType.uint32]
    var totals_host: HostBuffer[DType.uint64]
    var tok_cap: Int
    var seg_cap: Int
    var tape_cap: Int
    var arena_cap: Int

    def __init__(out self, ctx: DeviceContext, five: Span[UInt64, _]) raises:
        comptime MIN_TOK = 4096
        comptime MIN_SEG = 16
        comptime MIN_TAPE = 4096
        comptime MIN_ARENA = 16384
        self.tok_cap = MIN_TOK
        self.seg_cap = MIN_SEG
        self.tape_cap = MIN_TAPE
        self.arena_cap = MIN_ARENA
        var blocks = ceildiv(MIN_TOK, BLOCK)
        self.types = ctx.enqueue_create_buffer[DType.uint8](MIN_TOK)
        self.pairs = ctx.enqueue_create_buffer[DType.uint64](MIN_TOK)
        self.excl = ctx.enqueue_create_buffer[DType.uint64](MIN_TOK)
        self.block_aggs = ctx.enqueue_create_buffer[DType.uint64](blocks)
        self.block_bases = ctx.enqueue_create_buffer[DType.uint64](blocks)
        self.totals = ctx.enqueue_create_buffer[DType.uint64](1)
        self.line_tape_base = ctx.enqueue_create_buffer[DType.uint32](MIN_SEG)
        self.line_arena_base = ctx.enqueue_create_buffer[DType.uint32](MIN_SEG)
        self.tape_blob = ctx.enqueue_create_buffer[DType.uint64](MIN_TAPE)
        self.arena_blob = ctx.enqueue_create_buffer[DType.uint8](MIN_ARENA)
        self.five_table = ctx.enqueue_create_buffer[DType.uint64](1302)
        self.types_host = ctx.enqueue_create_host_buffer[DType.uint8](MIN_TOK)
        self.tape_host = ctx.enqueue_create_host_buffer[DType.uint64](MIN_TAPE)
        self.arena_host = ctx.enqueue_create_host_buffer[DType.uint8](MIN_ARENA)
        self.tape_bases_host = ctx.enqueue_create_host_buffer[DType.uint32](
            MIN_SEG
        )
        self.arena_bases_host = ctx.enqueue_create_host_buffer[DType.uint32](
            MIN_SEG
        )
        self.totals_host = ctx.enqueue_create_host_buffer[DType.uint64](1)
        # Upload the Eisel-Lemire powers-of-five table once (comptime
        # StackArray globals do not link into Metal kernels).
        ctx.synchronize()
        var fh = ctx.enqueue_create_host_buffer[DType.uint64](1302)
        ctx.synchronize()
        var fp = fh.unsafe_ptr()
        for i in range(1302):
            fp[i] = five[i]
        ctx.enqueue_copy(dst_buf=self.five_table, src_buf=fh)
        ctx.synchronize()

    def ensure_tokens(
        mut self, ctx: DeviceContext, num_tokens: Int, num_segs: Int
    ) raises:
        if num_tokens > self.tok_cap:
            var cap = max(num_tokens, self.tok_cap * 2)
            var blocks = ceildiv(cap, BLOCK)
            self.types = ctx.enqueue_create_buffer[DType.uint8](cap)
            self.pairs = ctx.enqueue_create_buffer[DType.uint64](cap)
            self.excl = ctx.enqueue_create_buffer[DType.uint64](cap)
            self.block_aggs = ctx.enqueue_create_buffer[DType.uint64](blocks)
            self.block_bases = ctx.enqueue_create_buffer[DType.uint64](blocks)
            self.types_host = ctx.enqueue_create_host_buffer[DType.uint8](cap)
            self.tok_cap = cap
            ctx.synchronize()
        if num_segs > self.seg_cap:
            var cap = max(num_segs, self.seg_cap * 2)
            self.line_tape_base = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.line_arena_base = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.tape_bases_host = ctx.enqueue_create_host_buffer[DType.uint32](
                cap
            )
            self.arena_bases_host = ctx.enqueue_create_host_buffer[
                DType.uint32
            ](cap)
            self.seg_cap = cap
            ctx.synchronize()

    def ensure_blobs(
        mut self, ctx: DeviceContext, tape_words: Int, arena_bytes: Int
    ) raises:
        if tape_words > self.tape_cap:
            var cap = max(tape_words, self.tape_cap * 2)
            self.tape_blob = ctx.enqueue_create_buffer[DType.uint64](cap)
            self.tape_host = ctx.enqueue_create_host_buffer[DType.uint64](cap)
            self.tape_cap = cap
            ctx.synchronize()
        if arena_bytes > self.arena_cap:
            var cap = max(arena_bytes, self.arena_cap * 2)
            self.arena_blob = ctx.enqueue_create_buffer[DType.uint8](cap)
            self.arena_host = ctx.enqueue_create_host_buffer[DType.uint8](cap)
            self.arena_cap = cap
            ctx.synchronize()
