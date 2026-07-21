"""Segmented GPU stage 1: structural indexing (fused pipeline).

Produces positions bit-identical to running the CPU
`structural_index[True]` on each segment independently (a batch of JSONL
lines is N segments; a single document is one segment), in five
launches — the 0.8 ms cost of a ~20-launch pipeline measured in Phase 0
forced fusion up front:

  K1 classify   thread/chunk: load 64B once -> class masks (shared
                nibble tables), carry transfer element, fused UTF-8
                validation, block-level inclusive compose scan ->
                per-chunk exclusive prefix element + per-block aggregate.
  K2 carries    one threadgroup: scan block aggregates -> per-block
                carry-in state (`scan.scan_aggregates_kernel`).
  K3 combine    thread/chunk (pointwise): resolve carries, shared
                structural algebra (`_index/portable.mojo`), popcount,
                block-level sum scan -> local offsets + block counts.
  K4 offsets    one threadgroup: scan block counts -> block bases +
                grand total (`scan.scan_counts_kernel`).
  K5 scatter    thread/chunk: ctz loop writes ascending ABSOLUTE byte
                positions; the last chunk's thread writes three
                whole-input sentinels (batch callers build per-segment
                sentinels host-side instead).

Segmentation model: chunking is per-segment (`seg_chunk_off` is the
exclusive scan of per-segment chunk counts; a chunk never spans two
segments), so each segment's carries evolve exactly as if parsed alone.
Segment-head chunks emit CONSTANT transfer elements
(`scan.constant_element`) which absorb all prior state under plain
composition — no segmented-scan flag machinery exists or is needed. An
unclosed string or trailing backslash in one corrupt line therefore
cannot leak state into the next line, which is what keeps skip-malformed
batch semantics identical to parsing each line in isolation.

All mask *extraction* here avoids `pack_bits`/`_dynamic_shuffle` (both
crash the Metal shader compiler): movemasks are comptime-unrolled bit
ORs, table lookups are per-lane extracts. The carry mathematics is
imported from `_index/portable.mojo` and `scan.mojo` — the same
formulations the CPU engine executes.

Fused UTF-8 sets one GLOBAL error flag (clean flag == the whole input is
valid UTF-8). Per-segment verdicts are not tracked on device: sequences
cannot span the ASCII `\\n` delimiter, so batch callers that see the
flag set fall back to cheap per-line CPU validation to decide which
lines to skip.
"""

from std.bit import count_trailing_zeros, pop_count
from std.math import ceildiv
from layout import row_major, stack_allocation
from std.memory import bitcast, memcpy, pack_bits
from std.sys import has_accelerator
from std.sys.info import is_nvidia_gpu
from std.atomic import Atomic
from std.gpu import barrier, global_idx, thread_idx
from std.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from std.gpu.memory import AddressSpace

from emberjson._index.portable import (
    CLASSIFY_HIGH_NIBBLE,
    CLASSIFY_LOW_NIBBLE,
    CLASS_OP_BITS,
    CLASS_WS_BITS,
    escape_next,
    prefix_xor_portable,
    structurals_from_masks,
)
from emberjson._utf8 import _BYTE_1_HIGH, _BYTE_1_LOW, _BYTE_2_HIGH, _MAX_VALUE
from .scan import (
    IDENTITY_ELEM,
    apply_state,
    chunk_transfer_element,
    compose,
    constant_element,
    scan_aggregates_kernel,
    scan_counts_kernel,
)
from ._tables import tbl16
from ._tensor import Vec, vec

comptime _C16 = SIMD[DType.uint8, 16]
comptime _B16 = SIMD[DType.bool, 16]
comptime BLOCK = 256


@always_inline
def _movemask16(v: _B16) -> UInt64:
    """Bool16 -> 16-bit mask; native `pack_bits` on NVIDIA (probed
    SUPPORTED on sm_86), Metal-safe unrolled extraction elsewhere
    (`pack_bits` crashes the Metal shader compiler)."""
    comptime if is_nvidia_gpu():
        return UInt64(pack_bits(v))
    else:
        var m: UInt64 = 0
        comptime for i in range(16):
            if v[i]:
                m |= UInt64(1) << UInt64(i)
        return m


