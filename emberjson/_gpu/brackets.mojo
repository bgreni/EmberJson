"""Parallel bracket matching (cuJSON's structure recognizer, on Metal).

The insight (AutomataLab/cuJSON, ASPLOS'26): after adjusting every
OPENING container token's depth down by one, an open and its matching
close share the same depth — and within one depth level, well-formed
containers alternate strictly open, close, open, close in document
order (a sibling must close before the next opens). So:

    depth per container token   (+1/-1 inclusive scan; opens -1 after)
    stable sort by depth        (keeps document order within a level)
    pair sorted[2k], sorted[2k+1] and validate open/close type match

cuJSON validates the pair with one XOR: '[' ^ ']' == '{' ^ '}' == 0x06,
which simultaneously checks type-match and open-before-close ordering.
Any malformed nesting breaks alternation somewhere and fails that check
(or leaves an odd-length level).

Metal adaptation: Thrust's sort becomes a stable counting sort over the
depth domain (depth is capped at the walker's `_MAX_DEPTH` = 1024):
per-block shared-memory histograms, one bucket-major exclusive scan
(reusing the stage-2 scan kernels), and a stable scatter whose in-block
rank is recomputed from the shared histogram replay. All control flow
follows the Metal-safe single-exit shape.

Outputs, per container token (in compacted container order): the
matching partner's TOKEN index (into the stage-2 token stream), plus a
global error flag. This is exactly the data the tape's container words
need (close index / open index), computed with zero serial work.
"""

from std.math import ceildiv
from std.memory import UnsafePointer, stack_allocation
from std.sys import has_accelerator
from std.atomic import Atomic
from std.gpu import barrier, global_idx, thread_idx
from std.gpu.host import DeviceContext, DeviceBuffer, HostBuffer
from std.gpu.memory import AddressSpace

from .stage1 import BLOCK
from .stage2 import (
    TOK_CLOSE_ARR,
    TOK_CLOSE_OBJ,
    TOK_KIND_MASK,
    TOK_OPEN_ARR,
    TOK_OPEN_OBJ,
)

comptime MAX_BRACKET_DEPTH = 1024


@always_inline
def _is_container(kind: UInt8) -> Bool:
    return (
        kind == TOK_OPEN_OBJ
        or kind == TOK_CLOSE_OBJ
        or kind == TOK_OPEN_ARR
        or kind == TOK_CLOSE_ARR
    )


@always_inline
def _is_open(kind: UInt8) -> Bool:
    return kind == TOK_OPEN_OBJ or kind == TOK_OPEN_ARR


