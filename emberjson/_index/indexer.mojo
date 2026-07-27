"""Stage-1 indexer: the chunk loop that emits structural character positions.

Ported from simdjson. `structural_index` walks the input 64 bytes
at a time; for each chunk it combines the classifier's operator/whitespace
masks with the string-mask scanners to compute that chunk's structural
bits: structural operators outside strings, every real (non-escaped)
quote, and pseudo-structural scalar starts (the first byte of a number or
`true`/`false`/`null`). Set bits are scattered into the caller's reusable
`positions` buffer by a branchless 8-at-a-time `emit` that trades a small
over-write tail for removing the per-structural mispredicted branch.

Output is deferred by one chunk so cross-chunk carries settle, and the
spurious tail produced by the final chunk's zero bytes is trimmed at the
end. On exit, `len(positions)` equals the true structural count.

Unlike simdjson, the input need not be a padded copy: with
`assume_padded=False` the final partial chunk is copied into a zeroed
64-byte stack buffer, so the caller's original (borrowed) input can be
indexed without any heap copy. `assume_padded=True` requires a
`PaddedBuffer`-backed input and loads every chunk directly.
"""

from std.bit import count_trailing_zeros, pop_count
from std.memory import unsafe_memcpy

from emberjson.utils import BytePtr
from .simd_ops import SimdInput
from .classifier import classify, CharacterBlock
from .portable import structurals_from_masks
from .string_mask import EscapeScanner, StringScanner


def structural_index[
    assume_padded: Bool
](ptr: BytePtr, input_len: Int, mut positions: List[UInt32]):
    """Fills `positions` with the offsets of every structural character.

    Structural characters are `{ } [ ] : ,`, both quotes of every string
    (in-string and escaped quotes are masked out), and the first byte of
    every scalar token. Positions are strictly ascending.

    The buffer is reused across calls: it is only (re)allocated when its
    capacity cannot hold the worst case of one structural per input byte
    (capacity-based, because this function resizes `positions` down to the
    structural count on exit, so a warm buffer has a small length but a
    large capacity).

    Parameters:
        assume_padded: The input is backed by a `PaddedBuffer` and whole
            64-byte chunks may always be loaded. Otherwise the final
            partial chunk is staged through a zeroed stack buffer and the
            input is never read past `input_len`.

    Args:
        ptr: Start of the JSON input.
        input_len: Length of the JSON input in bytes.
        positions: Caller-owned, reusable output buffer. Filled with
            structural offsets and resized to the structural count.
    """
    if input_len == 0:
        positions.resize(0, UInt32(0))
        return

    # Worst case is one structural per byte. The branchless 8-at-a-time
    # emit can over-write up to 7 entries past the true count, so the
    # buffer carries EMIT_SLACK extra slots; those over-writes are never
    # read.
    comptime EMIT_SLACK = 8
    if positions.capacity() < input_len + EMIT_SLACK:
        positions.reserve(input_len + EMIT_SLACK)
    # Length must cover the raw-pointer write phase.
    positions.resize(unsafe_uninit_length=input_len + EMIT_SLACK)

    var num_chunks = (input_len + 63) // 64

    var escape_scanner = EscapeScanner()
    var string_scanner = StringScanner()

    var prev_structurals: UInt64 = 0
    var prev_scalar_carry: UInt64 = 0
    var prev_base: UInt32 = 0

    # Deliberately an `UnsafePointer`: the emit loop writes up to 7 slots past
    # the true structural count (covered by `EMIT_SLACK`), so it wants raw
    # offset indexing rather than the bounds-tracked `Pointer` `List` vends.
    var out_ptr: UnsafePointer[
        UInt32, origin_of(positions)
    ] = positions.unsafe_ptr()
    var write_pos = 0

    @parameter
    @always_inline("nodebug")
    def emit(base_idx: UInt32, bits: UInt64):
        """Writes the offset of each set bit into `positions`.

        Branchless 8-at-a-time scatter (simdjson AVX2-kernel style): each
        iteration writes 8 indices unconditionally, but `write_pos`
        advances only by the true popcount. The spurious tail (<8 entries,
        where count_trailing_zeros(0)==64) is overwritten by the next emit
        or lands in EMIT_SLACK and is never read. This removes the
        per-set-bit branch (one mispredict per structural character).
        """
        if bits == 0:
            return
        var cnt = Int(pop_count(bits))
        var b = bits
        var w = write_pos
        var done = 0
        while done < cnt:
            out_ptr[w + 0] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 1] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 2] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 3] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 4] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 5] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 6] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            out_ptr[w + 7] = base_idx + UInt32(count_trailing_zeros(b))
            b = b & (b - 1)
            w += 8
            done += 8
        write_pos += cnt

    for chunk_idx in range(num_chunks):
        var base_idx = UInt32(chunk_idx * 64)
        var input: SimdInput
        comptime if assume_padded:
            input = SimdInput.load(ptr + Int(base_idx))
        else:
            if Int(base_idx) + 64 <= input_len:
                input = SimdInput.load(ptr + Int(base_idx))
            else:
                # Final partial chunk: stage through a zeroed stack buffer
                # so the borrowed input is never read past input_len.
                var tail = InlineArray[Byte, 64](fill=0)
                unsafe_memcpy(
                    dest=tail.unsafe_ptr(),
                    src=ptr + Int(base_idx),
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

    # Positions are emitted in strictly ascending order, so any position
    # >= input_len — spurious structurals from the final chunk's zero
    # bytes — forms a contiguous tail. Trim it.
    while write_pos > 0 and Int(out_ptr[write_pos - 1]) >= input_len:
        write_pos -= 1
    positions.resize(write_pos, UInt32(0))