@always_inline
def _movemask64(a: _B16, b: _B16, c: _B16, d: _B16) -> UInt64:
    comptime if is_nvidia_gpu():
        return pack_bits(a.join(b).join(c.join(d)))
    else:
        return (
            _movemask16(a)
            | _movemask16(b) << 16
            | _movemask16(c) << 32
            | _movemask16(d) << 48
        )


@always_inline
def _satsub(a: _C16, b: _C16) -> _C16:
    return max(a, b) - b


# --- NVIDIA SWAR classification -------------------------------------
# PTX has no 16-lane byte vectors: every `_C16` op scalarizes to ~16
# instructions, which made K1 run ~50x above its memory floor (measured
# 25 ms @ 420 MB vs 0.5 ms for the u64-scalar K3). The u64 SWAR forms
# below classify 8 bytes per ALU op chain instead. Metal keeps the
# byte-SIMD forms (native 16-byte vectors there); cuJSON's kernels use
# the same word-parallel trick for the same reason.

comptime _SWAR_ONES: UInt64 = 0x0101010101010101
comptime _SWAR_HIGH: UInt64 = 0x8080808080808080
comptime _SWAR_PACK: UInt64 = 0x0102040810204080


@always_inline
def _swar_eq_mask(x: UInt64, c: UInt8) -> UInt64:
    """0x80 in every byte of `x` that equals `c`, 0 elsewhere.

    Exact per-byte form (`~(t | ((t | HIGH) - ONES)) & HIGH`): the
    subtraction cannot borrow across bytes because every byte of
    `t | HIGH` is >= 0x80, unlike the classic zero-byte trick, which
    false-positives on a 0x01 byte sitting above a true match."""
    var t = x ^ (UInt64(c) * _SWAR_ONES)
    return ~(t | ((t | _SWAR_HIGH) - _SWAR_ONES)) & _SWAR_HIGH


@always_inline
def _swar_pack8(m: UInt64) -> UInt64:
    """Per-byte 0x80 flags -> 8-bit mask (byte j -> bit j)."""
    return ((m >> 7) * _SWAR_PACK) >> 56


@always_inline
def _load_u64(inp: Vec[DType.uint8], offset: Int) -> UInt64:
    """Little-endian u64 at any byte address.

    A width-8 load at an unknown alignment lowers to an 8-iteration
    per-byte loop on NVIDIA (the compiler cannot prove 8-byte alignment,
    and a typed misaligned load faults on CUDA / address-rounds on
    Metal) — ~24 PTX ops instead of one `ld.global.b64`. Instead, load
    the two 8-aligned words straddling `offset` and funnel-shift.

    Single-segment inputs have 64-aligned chunk bases, so `offset` is
    8-aligned, `mis == 0`, and the second load is skipped. Only
    misaligned (JSONL) segments pay for both loads.

    Safety: the high word reads up to `offset + 15`. The caller's largest
    `offset` is `base + 56`, and `base + 64` can round up to `n + 63`, so
    the high load can touch `n + 70`. The staging window guarantees
    >= `n + 128` zero-padded bytes (`ceildiv(n, 64) + 2` chunks), which
    covers it.
    """
    var mis = offset & 7
    var abase = offset - mis
    var lo = bitcast[DType.uint64, 1](inp.raw_load[width=8, alignment=8](abase))
    if mis == 0:
        return lo
    var hi = bitcast[DType.uint64, 1](
        inp.raw_load[width=8, alignment=8](abase + 8)
    )
    var sh = UInt64(mis * 8)
    return (lo >> sh) | (hi << (64 - sh))


@always_inline
def _prev_shift[n: Int](prev_chunk: _C16, cur: _C16) -> _C16:
    return prev_chunk.join(cur).slice[16, offset=16 - n]()


