"""Stage-1 indexer: the chunk loop that emits structural character positions.

Ported from simdjson. `structural_index` walks the input 64 bytes
at a time; for each chunk it combines the classifier's operator/whitespace
masks with the string-mask scanners to compute that chunk's structural
bits: structural operators outside strings, every real (non-escaped)
quote, and pseudo-structural scalar starts (the first byte of a number or
`true`/`false`/`null`). Set bits are scattered into the caller's reusable
`positions` buffer by an `emit` that writes 4 unconditional slots, then
pairs, trading a small over-write tail for removing most of the
per-structural mispredicted branches.

Output is deferred by one chunk so cross-chunk carries settle, and the
spurious tail produced by the final chunk's zero bytes is trimmed at the
end. On exit, `len(positions)` equals the true structural count.

Unlike simdjson, the input need not be a padded copy: with
`assume_padded=False` the final partial chunk is copied into a zeroed
64-byte stack buffer, so the caller's original (borrowed) input can be
indexed without any heap copy. `assume_padded=True` requires a
`PaddedBuffer`-backed input and loads every chunk directly.

AVX2 targets run a differently shaped loop, `_structural_index_x86`
(same contract, bit-identical output); see its docstring. aarch64 keeps
the loop below unchanged.
"""

from std.bit import count_trailing_zeros, pop_count
from std.builtin.globals import global_constant
from std.memory import unsafe_memcpy
from std.sys.info import CompilationTarget
from std.sys.intrinsics import likely, unlikely

from emberjson.utils import BytePtr, StackArray
from .simd_ops import SimdInput
from .classifier import classify
from .portable import structurals_from_masks
from .string_mask import EscapeScanner, StringScanner


comptime INDEX_HAS_BACKSLASH: UInt64 = 1
"""`structural_index_with_flags` bit: the input contains a backslash."""


comptime INDEX_SLACK = 9
"""Slots past `input_len` that `structural_index_into`'s buffer needs: the
emit loops over-write up to 8 slots past the true count, which is itself up
to `input_len + 1` before the tail trim."""


def structural_index[
    assume_padded: Bool
](ptr: BytePtr, input_len: Int, mut positions: List[UInt32]):
    """Fills `positions` with the offsets of every structural character.

    See `_structural_index` for the contract.
    """
    var flags: UInt64 = 0
    var backslashes = List[UInt32]()
    _index_list[assume_padded, False](
        ptr, input_len, positions, backslashes, flags
    )


def structural_index_with_flags[
    assume_padded: Bool
](
    ptr: BytePtr,
    input_len: Int,
    mut positions: List[UInt32],
    mut backslashes: List[UInt32],
) -> UInt64:
    """`structural_index` that also reports where strings need decoding.

    Fills `backslashes` with the ascending offset of every backslash in the
    input, and returns an `INDEX_*` bit set (whether any backslash occurs).
    A string span containing no listed backslash decodes to its own bytes.
    Offsets are only scattered for chunks that contain a backslash, so the
    common chunk pays one extra branch. Raw control bytes are NOT flagged:
    the consumer checks the strings it takes verbatim.
    """
    var flags: UInt64 = 0
    backslashes.resize(0, UInt32(0))
    _index_list[assume_padded, True](
        ptr, input_len, positions, backslashes, flags
    )
    return flags


def structural_index_into[
    assume_padded: Bool, o: MutOrigin
](
    ptr: BytePtr,
    input_len: Int,
    dest: Pointer[UInt32, o],
    mut backslashes: List[UInt32],
) -> Int:
    """`structural_index_with_flags` into `dest`, caller storage of at least
    `input_len + INDEX_SLACK` slots, such as a stack buffer for a small
    input. Returns the structural count."""
    var flags: UInt64 = 0
    backslashes.resize(0, UInt32(0))
    return _structural_index[assume_padded, True](
        ptr, input_len, dest, backslashes, flags
    )


