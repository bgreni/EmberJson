"""Stage-1 string masking: which bytes are escaped / inside strings.

Ported from simdjson. Two carry-carrying scanners run per 64-byte
chunk and thread their state across chunk boundaries, so a backslash run or
an open string spanning a 64-byte edge is handled correctly:

  * `EscapeScanner.next` turns a backslash bitmask into an "escaped"
    bitmask using simdjson's odd-bits parity trick (a byte is escaped iff
    it follows an odd-length run of backslashes).
  * `StringScanner.next` turns the real (non-escaped) quote bitmask into an
    "in-string" bitmask via a prefix-XOR over quotes, carrying the
    open/closed polarity into the next chunk.

The in-string mask is what lets the indexer exclude string content from
structural-character detection. No per-byte branching.
"""

from .portable import escape_next
from .simd_ops import prefix_xor


struct EscapeScanner:
    """Marks bytes that follow an odd-length run of backslashes."""

    var next_is_escaped: UInt64

    def __init__(out self):
        self.next_is_escaped = 0

    @always_inline("nodebug")
    def next(mut self, backslash: UInt64) -> UInt64:
        """Given a backslash bitmask, returns the escaped-byte bitmask.

        The formulation (simdjson's `json_escape_scanner`, with its
        subtle carried-escape handling) lives in `portable.escape_next`,
        shared with the GPU kernels; this scanner just threads the carry
        across chunks.
        """
        var r = escape_next(backslash, self.next_is_escaped)
        self.next_is_escaped = r[1]
        return r[0]


struct StringScanner:
    """Computes the in-string bitmask via prefix_xor over real quotes."""

    var prev_in_string: UInt64

    def __init__(out self):
        self.prev_in_string = 0

    @always_inline("nodebug")
    def next(mut self, quote: UInt64, escaped: UInt64) -> UInt64:
        """Returns the in-string bitmask (between quotes, exclusive).

        Same three-line body as `portable.string_next`, kept separate so
        this hot path uses the NEON-dispatching `prefix_xor` (PMULL)
        rather than the portable shift-XOR chain."""
        var real_quotes = quote & ~escaped
        var in_string = prefix_xor(real_quotes) ^ self.prev_in_string
        # Arithmetic right-shift of bit 63 broadcasts the carry (0 or ~0).
        self.prev_in_string = UInt64(Int64(Int(in_string)) >> 63)
        return in_string