@always_inline
def _utf8_check_block(cur: _C16, prev_chunk: _C16, mut error: _C16):
    var prev1 = _prev_shift[1](prev_chunk, cur)
    var sc = (
        tbl16(_BYTE_1_HIGH, prev1 >> 4)
        & tbl16(_BYTE_1_LOW, prev1 & 0xF)
        & tbl16(_BYTE_2_HIGH, cur >> 4)
    )
    var prev2 = _prev_shift[2](prev_chunk, cur)
    var prev3 = _prev_shift[3](prev_chunk, cur)
    var must23 = _satsub(prev2, _C16(0xE0 - 0x80)) | _satsub(
        prev3, _C16(0xF0 - 0x80)
    )
    error |= (must23 & 0x80) ^ sc


@always_inline
def _seg_of(
    seg_chunk_off: Vec[DType.uint32],
    num_segs: Int,
    c: Int,
) -> Int:
    """Binary search: the segment whose chunk range contains chunk `c`.
    Segment s owns chunks [seg_chunk_off[s], seg_chunk_off[s+1])."""
    var lo = 0
    var hi = num_segs
    while hi - lo > 1:
        var mid = (lo + hi) // 2
        if Int(seg_chunk_off[mid]) <= c:
            lo = mid
        else:
            hi = mid
    return lo


@always_inline
def _chunk_geometry(
    seg_chunk_off: Vec[DType.uint32],
    seg_starts: Vec[DType.uint32],
    seg_lens: Vec[DType.uint32],
    num_segs: Int,
    c: Int,
) -> Tuple[Int, Int, Int]:
    """Chunk `c` -> (absolute byte base, remaining segment bytes at this
    chunk, local chunk index). `rem > 64` means an interior chunk."""
    var s = _seg_of(seg_chunk_off, num_segs, c)
    var local = c - Int(seg_chunk_off[s])
    var base = Int(seg_starts[s]) + local * 64
    var rem = Int(seg_lens[s]) - local * 64
    return (base, rem, local)


@always_inline
def _valid_mask(rem: Int) -> UInt64:
    if rem >= 64:
        return UInt64.MAX
    return (UInt64(1) << UInt64(rem)) - 1


