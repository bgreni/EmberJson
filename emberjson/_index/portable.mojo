"""Target-agnostic stage-1 bit algebra shared by CPU scanners and GPU kernels.

Everything here is pure `UInt64` arithmetic or comptime data: no
`llvm_intrinsic` calls, no `pack_bits` (which crashes the Metal shader
compiler when lowered for Apple GPUs), no SIMD-width assumptions, and
everything interprets cleanly in the comptime interpreter. GPU modules
import shared math ONLY from this file so device codegen never sees
NEON-specific symbols; the CPU fast paths in `simd_ops.mojo` /
`classifier.mojo` are untouched and their portable branches delegate
here, so both engines compute from one formulation.

Byte -> mask *extraction* (loading 64 bytes and producing per-class
bitmasks) is deliberately NOT here: it is target-specific. The CPU uses
`SimdInput` + NEON tbl/addp or `pack_bits`; the GPU uses its own
extraction in `emberjson/_gpu/` built from verified-on-device ops.
"""

# --- Classifier data (single source of truth, shared with the GPU) -----
# Class-bit tables, indexed by a byte's low/high nibble. A byte's class
# descriptor is CLASSIFY_LOW_NIBBLE[b & 0xF] & CLASSIFY_HIGH_NIBBLE[b >> 4]:
#   ','  0x2C -> 1     ':'  0x3A -> 2     '[' ']' '{' '}' -> 4
#   ' '  0x20 -> 8     '\t' '\n' '\r'     -> 16
comptime CLASSIFY_LOW_NIBBLE = SIMD[DType.uint8, 16](
    8, 0, 0, 0, 0, 0, 0, 0, 0, 16, 18, 4, 1, 20, 0, 0
)
comptime CLASSIFY_HIGH_NIBBLE = SIMD[DType.uint8, 16](
    16, 0, 9, 2, 0, 4, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0
)
comptime CLASS_OP_BITS: UInt8 = 0x7
comptime CLASS_WS_BITS: UInt8 = 0x18


@always_inline("nodebug")
def prefix_xor_portable(bitmask: UInt64) -> UInt64:
    """Inclusive XOR-scan of a 64-bit mask (six shift-XOR Hillis-Steele
    steps). Bit-identical to the NEON PMULL formulation in
    `simd_ops.prefix_xor`, which delegates its portable branch here."""
    var x = bitmask
    x ^= x << 1
    x ^= x << 2
    x ^= x << 4
    x ^= x << 8
    x ^= x << 16
    x ^= x << 32
    return x


@always_inline("nodebug")
def escape_next(backslash: UInt64, prev_carry: UInt64) -> Tuple[UInt64, UInt64]:
    """Backslash bitmask + carry-in -> (escaped bitmask, carry-out in {0,1}).

    simdjson's `json_escape_scanner` formulation. Notably it masks the
    carried-in escaped byte out of the backslash mask before computing
    runs: a backslash that is itself escaped by the previous chunk cannot
    start a run, but the backslash after it starts a fresh one. (A naive
    run-start formulation gets that wrong — e.g. a `\\\\\\"` run
    straddling a 64-byte boundary — which a differential test against a
    scalar reference caught.)

    The carry-out depends on the carry-in, so on the GPU each chunk's
    transfer function is captured by evaluating this at carry-in 0 and 1
    (a 2-bit state composed associatively by the carry scan).
    """
    comptime ODD_BITS: UInt64 = 0xAAAAAAAAAAAAAAAA

    # A backslash escaped by the previous chunk cannot start a run.
    var potential_escape = backslash & ~prev_carry

    # Add-propagate odd-bit parity through the runs (wrapping
    # arithmetic): the bit after each odd-length run survives the XOR.
    var maybe_escaped = potential_escape << 1
    var maybe_escaped_and_odd = maybe_escaped | ODD_BITS
    var even_series_and_odd = maybe_escaped_and_odd - potential_escape
    var escape_and_terminal = even_series_and_odd ^ ODD_BITS

    var escaped = escape_and_terminal ^ (backslash | prev_carry)
    var escape = escape_and_terminal & backslash
    return (escaped, escape >> 63)


@always_inline("nodebug")
def string_next(
    quote: UInt64, escaped: UInt64, prev_in_string: UInt64
) -> Tuple[UInt64, UInt64]:
    """Quote + escaped masks + in-string carry word (0 or ~0) ->
    (in-string bitmask, next carry word).

    Portable formulation for GPU/comptime use; the CPU `StringScanner`
    keeps the identical three-line body on top of the NEON-dispatching
    `prefix_xor`. The quote-parity carry is bit 63 broadcast by
    arithmetic right shift."""
    var real_quotes = quote & ~escaped
    var in_string = prefix_xor_portable(real_quotes) ^ prev_in_string
    return (in_string, UInt64(Int64(Int(in_string)) >> 63))


@always_inline("nodebug")
def structurals_from_masks(
    op: UInt64,
    whitespace: UInt64,
    real_quotes: UInt64,
    in_string: UInt64,
    prev_scalar_carry: UInt64,
    valid_mask: UInt64 = UInt64.MAX,
) -> Tuple[UInt64, UInt64]:
    """Per-chunk structural combine -> (structurals, scalar carry-out).

    The exact algebra of the CPU indexer loop: structural operators
    outside strings, all real quotes, plus pseudo-structural scalar
    starts (first byte of numbers / true / false / null).

    `valid_mask` clears bits at and beyond a segment's content end (GPU
    segmented mode, where trailing bytes belong to the next line or the
    padding). The CPU passes all-ones and relies on its ascending-tail
    trim instead; with all-ones the AND folds away and the result is
    bit-identical to the historical inline body.
    """
    var structural_ops = (op & ~in_string) | real_quotes
    var scalar = ~(whitespace | op | real_quotes | in_string) & valid_mask
    var scalar_start = scalar & ~((scalar << 1) | prev_scalar_carry)
    return (structural_ops | scalar_start, (scalar >> 63) & 1)