def oc_count_kernel(
    types: UnsafePointer[UInt8, MutAnyOrigin],
    counts: UnsafePointer[UInt32, MutAnyOrigin],
    num_tokens: Int,
):
    """Per-block count of container tokens (feeds the compaction scan)."""
    var tid = thread_idx.x
    var t = global_idx.x
    var c: UInt32 = 0
    if t < num_tokens:
        if _is_container(types[t] & TOK_KIND_MASK):
            c = 1
    var shared = stack_allocation[
        BLOCK, UInt32, address_space=AddressSpace.SHARED
    ]()
    shared[tid] = c
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
    if tid == BLOCK - 1:
        counts[t // BLOCK] = shared[tid]


def oc_compact_kernel(
    types: UnsafePointer[UInt8, MutAnyOrigin],
    block_bases: UnsafePointer[UInt32, MutAnyOrigin],
    oc_tok: UnsafePointer[UInt32, MutAnyOrigin],
    oc_delta: UnsafePointer[Int32, MutAnyOrigin],
    num_tokens: Int,
):
    """Scatter container tokens (their token index + depth delta) in
    document order, using the block-scanned bases."""
    var tid = thread_idx.x
    var t = global_idx.x
    var is_c = False
    var kind: UInt8 = 0
    if t < num_tokens:
        kind = types[t] & TOK_KIND_MASK
        is_c = _is_container(kind)
    var c: UInt32 = UInt32(1) if is_c else UInt32(0)
    var shared = stack_allocation[
        BLOCK, UInt32, address_space=AddressSpace.SHARED
    ]()
    shared[tid] = c
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
    if is_c:
        var w = Int(block_bases[t // BLOCK] + shared[tid] - c)
        oc_tok[w] = UInt32(t)
        oc_delta[w] = Int32(1) if _is_open(kind) else Int32(-1)


def depth_block_kernel(
    oc_delta: UnsafePointer[Int32, MutAnyOrigin],
    depth_excl: UnsafePointer[Int32, MutAnyOrigin],
    block_aggs: UnsafePointer[Int32, MutAnyOrigin],
    oc_cnt: Int,
):
    """Per-block inclusive +1/-1 scan (block phase of the depth scan)."""
    var tid = thread_idx.x
    var g = global_idx.x
    var v: Int32 = 0
    if g < oc_cnt:
        v = oc_delta[g]
    var shared = stack_allocation[
        BLOCK, Int32, address_space=AddressSpace.SHARED
    ]()
    shared[tid] = v
    barrier()
    var offset = 1
    while offset < BLOCK:
        var u: Int32 = 0
        if tid >= offset:
            u = shared[tid - offset]
        barrier()
        shared[tid] += u
        barrier()
        offset <<= 1
    if g < oc_cnt:
        depth_excl[g] = shared[tid]  # inclusive within block
    if tid == BLOCK - 1:
        block_aggs[g // BLOCK] = shared[tid]


def depth_aggs_kernel(
    block_aggs: UnsafePointer[Int32, MutAnyOrigin],
    block_bases: UnsafePointer[Int32, MutAnyOrigin],
    num_blocks: Int,
):
    """Single-threadgroup exclusive scan of block depth sums."""
    var tid = thread_idx.x
    var shared = stack_allocation[
        BLOCK, Int32, address_space=AddressSpace.SHARED
    ]()
    var carried: Int32 = 0
    var tile = 0
    while tile < num_blocks:
        var n_tile = min(BLOCK, num_blocks - tile)
        if tid < n_tile:
            shared[tid] = block_aggs[tile + tid]
        barrier()
        var offset = 1
        while offset < BLOCK:
            var u: Int32 = 0
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


def depth_finalize_kernel(
    oc_delta: UnsafePointer[Int32, MutAnyOrigin],
    depth_incl: UnsafePointer[Int32, MutAnyOrigin],
    block_bases: UnsafePointer[Int32, MutAnyOrigin],
    depth_key: UnsafePointer[UInt32, MutAnyOrigin],
    err_flag: UnsafePointer[Int32, MutAnyOrigin],
    oc_cnt: Int,
):
    """Adds block bases, applies cuJSON's open-adjustment (open's key =
    its inclusive depth - 1 = the matching close's key), and validates
    the depth domain (negative depth = close-before-open; >= 1024 =
    walker's max-depth verdict)."""
    var g = global_idx.x
    if g >= oc_cnt:
        return
    var d = depth_incl[g] + block_bases[g // BLOCK]
    var key = d
    if oc_delta[g] > 0:
        key = d - 1
    if key < 0 or key >= MAX_BRACKET_DEPTH:
        _ = Atomic.fetch_add(err_flag, 1)
        key = 0
    depth_key[g] = UInt32(key)


def hist_kernel(
    depth_key: UnsafePointer[UInt32, MutAnyOrigin],
    block_hists: UnsafePointer[UInt32, MutAnyOrigin],
    oc_cnt: Int,
    num_blocks: Int,
):
    """Per-block depth histograms, written bucket-major:
    block_hists[d * num_blocks + b]."""
    var tid = thread_idx.x
    var b = Int(global_idx.x) // BLOCK
    var shared = stack_allocation[
        MAX_BRACKET_DEPTH, UInt32, address_space=AddressSpace.SHARED
    ]()
    var i = tid
    while i < MAX_BRACKET_DEPTH:
        shared[i] = 0
        i += BLOCK
    barrier()
    var g = b * BLOCK + tid
    if g < oc_cnt:
        _ = Atomic.fetch_add(
            shared.address_space_cast[AddressSpace.SHARED]()
            + Int(depth_key[g]),
            UInt32(1),
        )
    barrier()
    i = tid
    while i < MAX_BRACKET_DEPTH:
        block_hists[i * num_blocks + b] = shared[i]
        i += BLOCK


def sort_scatter_kernel(
    depth_key: UnsafePointer[UInt32, MutAnyOrigin],
    oc_tok: UnsafePointer[UInt32, MutAnyOrigin],
    hist_bases: UnsafePointer[UInt32, MutAnyOrigin],
    sorted_tok: UnsafePointer[UInt32, MutAnyOrigin],
    sorted_key: UnsafePointer[UInt32, MutAnyOrigin],
    oc_cnt: Int,
    num_blocks: Int,
):
    """Stable scatter: position = scanned bucket-major histogram base +
    in-block rank among same-key elements (replayed from shared keys —
    O(BLOCK) per thread, bounded and Metal-safe)."""
    var tid = thread_idx.x
    var b = Int(global_idx.x) // BLOCK
    var g = b * BLOCK + tid
    var shared_keys = stack_allocation[
        BLOCK, UInt32, address_space=AddressSpace.SHARED
    ]()
    var key: UInt32 = 0xFFFFFFFF
    if g < oc_cnt:
        key = depth_key[g]
    shared_keys[tid] = key
    barrier()
    if g < oc_cnt:
        var rank = 0
        for j in range(tid):
            if shared_keys[j] == key:
                rank += 1
        var base = Int(hist_bases[Int(key) * num_blocks + b])
        var w = base + rank
        sorted_tok[w] = oc_tok[g]
        sorted_key[w] = key
    _ = shared_keys  # keep alive


def pair_validate_kernel(
    sorted_tok: UnsafePointer[UInt32, MutAnyOrigin],
    sorted_key: UnsafePointer[UInt32, MutAnyOrigin],
    types: UnsafePointer[UInt8, MutAnyOrigin],
    pair_tok: UnsafePointer[UInt32, MutAnyOrigin],
    err_flag: UnsafePointer[Int32, MutAnyOrigin],
    oc_cnt: Int,
):
    """Neighbor pairing + validation over the depth-sorted stream.

    For each even index 2k: the pair (2k, 2k+1) must exist, share a
    depth level, and be (open, close) of the same container class —
    cuJSON's XOR trick: open_kind ^ close_kind == 1 in our token
    encoding (OPEN_OBJ=0/CLOSE_OBJ=1, OPEN_ARR=2/CLOSE_ARR=3), with the
    open strictly first in document order (guaranteed by stable sort +
    checking open/close roles explicitly). Writes both directions of
    the match, as CONTAINER-token indexes into the token stream."""
    var k = global_idx.x
    var i = Int(k) * 2
    if i >= oc_cnt:
        return
    var bad = False
    if i + 1 >= oc_cnt:
        bad = True
    else:
        var t_open = Int(sorted_tok[i])
        var t_close = Int(sorted_tok[i + 1])
        var k_open = types[t_open] & TOK_KIND_MASK
        var k_close = types[t_close] & TOK_KIND_MASK
        if sorted_key[i] != sorted_key[i + 1]:
            bad = True
        elif not _is_open(k_open):
            bad = True
        elif (k_open ^ k_close) != 1:
            bad = True
        else:
            pair_tok[t_open] = UInt32(t_close)
            pair_tok[t_close] = UInt32(t_open)
    if bad:
        _ = Atomic.fetch_add(err_flag, 1)


struct BracketBuffers(Movable):
    """Reusable buffers for the parallel bracket matcher."""

    var oc_counts: DeviceBuffer[DType.uint32]
    var oc_bases: DeviceBuffer[DType.uint32]
    var oc_tok: DeviceBuffer[DType.uint32]
    var oc_delta: DeviceBuffer[DType.int32]
    var depth_incl: DeviceBuffer[DType.int32]
    var depth_aggs: DeviceBuffer[DType.int32]
    var depth_bases: DeviceBuffer[DType.int32]
    var depth_key: DeviceBuffer[DType.uint32]
    var block_hists: DeviceBuffer[DType.uint32]
    var hist_scanned: DeviceBuffer[DType.uint32]
    var hist_scan_aggs: DeviceBuffer[DType.uint32]
    var hist_scan_bases: DeviceBuffer[DType.uint32]
    var sorted_tok: DeviceBuffer[DType.uint32]
    var sorted_key: DeviceBuffer[DType.uint32]
    var pair_tok: DeviceBuffer[DType.uint32]
    var pair_compact: DeviceBuffer[DType.uint32]
    var oc_total: DeviceBuffer[DType.uint32]
    var oc_tok_host: HostBuffer[DType.uint32]
    var pair_host: HostBuffer[DType.uint32]
    var oc_cnt_host: HostBuffer[DType.uint32]
    var tok_cap: Int
    var oc_cap: Int

    def __init__(out self, ctx: DeviceContext) raises:
        comptime MIN_TOK = 4096
        comptime MIN_OC = 1024
        self.tok_cap = MIN_TOK
        self.oc_cap = MIN_OC
        var tb = ceildiv(MIN_TOK, BLOCK)
        var ob = ceildiv(MIN_OC, BLOCK)
        self.oc_counts = ctx.enqueue_create_buffer[DType.uint32](tb)
        self.oc_bases = ctx.enqueue_create_buffer[DType.uint32](tb)
        self.oc_tok = ctx.enqueue_create_buffer[DType.uint32](MIN_OC)
        self.oc_delta = ctx.enqueue_create_buffer[DType.int32](MIN_OC)
        self.depth_incl = ctx.enqueue_create_buffer[DType.int32](MIN_OC)
        self.depth_aggs = ctx.enqueue_create_buffer[DType.int32](ob)
        self.depth_bases = ctx.enqueue_create_buffer[DType.int32](ob)
        self.depth_key = ctx.enqueue_create_buffer[DType.uint32](MIN_OC)
        self.block_hists = ctx.enqueue_create_buffer[DType.uint32](
            ob * MAX_BRACKET_DEPTH
        )
        self.hist_scanned = ctx.enqueue_create_buffer[DType.uint32](
            ob * MAX_BRACKET_DEPTH
        )
        var hb = ceildiv(ob * MAX_BRACKET_DEPTH, BLOCK)
        self.hist_scan_aggs = ctx.enqueue_create_buffer[DType.uint32](hb)
        self.hist_scan_bases = ctx.enqueue_create_buffer[DType.uint32](hb)
        self.sorted_tok = ctx.enqueue_create_buffer[DType.uint32](MIN_OC)
        self.sorted_key = ctx.enqueue_create_buffer[DType.uint32](MIN_OC)
        self.pair_tok = ctx.enqueue_create_buffer[DType.uint32](MIN_TOK)
        self.pair_compact = ctx.enqueue_create_buffer[DType.uint32](MIN_OC)
        self.oc_total = ctx.enqueue_create_buffer[DType.uint32](1)
        self.oc_tok_host = ctx.enqueue_create_host_buffer[DType.uint32](MIN_OC)
        self.pair_host = ctx.enqueue_create_host_buffer[DType.uint32](MIN_OC)
        self.oc_cnt_host = ctx.enqueue_create_host_buffer[DType.uint32](1)

    def ensure(
        mut self, ctx: DeviceContext, num_tokens: Int, oc_cnt: Int
    ) raises:
        var grew = False
        if num_tokens > self.tok_cap:
            var cap = max(num_tokens, self.tok_cap * 2)
            var tb = ceildiv(cap, BLOCK)
            self.oc_counts = ctx.enqueue_create_buffer[DType.uint32](tb)
            self.oc_bases = ctx.enqueue_create_buffer[DType.uint32](tb)
            self.pair_tok = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.tok_cap = cap
            grew = True
        if oc_cnt > self.oc_cap:
            var cap = max(oc_cnt, self.oc_cap * 2)
            var ob = ceildiv(cap, BLOCK)
            self.oc_tok = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.oc_delta = ctx.enqueue_create_buffer[DType.int32](cap)
            self.depth_incl = ctx.enqueue_create_buffer[DType.int32](cap)
            self.depth_aggs = ctx.enqueue_create_buffer[DType.int32](ob)
            self.depth_bases = ctx.enqueue_create_buffer[DType.int32](ob)
            self.depth_key = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.block_hists = ctx.enqueue_create_buffer[DType.uint32](
                ob * MAX_BRACKET_DEPTH
            )
            self.hist_scanned = ctx.enqueue_create_buffer[DType.uint32](
                ob * MAX_BRACKET_DEPTH
            )
            var hb = ceildiv(ob * MAX_BRACKET_DEPTH, BLOCK)
            self.hist_scan_aggs = ctx.enqueue_create_buffer[DType.uint32](hb)
            self.hist_scan_bases = ctx.enqueue_create_buffer[DType.uint32](hb)
            self.sorted_tok = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.sorted_key = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.pair_compact = ctx.enqueue_create_buffer[DType.uint32](cap)
            self.oc_tok_host = ctx.enqueue_create_host_buffer[DType.uint32](cap)
            self.pair_host = ctx.enqueue_create_host_buffer[DType.uint32](cap)
            self.oc_cap = cap
            grew = True
        if grew:
            ctx.synchronize()


def u32_scan_block_kernel(
    elems: UnsafePointer[UInt32, MutAnyOrigin],
    excl: UnsafePointer[UInt32, MutAnyOrigin],
    block_aggs: UnsafePointer[UInt32, MutAnyOrigin],
    n: Int,
):
    """Block phase of a u32 exclusive scan (aggregates feed
    `scan.scan_counts_kernel`; `u32_scan_apply_kernel` finishes)."""
    var tid = thread_idx.x
    var g = global_idx.x
    var v: UInt32 = 0
    if g < n:
        v = elems[g]
    var shared = stack_allocation[
        BLOCK, UInt32, address_space=AddressSpace.SHARED
    ]()
    shared[tid] = v
    barrier()
    var offset = 1
    while offset < BLOCK:
        var u: UInt32 = 0
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


def u32_scan_apply_kernel(
    excl: UnsafePointer[UInt32, MutAnyOrigin],
    block_bases: UnsafePointer[UInt32, MutAnyOrigin],
    n: Int,
):
    var g = global_idx.x
    if g < n:
        excl[g] += block_bases[g // BLOCK]


def gather_pairs_kernel(
    oc_tok: UnsafePointer[UInt32, MutAnyOrigin],
    pair_tok: UnsafePointer[UInt32, MutAnyOrigin],
    pair_compact: UnsafePointer[UInt32, MutAnyOrigin],
    oc_cnt: Int,
):
    """pair_compact[i] = partner token of the i-th container (document
    order) — the compact readback for testing and host consumers."""
    var g = global_idx.x
    if g < oc_cnt:
        pair_compact[g] = pair_tok[Int(oc_tok[g])]