def classify_kernel[
    validate_utf8: Bool
](
    inp: Vec[DType.uint8],
    masks: Vec[DType.uint64],
    prefixes: Vec[DType.uint16],
    aggs: Vec[DType.uint16],
    err_flag: Vec[DType.int32],
    seg_chunk_off: Vec[DType.uint32],
    seg_starts: Vec[DType.uint32],
    seg_lens: Vec[DType.uint32],
    num_segs: Int,
    num_chunks: Int,
    stride: Int,
):
    """K1. `masks` is 5 planes of `stride` u64s: backslash, quote, op,
    ws, and (written by K3) the resolved in-string mask.

    Every thread participates in the block scan barriers; padding lanes
    hold the identity element and never write outputs.
    """
    var tid = thread_idx.x
    var c = global_idx.x
    var is_real = c < num_chunks

    var elem: UInt16 = IDENTITY_ELEM
    if is_real:
        var geo = _chunk_geometry(
            seg_chunk_off, seg_starts, seg_lens, num_segs, c
        )
        var byte_base = geo[0]
        var rem = geo[1]
        var local = geo[2]
        var base = Int(byte_base)
        var backslash: UInt64
        var quote: UInt64
        var op: UInt64
        var ws: UInt64
        comptime if is_nvidia_gpu():
            # u64 SWAR classification (see the helpers' rationale).
            backslash = 0
            quote = 0
            op = 0
            ws = 0
            comptime for w in range(8):
                var x = _load_u64(inp, base + w * 8)
                backslash |= _swar_pack8(_swar_eq_mask(x, 0x5C)) << UInt64(
                    8 * w
                )
                quote |= _swar_pack8(_swar_eq_mask(x, 0x22)) << UInt64(8 * w)
                var m_op = (
                    _swar_eq_mask(x, UInt8(ord("{")))
                    | _swar_eq_mask(x, UInt8(ord("}")))
                    | _swar_eq_mask(x, UInt8(ord("[")))
                    | _swar_eq_mask(x, UInt8(ord("]")))
                    | _swar_eq_mask(x, UInt8(ord(":")))
                    | _swar_eq_mask(x, UInt8(ord(",")))
                )
                op |= _swar_pack8(m_op) << UInt64(8 * w)
                var m_ws = (
                    _swar_eq_mask(x, 0x20)
                    | _swar_eq_mask(x, 0x09)
                    | _swar_eq_mask(x, 0x0A)
                    | _swar_eq_mask(x, 0x0D)
                )
                ws |= _swar_pack8(m_ws) << UInt64(8 * w)
        else:
            var r0 = inp.raw_load[width=16](base)
            var r1 = inp.raw_load[width=16](base + 16)
            var r2 = inp.raw_load[width=16](base + 32)
            var r3 = inp.raw_load[width=16](base + 48)

            backslash = _movemask64(
                r0.eq(_C16(0x5C)),
                r1.eq(_C16(0x5C)),
                r2.eq(_C16(0x5C)),
                r3.eq(_C16(0x5C)),
            )
            quote = _movemask64(
                r0.eq(_C16(0x22)),
                r1.eq(_C16(0x22)),
                r2.eq(_C16(0x22)),
                r3.eq(_C16(0x22)),
            )
            # Class descriptors via the shared nibble tables.
            var d0 = tbl16(CLASSIFY_LOW_NIBBLE, r0 & 0xF) & tbl16(
                CLASSIFY_HIGH_NIBBLE, r0 >> 4
            )
            var d1 = tbl16(CLASSIFY_LOW_NIBBLE, r1 & 0xF) & tbl16(
                CLASSIFY_HIGH_NIBBLE, r1 >> 4
            )
            var d2 = tbl16(CLASSIFY_LOW_NIBBLE, r2 & 0xF) & tbl16(
                CLASSIFY_HIGH_NIBBLE, r2 >> 4
            )
            var d3 = tbl16(CLASSIFY_LOW_NIBBLE, r3 & 0xF) & tbl16(
                CLASSIFY_HIGH_NIBBLE, r3 >> 4
            )
            op = _movemask64(
                (d0 & CLASS_OP_BITS).ne(_C16(0)),
                (d1 & CLASS_OP_BITS).ne(_C16(0)),
                (d2 & CLASS_OP_BITS).ne(_C16(0)),
                (d3 & CLASS_OP_BITS).ne(_C16(0)),
            )
            ws = _movemask64(
                (d0 & CLASS_WS_BITS).ne(_C16(0)),
                (d1 & CLASS_WS_BITS).ne(_C16(0)),
                (d2 & CLASS_WS_BITS).ne(_C16(0)),
                (d3 & CLASS_WS_BITS).ne(_C16(0)),
            )

        # Clip every class mask to the segment's content: bits past the
        # content belong to the delimiter / the next line / the padding
        # and must not classify. (Single-segment parity: the CPU loads
        # NUL padding there, which is class-less anyway.)
        var valid = _valid_mask(rem)
        backslash &= valid
        quote &= valid
        op &= valid
        ws &= valid

        masks[c] = backslash
        masks[stride + c] = quote
        masks[2 * stride + c] = op
        masks[3 * stride + c] = ws

        elem = chunk_transfer_element(backslash, quote, op, ws, valid)
        if local == 0:
            # Segment head: the carry-in is the reset state by
            # definition, so the transfer function is constant — and
            # constants absorb everything composed before them, which
            # is the whole segmentation mechanism.
            elem = constant_element(apply_state(0, elem))

        comptime if validate_utf8:
            var prev: _C16
            if local == 0:
                # Sequences cannot span the segment delimiter (ASCII),
                # so the reset matches the CPU's initial state.
                prev = _C16(0)
            else:
                prev = inp.raw_load[width=16](base - 16)
            var error = _C16(0)
            # Loaded here (not shared with classification): the NVIDIA
            # classify path reads u64 words instead of these vectors,
            # and on Metal the compiler folds these reloads into the
            # identical loads above.
            var blocks: InlineArray[_C16, 4] = [
                inp.raw_load[width=16](base),
                inp.raw_load[width=16](base + 16),
                inp.raw_load[width=16](base + 32),
                inp.raw_load[width=16](base + 48),
            ]
            comptime for r in range(4):
                var cur = blocks[r]
                if (cur & 0x80).reduce_max() == 0:
                    error |= _satsub(prev, _MAX_VALUE)
                else:
                    _utf8_check_block(cur, prev, error)
                prev = cur
            if rem == 64:
                # Content fills this chunk exactly and the byte AFTER it
                # belongs to no chunk window: check for a dangling lead
                # at the segment end here. (When rem < 64 the in-window
                # bytes after the content — the '\n' delimiter, the next
                # line, or the zero padding — fail the continuation
                # checks naturally.)
                error |= _satsub(prev, _MAX_VALUE)
            if error.reduce_max() != 0:
                _ = Atomic.fetch_add(err_flag.ptr, 1)

    # Block-level inclusive compose scan (all threads hit the barriers).
    var shared = stack_allocation[
        DType.uint16, address_space=AddressSpace.SHARED
    ](row_major[BLOCK]())
    shared[tid] = elem
    barrier()
    var offset = 1
    while offset < BLOCK:
        var v: UInt16 = IDENTITY_ELEM
        if tid >= offset:
            v = shared[tid - offset]
        barrier()
        shared[tid] = compose(v, shared[tid])
        barrier()
        offset <<= 1

    if is_real:
        # Exclusive local prefix for this chunk.
        var prefix: UInt16 = IDENTITY_ELEM
        if tid > 0:
            prefix = shared[tid - 1]
        prefixes[c] = prefix
        # The last real chunk of the block owns the aggregate (padding
        # lanes' identity elements would clobber the sc bits).
        if tid == BLOCK - 1 or c == num_chunks - 1:
            aggs[c // BLOCK] = shared[tid]


def combine_kernel(
    masks: Vec[DType.uint64],
    prefixes: Vec[DType.uint16],
    block_states: Vec[DType.uint8],
    structurals_out: Vec[DType.uint64],
    local_offsets: Vec[DType.uint32],
    count_aggs: Vec[DType.uint32],
    seg_chunk_off: Vec[DType.uint32],
    seg_starts: Vec[DType.uint32],
    seg_lens: Vec[DType.uint32],
    num_segs: Int,
    num_chunks: Int,
    stride: Int,
):
    """K3. Resolve each chunk's carries, combine to structural bits,
    block-scan the popcounts."""
    var tid = thread_idx.x
    var c = global_idx.x
    var is_real = c < num_chunks

    var count: UInt32 = 0
    if is_real:
        var geo = _chunk_geometry(
            seg_chunk_off, seg_starts, seg_lens, num_segs, c
        )
        var rem = geo[1]
        var local = geo[2]

        # The identity element zeroes the sc bit (it is output-only), so
        # the first chunk of a block — whose exclusive local prefix IS
        # the identity — must take the block carry state directly; a
        # segment head is simply the reset state.
        var state: UInt8
        if local == 0:
            state = 0
        elif tid == 0:
            state = block_states[c // BLOCK]
        else:
            state = apply_state(block_states[c // BLOCK], prefixes[c])
        var e_in = UInt64(state & 1)
        var p_in = UInt64((state >> 1) & 1)
        var sc_in = UInt64((state >> 2) & 1)

        var backslash = masks[c]
        var quote = masks[stride + c]
        var op = masks[2 * stride + c]
        var ws = masks[3 * stride + c]

        var escaped = escape_next(backslash, e_in)[0]
        var real_quotes = quote & ~escaped
        var in_string = prefix_xor_portable(real_quotes) ^ (0 - p_in)

        var structurals = structurals_from_masks(
            op, ws, real_quotes, in_string, sc_in, _valid_mask(rem)
        )[0]
        structurals_out[c] = structurals
        # Fifth mask plane: the resolved in-string mask, which stage 2's
        # token classifier uses to tell open quotes (bit set) from close
        # quotes (bit clear).
        masks[4 * stride + c] = in_string
        count = UInt32(pop_count(structurals))

    # Block-level exclusive sum scan of counts.
    var shared = stack_allocation[
        DType.uint32, address_space=AddressSpace.SHARED
    ](row_major[BLOCK]())
    shared[tid] = count
    barrier()
    var offset = 1
    while offset < BLOCK:
        var v: UInt32 = 0
        if tid >= offset:
            v = shared[tid - offset]
        barrier()
        shared[tid] += v
        barrier()
        offset <<= 1

    if is_real:
        local_offsets[c] = shared[tid] - count
        if tid == BLOCK - 1 or c == num_chunks - 1:
            count_aggs[c // BLOCK] = shared[tid]


def scatter_kernel(
    structurals: Vec[DType.uint64],
    local_offsets: Vec[DType.uint32],
    count_bases: Vec[DType.uint32],
    total: Vec[DType.uint32],
    positions: Vec[DType.uint32],
    seg_chunk_off: Vec[DType.uint32],
    seg_starts: Vec[DType.uint32],
    seg_lens: Vec[DType.uint32],
    num_segs: Int,
    num_chunks: Int,
    input_len: Int,
):
    """K5. Ascending ctz scatter (absolute byte offsets) + three
    whole-input sentinels for the single-segment caller."""
    var c = global_idx.x
    if c >= num_chunks:
        return
    var geo = _chunk_geometry(seg_chunk_off, seg_starts, seg_lens, num_segs, c)
    var byte_base = UInt32(geo[0])
    var w = Int(count_bases[c // BLOCK] + local_offsets[c])
    var bits = structurals[c]
    while bits != 0:
        positions[w] = byte_base + UInt32(count_trailing_zeros(bits))
        bits &= bits - 1
        w += 1
    if c == num_chunks - 1:
        var t = Int(total[0])
        comptime for k in range(3):
            positions[t + k] = UInt32(input_len)


def run_stage1_pipeline[
    validate_utf8: Bool
](
    ctx: DeviceContext,
    inp: Vec[DType.uint8],
    err_flag: Vec[DType.int32],
    mut bufs: Stage1Buffers,
    num_segs: Int,
    num_chunks: Int,
    input_len: Int,
) raises:
    """Enqueues K1..K5 (no synchronize; the caller syncs and reads
    `bufs.total` / `bufs.positions`). Segment descriptors must already
    be uploaded via `bufs.upload_segments`."""
    comptime if has_accelerator():
        var grid = ceildiv(num_chunks, BLOCK)
        var num_blocks = grid
        comptime k1 = classify_kernel[validate_utf8]
        ctx.enqueue_function[k1](
            inp,
            vec(bufs.masks, 5 * bufs.chunk_cap),
            vec(bufs.prefixes, num_chunks),
            vec(bufs.aggs, num_blocks),
            err_flag,
            vec(bufs.seg_chunk_off, num_segs + 1),
            vec(bufs.seg_starts, num_segs),
            vec(bufs.seg_lens, num_segs),
            num_segs,
            num_chunks,
            bufs.chunk_cap,
            grid_dim=grid,
            block_dim=BLOCK,
        )
        ctx.enqueue_function[scan_aggregates_kernel](
            vec(bufs.aggs, num_blocks),
            vec(bufs.block_states, num_blocks),
            grid_dim=1,
            block_dim=BLOCK,
        )
        ctx.enqueue_function[combine_kernel](
            vec(bufs.masks, 5 * bufs.chunk_cap),
            vec(bufs.prefixes, num_chunks),
            vec(bufs.block_states, num_blocks),
            vec(bufs.structurals, num_chunks),
            vec(bufs.local_offsets, num_chunks),
            vec(bufs.count_aggs, num_blocks),
            vec(bufs.seg_chunk_off, num_segs + 1),
            vec(bufs.seg_starts, num_segs),
            vec(bufs.seg_lens, num_segs),
            num_segs,
            num_chunks,
            bufs.chunk_cap,
            grid_dim=grid,
            block_dim=BLOCK,
        )
        ctx.enqueue_function[scan_counts_kernel](
            vec(bufs.count_aggs, num_blocks),
            vec(bufs.count_bases, num_blocks),
            vec(bufs.total, 1),
            grid_dim=1,
            block_dim=BLOCK,
        )
        ctx.enqueue_function[scatter_kernel](
            vec(bufs.structurals, num_chunks),
            vec(bufs.local_offsets, num_chunks),
            vec(bufs.count_bases, num_blocks),
            vec(bufs.total, 1),
            # Written up to the device-side structural total, which the
            # host only learns after this launch — so the view is the
            # whole allocation.
            vec(bufs.positions, bufs.pos_cap),
            vec(bufs.seg_chunk_off, num_segs + 1),
            vec(bufs.seg_starts, num_segs),
            vec(bufs.seg_lens, num_segs),
            num_segs,
            num_chunks,
            input_len,
            grid_dim=grid,
            block_dim=BLOCK,
        )


struct Stage1Buffers(Movable):
    """Reusable device buffers for the stage-1 pipeline (grown
    geometrically, never shrunk)."""

    var masks: DeviceBuffer[DType.uint64]  # 4 planes x chunk_cap
    var prefixes: DeviceBuffer[DType.uint16]
    var aggs: DeviceBuffer[DType.uint16]
    var block_states: DeviceBuffer[DType.uint8]
    var structurals: DeviceBuffer[DType.uint64]
    var local_offsets: DeviceBuffer[DType.uint32]
    var count_aggs: DeviceBuffer[DType.uint32]
    var count_bases: DeviceBuffer[DType.uint32]
    var total: DeviceBuffer[DType.uint32]
    var positions: DeviceBuffer[DType.uint32]
    var positions_host: HostBuffer[DType.uint32]
    var seg_chunk_off: DeviceBuffer[DType.uint32]  # num_segs + 1
    var seg_starts: DeviceBuffer[DType.uint32]  # num_segs
    var seg_lens: DeviceBuffer[DType.uint32]  # num_segs
    var seg_staging_off: HostBuffer[DType.uint32]
    var seg_staging_starts: HostBuffer[DType.uint32]
    var seg_staging_lens: HostBuffer[DType.uint32]
    var chunk_cap: Int
    var pos_cap: Int
    var seg_cap: Int

    def __init__(out self, ctx: DeviceContext) raises:
        comptime MIN_CHUNKS = 64
        comptime MIN_POS = 4096
        comptime MIN_SEGS = 16
        self.chunk_cap = MIN_CHUNKS
        self.pos_cap = MIN_POS
        self.seg_cap = MIN_SEGS
        var blocks = ceildiv(MIN_CHUNKS, BLOCK)
        self.masks = ctx.enqueue_create_buffer[DType.uint64](5 * MIN_CHUNKS)
        self.prefixes = ctx.enqueue_create_buffer[DType.uint16](MIN_CHUNKS)
        self.aggs = ctx.enqueue_create_buffer[DType.uint16](blocks)
        self.block_states = ctx.enqueue_create_buffer[DType.uint8](blocks)
        self.structurals = ctx.enqueue_create_buffer[DType.uint64](MIN_CHUNKS)
        self.local_offsets = ctx.enqueue_create_buffer[DType.uint32](MIN_CHUNKS)
        self.count_aggs = ctx.enqueue_create_buffer[DType.uint32](blocks)
        self.count_bases = ctx.enqueue_create_buffer[DType.uint32](blocks)
        self.total = ctx.enqueue_create_buffer[DType.uint32](1)
        self.positions = ctx.enqueue_create_buffer[DType.uint32](MIN_POS)
        self.positions_host = ctx.enqueue_create_host_buffer[DType.uint32](
            MIN_POS
        )
        self.seg_chunk_off = ctx.enqueue_create_buffer[DType.uint32](
            MIN_SEGS + 1
        )
        self.seg_starts = ctx.enqueue_create_buffer[DType.uint32](MIN_SEGS)
        self.seg_lens = ctx.enqueue_create_buffer[DType.uint32](MIN_SEGS)
        self.seg_staging_off = ctx.enqueue_create_host_buffer[DType.uint32](
            MIN_SEGS + 1
        )
        self.seg_staging_starts = ctx.enqueue_create_host_buffer[DType.uint32](
            MIN_SEGS
        )
        self.seg_staging_lens = ctx.enqueue_create_host_buffer[DType.uint32](
            MIN_SEGS
        )

    def ensure(
        mut self, ctx: DeviceContext, num_chunks: Int, input_len: Int
    ) raises:
        """Grows the buffers for `num_chunks` chunks and up to
        `input_len` structural positions (+ sentinels)."""
        if num_chunks > self.chunk_cap:
            var new_cap = max(num_chunks, self.chunk_cap * 2)
            var blocks = ceildiv(new_cap, BLOCK)
            self.masks = ctx.enqueue_create_buffer[DType.uint64](5 * new_cap)
            self.prefixes = ctx.enqueue_create_buffer[DType.uint16](new_cap)
            self.aggs = ctx.enqueue_create_buffer[DType.uint16](blocks)
            self.block_states = ctx.enqueue_create_buffer[DType.uint8](blocks)
            self.structurals = ctx.enqueue_create_buffer[DType.uint64](new_cap)
            self.local_offsets = ctx.enqueue_create_buffer[DType.uint32](
                new_cap
            )
            self.count_aggs = ctx.enqueue_create_buffer[DType.uint32](blocks)
            self.count_bases = ctx.enqueue_create_buffer[DType.uint32](blocks)
            self.chunk_cap = new_cap
        var pos_needed = input_len + 4
        if pos_needed > self.pos_cap:
            var new_pos = max(pos_needed, self.pos_cap * 2)
            self.positions = ctx.enqueue_create_buffer[DType.uint32](new_pos)
            self.positions_host = ctx.enqueue_create_host_buffer[DType.uint32](
                new_pos
            )
            self.pos_cap = new_pos
        ctx.synchronize()

    def upload_segments(
        mut self,
        ctx: DeviceContext,
        chunk_off: List[UInt32],
        starts: List[UInt32],
        lens: List[UInt32],
    ) raises:
        """Uploads the segment descriptors (`chunk_off` has one extra
        trailing entry: the total chunk count)."""
        var s = len(starts)
        if s > self.seg_cap:
            var new_cap = max(s, self.seg_cap * 2)
            self.seg_chunk_off = ctx.enqueue_create_buffer[DType.uint32](
                new_cap + 1
            )
            self.seg_starts = ctx.enqueue_create_buffer[DType.uint32](new_cap)
            self.seg_lens = ctx.enqueue_create_buffer[DType.uint32](new_cap)
            self.seg_staging_off = ctx.enqueue_create_host_buffer[DType.uint32](
                new_cap + 1
            )
            self.seg_staging_starts = ctx.enqueue_create_host_buffer[
                DType.uint32
            ](new_cap)
            self.seg_staging_lens = ctx.enqueue_create_host_buffer[
                DType.uint32
            ](new_cap)
            self.seg_cap = new_cap
            ctx.synchronize()
        memcpy(
            dest=self.seg_staging_off.unsafe_ptr(),
            src=chunk_off.unsafe_ptr(),
            count=s + 1,
        )
        memcpy(
            dest=self.seg_staging_starts.unsafe_ptr(),
            src=starts.unsafe_ptr(),
            count=s,
        )
        memcpy(
            dest=self.seg_staging_lens.unsafe_ptr(),
            src=lens.unsafe_ptr(),
            count=s,
        )
        ctx.enqueue_copy(
            dst_ptr=self.seg_chunk_off.unsafe_ptr(),
            src_ptr=self.seg_staging_off.unsafe_ptr(),
            size=s + 1,
        )
        ctx.enqueue_copy(
            dst_ptr=self.seg_starts.unsafe_ptr(),
            src_ptr=self.seg_staging_starts.unsafe_ptr(),
            size=s,
        )
        ctx.enqueue_copy(
            dst_ptr=self.seg_lens.unsafe_ptr(),
            src_ptr=self.seg_staging_lens.unsafe_ptr(),
            size=s,
        )