@always_inline
def _index_list[
    assume_padded: Bool, with_flags: Bool
](
    ptr: BytePtr,
    input_len: Int,
    mut positions: List[UInt32],
    mut backslashes: List[UInt32],
    mut flags: UInt64,
):
    """`_structural_index` into `positions`, a reusable buffer: it is only
    (re)allocated when its capacity cannot hold the worst case (capacity-
    based, because it is resized down to the structural count on exit, so
    a warm buffer has a small length but a large capacity)."""
    if positions.capacity() < input_len + INDEX_SLACK:
        positions.reserve(input_len + INDEX_SLACK)
    # Length must cover the raw-pointer write phase.
    positions.resize(unsafe_uninit_length=input_len + INDEX_SLACK)
    var n = _structural_index[assume_padded, with_flags](
        ptr, input_len, positions.unsafe_ptr(), backslashes, flags
    )
    positions.resize(n, UInt32(0))


def _structural_index[
    assume_padded: Bool, with_flags: Bool, o: MutOrigin
](
    ptr: BytePtr,
    input_len: Int,
    out_ptr: Pointer[UInt32, o],
    mut backslashes: List[UInt32],
    mut flags: UInt64,
) -> Int:
    """Writes the offsets of every structural character to `out_ptr`,
    which has room for `input_len + INDEX_SLACK`, and returns their count.

    Structural characters are `{ } [ ] : ,`, both quotes of every string
    (in-string and escaped quotes are masked out), and the first byte of
    every scalar token. Positions are strictly ascending.

    Parameters:
        assume_padded: The input is backed by a `PaddedBuffer` and whole
            64-byte chunks may always be loaded. Otherwise the final
            partial chunk is staged through a zeroed stack buffer and the
            input is never read past `input_len`.

    Args:
        ptr: Start of the JSON input.
        input_len: Length of the JSON input in bytes.
        out_ptr: The output buffer.
    """
    comptime if _X86_STAGE1:
        # The interpreter takes the loop below: its kernels all have
        # portable branches, and this one reads a global table.
        if not __is_run_in_comptime_interpreter:
            return _structural_index_x86[assume_padded, with_flags](
                ptr, input_len, out_ptr, backslashes, flags
            )

    if input_len == 0:
        return 0

    var num_chunks = (input_len + 63) // 64

    var escape_scanner = EscapeScanner()
    var string_scanner = StringScanner()

    var backslash_acc: UInt64 = 0

    var prev_structurals: UInt64 = 0
    var prev_scalar_carry: UInt64 = 0
    var prev_base: UInt32 = 0

    var write_pos = 0

    @__parameter
    @always_inline("nodebug")
    def emit(base_idx: UInt32, bits: UInt64):
        """Writes the offset of each set bit into `positions`.

        Four unconditional slots, then pairs (simdjson #2869: typical
        JSON has 4-8 structurals per 64 bytes). Wastes 0-3 slots instead
        of the 0-7 the old groups-of-eight did. Over-writes land past the
        true count and are overwritten by the next emit or fall into
        INDEX_SLACK, and are never read.
        """
        if bits == 0:
            return
        var cnt = Int(pop_count(bits))
        var b = bits
        var w = write_pos
        comptime for k in range(4):
            out_ptr[unsafe_offset=w + k] = base_idx + UInt32(
                count_trailing_zeros(b)
            )
            b = b & (b - 1)
        if unlikely(cnt > 4):
            var done = 4
            while done < cnt:
                out_ptr[unsafe_offset=w + done] = base_idx + UInt32(
                    count_trailing_zeros(b)
                )
                b = b & (b - 1)
                out_ptr[unsafe_offset=w + done + 1] = base_idx + UInt32(
                    count_trailing_zeros(b)
                )
                b = b & (b - 1)
                done += 2
        write_pos += cnt

    for chunk_idx in range(num_chunks):
        var base_idx = UInt32(chunk_idx * 64)
        var input: SimdInput
        comptime if assume_padded:
            input = SimdInput.load(ptr.unsafe_offset(Int(base_idx)))
        else:
            if Int(base_idx) + 64 <= input_len:
                input = SimdInput.load(ptr.unsafe_offset(Int(base_idx)))
            else:
                # Final partial chunk: stage through a zeroed stack buffer
                # so the borrowed input is never read past input_len.
                var tail = Array[Byte, 64](fill=0)
                unsafe_memcpy(
                    dest=tail.unsafe_ptr(),
                    src=ptr.unsafe_offset(Int(base_idx)),
                    count=input_len - Int(base_idx),
                )
                input = SimdInput.load(tail.unsafe_ptr())

        # Classify whitespace and operators.
        var block = classify(input)

        # Escape and string scanning.
        var backslash = input.eq(UInt8(0x5C))
        var all_quotes = input.eq(UInt8(0x22))
        var escaped = escape_scanner.next(backslash)
        var in_string = string_scanner.next(all_quotes, escaped)

        # Real quotes (non-escaped).
        var real_quotes = all_quotes & ~escaped

        comptime if with_flags:
            if unlikely(backslash != 0):
                backslash_acc |= backslash
                var b = backslash
                while b != 0:
                    backslashes.append(
                        base_idx + UInt32(count_trailing_zeros(b))
                    )
                    b &= b - 1

        # Structural combine (shared algebra in `portable.mojo`):
        # operators outside strings, all real quotes, plus
        # pseudo-structural scalar starts (first byte of numbers, true,
        # false, null).
        var combined = structurals_from_masks(
            block.op,
            block.whitespace,
            real_quotes,
            in_string,
            prev_scalar_carry,
        )

        # Deferred output: write the PREVIOUS chunk's structurals so
        # cross-chunk carries have settled.
        if chunk_idx > 0:
            emit(prev_base, prev_structurals)

        prev_structurals = combined[0]
        prev_scalar_carry = combined[1]
        prev_base = base_idx

    # Flush the last chunk.
    emit(prev_base, prev_structurals)

    comptime if with_flags:
        if backslash_acc != 0:
            flags |= INDEX_HAS_BACKSLASH

    # Positions are emitted in strictly ascending order, so any position
    # >= input_len — spurious structurals from the final chunk's zero
    # bytes — forms a contiguous tail. Trim it.
    while (
        write_pos > 0 and Int(out_ptr[unsafe_offset=write_pos - 1]) >= input_len
    ):
        write_pos -= 1
    return write_pos


