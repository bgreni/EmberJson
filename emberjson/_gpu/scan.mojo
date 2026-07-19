"""Carry-scan algebra + mid-level scan kernels for GPU stage 1.

Stage 1 has three cross-chunk carries (see `_index/`): the escape-run
carry, the in-string quote parity, and the previous chunk's scalar bit.
Per 64-byte chunk they form a tiny state machine: 2 bits of input state
(escape carry e, parity p) fully determine the chunk's outputs, and the
scalar bit is a pure output. Each chunk is therefore a transfer function
from (e, p) to (e', p', scalar63'), encodable in 12 bits:

    element: UInt16, entry_i = bits [3i, 3i+3) for input state i = e + 2p
    entry   = e' | p' << 1 | sc' << 2

Composition `a then b` selects b's entry through a's output state — an
associative operation — so resolving every chunk's carry-in is one
exclusive scan over these elements, replacing three separate scans.
The identity has sc' = 0, which composition on the RIGHT would clobber;
scans here only seed with it on the left (exclusive-scan semantics), and
block aggregates read the last real element's inclusive value instead of
padding with identity.

The functions are pure integer math, callable (and unit-tested) on the
CPU; the kernels at the bottom run the small mid-level pass over
per-block aggregates in a single threadgroup.
"""

from std.bit import pop_count
from std.math import ceildiv
from std.memory import UnsafePointer, stack_allocation
from std.sys import has_accelerator
from std.gpu import barrier, thread_idx
from std.gpu.host import DeviceContext, DeviceBuffer
from std.gpu.memory import AddressSpace

from emberjson._index.portable import escape_next, prefix_xor_portable

comptime SCAN_BLOCK = 256

# Identity transfer: e' = e, p' = p, sc' = 0 for every input state.
comptime IDENTITY_ELEM: UInt16 = 0 | 1 << 3 | 2 << 6 | 3 << 9


@always_inline
def compose(a: UInt16, b: UInt16) -> UInt16:
    """`a` then `b`: route each input state through a, then b."""
    var out: UInt16 = 0
    comptime for i in range(4):
        var ai = (a >> UInt16(3 * i)) & 7
        var ep = ai & 3
        var bi = (b >> (3 * ep)) & 7
        out |= bi << UInt16(3 * i)
    return out


@always_inline
def apply_state(state: UInt8, elem: UInt16) -> UInt8:
    """Runs a 2-bit (e, p) input state through a transfer element,
    returning the 3-bit (e', p', sc') output."""
    return UInt8((elem >> (3 * UInt16(state & 3))) & 7)


@always_inline
def constant_element(entry3: UInt8) -> UInt16:
    """A transfer element mapping EVERY input state to `entry3`.

    Segment-head chunks use this (their carry-in is the reset state by
    definition, so their transfer function is constant): a constant
    element absorbs anything composed before it under plain composition
    — `compose(a, const) == const` — which is what lets one unsegmented
    function-composition scan subsume the segmented scan, with no flag
    machinery."""
    var e = UInt16(entry3 & 7)
    return e | e << 3 | e << 6 | e << 9


@always_inline
def chunk_transfer_element(
    backslash: UInt64,
    quote: UInt64,
    op: UInt64,
    whitespace: UInt64,
    valid_mask: UInt64,
) -> UInt16:
    """Builds a chunk's transfer element by evaluating the shared stage-1
    algebra (`_index/portable.mojo`) at all four input states."""
    var ws63 = (whitespace >> 63) & 1
    var op63 = (op >> 63) & 1
    var valid63 = (valid_mask >> 63) & 1

    var elem: UInt16 = 0
    comptime for e in range(2):
        var r = escape_next(backslash, UInt64(e))
        var escaped = r[0]
        var e_out = r[1]
        var rq = quote & ~escaped
        var px63 = (prefix_xor_portable(rq) >> 63) & 1
        var rq63 = (rq >> 63) & 1
        comptime for p in range(2):
            var p_out = px63 ^ UInt64(p)
            var in63 = p_out
            var sc_out = ~(ws63 | op63 | rq63 | in63) & valid63
            var entry = UInt16(e_out | p_out << 1 | sc_out << 2)
            comptime i = e + 2 * p
            elem |= entry << UInt16(3 * i)
    return elem


def scan_aggregates_kernel(
    aggs: UnsafePointer[UInt16, MutAnyOrigin],
    block_states: UnsafePointer[UInt8, MutAnyOrigin],
    num_blocks: Int,
):
    """Single-threadgroup pass: turns per-block aggregate elements into
    each block's carry-in state (evaluated from the (0,0) initial state).

    Loops over the aggregates in tiles of SCAN_BLOCK, carrying the
    running composition across tiles; block b's state = apply(0,
    composition of aggregates [0, b)).
    """
    var tid = thread_idx.x
    var shared = stack_allocation[
        SCAN_BLOCK, UInt16, address_space=AddressSpace.SHARED
    ]()
    var carried: UInt16 = IDENTITY_ELEM

    var tile_start = 0
    while tile_start < num_blocks:
        var n_tile = min(SCAN_BLOCK, num_blocks - tile_start)
        if tid < n_tile:
            shared[tid] = aggs[tile_start + tid]
        barrier()
        # Hillis-Steele inclusive scan (compose) in shared memory.
        var offset = 1
        while offset < SCAN_BLOCK:
            var v: UInt16 = IDENTITY_ELEM
            var have = tid >= offset and tid < n_tile
            if have:
                v = shared[tid - offset]
            barrier()
            if have:
                shared[tid] = compose(v, shared[tid])
            barrier()
            offset <<= 1
        if tid < n_tile:
            # Exclusive prefix for this block = carried ∘ inclusive[tid-1].
            var prefix = carried
            if tid > 0:
                prefix = compose(carried, shared[tid - 1])
            block_states[tile_start + tid] = apply_state(0, prefix)
        barrier()
        carried = compose(carried, shared[n_tile - 1])
        tile_start += SCAN_BLOCK


def scan_counts_kernel(
    count_aggs: UnsafePointer[UInt32, MutAnyOrigin],
    count_bases: UnsafePointer[UInt32, MutAnyOrigin],
    total_out: UnsafePointer[UInt32, MutAnyOrigin],
    num_blocks: Int,
):
    """Single-threadgroup exclusive sum over per-block structural counts;
    also writes the grand total (for the sentinel writer and readback)."""
    var tid = thread_idx.x
    var shared = stack_allocation[
        SCAN_BLOCK, UInt32, address_space=AddressSpace.SHARED
    ]()
    var carried: UInt32 = 0

    var tile_start = 0
    while tile_start < num_blocks:
        var n_tile = min(SCAN_BLOCK, num_blocks - tile_start)
        if tid < n_tile:
            shared[tid] = count_aggs[tile_start + tid]
        barrier()
        var offset = 1
        while offset < SCAN_BLOCK:
            var v: UInt32 = 0
            var have = tid >= offset and tid < n_tile
            if have:
                v = shared[tid - offset]
            barrier()
            if have:
                shared[tid] += v
            barrier()
            offset <<= 1
        if tid < n_tile:
            var prefix = carried
            if tid > 0:
                prefix += shared[tid - 1]
            count_bases[tile_start + tid] = prefix
        barrier()
        carried += shared[n_tile - 1]
        tile_start += SCAN_BLOCK

    if tid == 0:
        total_out[0] = carried