# --- AVX2 loop ----------------------------------------------------------
#
# Each design choice below was measured on Zen 2 (Ryzen 7 3700X) against
# the loop above and against the alternatives named in the docstring.

comptime _X86_STAGE1 = CompilationTarget.has_avx2()


def _make_bit_offsets() -> StackArray[UInt64, 2048]:
    """Entry `j * 256 + b` packs, one per byte, `8 * j` plus the offset of
    each set bit of `b`: the in-chunk offsets of mask byte `j`'s bits."""
    var t = StackArray[UInt64, 2048](fill=0)
    for j in range(8):
        for b in range(256):
            var packed: UInt64 = 0
            var n = 0
            for bit in range(8):
                if (b >> bit) & 1:
                    packed |= UInt64(8 * j + bit) << UInt64(8 * n)
                    n += 1
            t[j * 256 + b] = packed
    return t^


comptime _BIT_OFFSETS = _make_bit_offsets()


@no_inline
def _append_offsets(mut out: List[UInt32], base_idx: UInt32, bits: UInt64):
    """Out of line so the hot loop carries no call on its common path."""
    var b = bits
    while b != 0:
        out.append(base_idx + UInt32(count_trailing_zeros(b)))
        b &= b - 1


@always_inline
def _structural_index_x86[
    assume_padded: Bool, with_flags: Bool, o: MutOrigin
](
    ptr: BytePtr,
    input_len: Int,
    out_start: Pointer[UInt32, o],
    mut backslashes: List[UInt32],
    mut flags: UInt64,
) -> Int:
    """`_structural_index` for AVX2 targets: same contract and output.

    The vector work is the same as the portable loop's; the differences
    are all on the scalar side:

      * Emit is a branchless table expansion: each mask byte loads its
        bit offsets from `_BIT_OFFSETS` (already including the byte's
        `8 * j`), widens them to eight u32 (VPMOVZXBD), adds the chunk
        base and stores all eight, and the cursor advances by the byte's
        popcount. That costs the same per chunk whatever the density.
        The tzcnt/blsr scatter is a serial chain (BLSR takes 2 cycles on
        Zen 2) with count-dependent branches, at ~3 cycles per
        structural; the corpus averages 6-9.5 structurals per chunk.
        Baking `8 * j` into the table (16 KiB rather than 2 KiB) saves
        eight vector constants, which otherwise spill to the stack.
      * No backslash in the chunk skips the escape scan: only a run
        carried in from the previous chunk can escape anything, and only
        its first byte (simdjson's short-circuit).
      * The partial final chunk is peeled out of the loop, and the
        backslash scatter is out of line, so the loop body makes no
        calls. With a call inside, loop-carried state spilled to the
        stack every iteration, and Zen 2 retires one store per cycle.

    Tried and rejected: emitting each chunk as soon as its mask is known
    (deferring by one chunk overlaps the stores with the next chunk's
    vector work), and two chunks per iteration as simdjson does (a gain
    only before the escape short-circuit).
    """
    if input_len == 0:
        return 0

    # A table store writes eight slots however many bits it had, so up
    # to eight past the true count, which is itself up to input_len + 1:
    # the zero fill past the input starts one more scalar at input_len
    # when the input ends on whitespace or a structural (the trim below
    # drops it). INDEX_SLACK covers both.
    var escape_scanner = EscapeScanner()
    var string_scanner = StringScanner()
    var prev_structurals: UInt64 = 0
    var prev_scalar_carry: UInt64 = 0
    var out = out_start
    var offsets = (
        global_constant[_BIT_OFFSETS]().unsafe_ptr().unsafe_bitcast[UInt8]()
    )

    @__parameter
    @always_inline("nodebug")
    def emit(base_idx: UInt32, bits: UInt64):
        var base = SIMD[DType.uint32, 8](base_idx)
        comptime for j in range(8):
            var byte = Int((bits >> UInt64(8 * j)) & 0xFF)
            var offs = offsets.unsafe_offset((j * 256 + byte) * 8)
            out.unsafe_store(
                offs.unsafe_load[width=8]().cast[DType.uint32]() + base
            )
            out = out.unsafe_offset(Int(pop_count(UInt8(byte))))

    @__parameter
    @always_inline("nodebug")
    def step(input: SimdInput, base_idx: UInt32):
        var block = classify(input)
        var backslash = input.eq(UInt8(0x5C))
        var all_quotes = input.eq(UInt8(0x22))
        var escaped: UInt64
        if likely(backslash == 0):
            escaped = escape_scanner.next_is_escaped
            escape_scanner.next_is_escaped = 0
        else:
            escaped = escape_scanner.next(backslash)
            comptime if with_flags:
                _append_offsets(backslashes, base_idx, backslash)
        var in_string = string_scanner.next(all_quotes, escaped)
        var real_quotes = all_quotes & ~escaped

        var combined = structurals_from_masks(
            block.op,
            block.whitespace,
            real_quotes,
            in_string,
            prev_scalar_carry,
        )
        # Deferred by one chunk, as in the portable loop. Before the
        # first chunk prev_structurals is 0: the stores land on slots the
        # next emit overwrites and the cursor does not move.
        emit(base_idx - 64, prev_structurals)
        prev_structurals = combined[0]
        prev_scalar_carry = combined[1]

    # A padded input can load its final partial chunk in place.
    var full = (input_len + 63) // 64 if assume_padded else input_len // 64
    for i in range(full):
        step(SimdInput.load(ptr.unsafe_offset(i * 64)), UInt32(i * 64))
    comptime if not assume_padded:
        var rem = input_len - full * 64
        if rem > 0:
            # Stage the final partial chunk through a zeroed stack buffer
            # so the borrowed input is never read past input_len.
            var tail = Array[Byte, 64](fill=0)
            unsafe_memcpy(
                dest=tail.unsafe_ptr(),
                src=ptr.unsafe_offset(full * 64),
                count=rem,
            )
            step(SimdInput.load(tail.unsafe_ptr()), UInt32(full * 64))
            full += 1
    emit(UInt32(full * 64 - 64), prev_structurals)

    comptime if with_flags:
        if len(backslashes) != 0:
            flags |= INDEX_HAS_BACKSLASH

    # Same ascending-tail trim as the portable loop.
    var write_pos = (Int(out) - Int(out_start)) // 4
    while (
        write_pos > 0
        and Int(out_start[unsafe_offset=write_pos - 1]) >= input_len
    ):
        write_pos -= 1
    return write_pos
