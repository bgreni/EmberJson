"""Stage-1 character classifier: 64 bytes -> whitespace + operator masks.

Ported from simdjson. `classify` turns one 64-byte `SimdInput`
chunk into a `CharacterBlock` of two 64-bit masks — one bit per byte.

NEON / x86 paths (guarded by `__is_run_in_comptime_interpreter`):
simdjson's low/high-nibble shuffle-table intersection — two table
lookups (TBL1 / VPSHUFB) and an AND give every byte a class descriptor
in one pass, then one movemask per class. On AVX2 the four 16-byte
chunks recombine into two 32-byte vectors first, halving the shuffle
and movemask count. Class bits: comma=1, colon=2, brackets/braces=4
(operator = desc & 0x7), space=8, tab/lf/cr=16 (whitespace =
desc & 0x18). The tables are constructed so `low[b & 15] & high[b >> 4]`
is non-zero for exactly the ten classified bytes;
`test_classifier_exhaustive` verifies all 256 byte values.

Portable/comptime path: parallel equality compares (six operators, four
whitespace), which interpret cleanly at compile time. No per-byte
branching in either path.
"""

from std.memory import pack_bits

from .portable import CLASSIFY_LOW_NIBBLE, CLASSIFY_HIGH_NIBBLE
from .simd_ops import (
    SimdInput,
    movemask64,
    lookup16,
    lookup16_x2,
    _NEON,
    _AVX2,
    _Chunk16,
    _Chunk32,
)


@fieldwise_init
struct CharacterBlock(Copyable, Movable):
    """Whitespace and structural-operator bitmasks for a 64-byte chunk."""

    var whitespace: UInt64
    var op: UInt64


# Class-bit tables (see `portable.mojo`, shared with the GPU kernels),
# indexed by a byte's low/high nibble. A byte's class descriptor is
# LOW[b & 0xF] & HIGH[b >> 4]:
#   ','  0x2C -> 1     ':'  0x3A -> 2     '[' ']' '{' '}' -> 4
#   ' '  0x20 -> 8     '\t' '\n' '\r'     -> 16
comptime _LOW_NIBBLE = CLASSIFY_LOW_NIBBLE
comptime _HIGH_NIBBLE = CLASSIFY_HIGH_NIBBLE


@always_inline("nodebug")
def _classify_avx2(input: SimdInput) -> CharacterBlock:
    comptime LOW_MASK = _Chunk32(0xF)
    comptime ZERO = _Chunk32(0)
    comptime OP_BITS = _Chunk32(0x7)
    comptime WS_BITS = _Chunk32(0x18)

    var lo = input.lo32()
    var hi = input.hi32()
    var d0 = lookup16_x2(_LOW_NIBBLE, lo & LOW_MASK) & lookup16_x2(
        _HIGH_NIBBLE, lo >> 4
    )
    var d1 = lookup16_x2(_LOW_NIBBLE, hi & LOW_MASK) & lookup16_x2(
        _HIGH_NIBBLE, hi >> 4
    )

    var op = (
        UInt64(pack_bits((d0 & OP_BITS).ne(ZERO)))
        | UInt64(pack_bits((d1 & OP_BITS).ne(ZERO))) << 32
    )
    var ws = (
        UInt64(pack_bits((d0 & WS_BITS).ne(ZERO)))
        | UInt64(pack_bits((d1 & WS_BITS).ne(ZERO))) << 32
    )
    return CharacterBlock(whitespace=ws, op=op)


@always_inline("nodebug")
def _classify_neon(input: SimdInput) -> CharacterBlock:
    comptime LOW_MASK = _Chunk16(0xF)
    comptime ZERO = _Chunk16(0)
    comptime OP_BITS = _Chunk16(0x7)
    comptime WS_BITS = _Chunk16(0x18)

    var d0 = lookup16(_LOW_NIBBLE, input.chunks[0] & LOW_MASK) & lookup16(
        _HIGH_NIBBLE, input.chunks[0] >> 4
    )
    var d1 = lookup16(_LOW_NIBBLE, input.chunks[1] & LOW_MASK) & lookup16(
        _HIGH_NIBBLE, input.chunks[1] >> 4
    )
    var d2 = lookup16(_LOW_NIBBLE, input.chunks[2] & LOW_MASK) & lookup16(
        _HIGH_NIBBLE, input.chunks[2] >> 4
    )
    var d3 = lookup16(_LOW_NIBBLE, input.chunks[3] & LOW_MASK) & lookup16(
        _HIGH_NIBBLE, input.chunks[3] >> 4
    )

    var op = movemask64(
        (d0 & OP_BITS).ne(ZERO),
        (d1 & OP_BITS).ne(ZERO),
        (d2 & OP_BITS).ne(ZERO),
        (d3 & OP_BITS).ne(ZERO),
    )
    var ws = movemask64(
        (d0 & WS_BITS).ne(ZERO),
        (d1 & WS_BITS).ne(ZERO),
        (d2 & WS_BITS).ne(ZERO),
        (d3 & WS_BITS).ne(ZERO),
    )
    return CharacterBlock(whitespace=ws, op=op)


@always_inline("nodebug")
def classify(input: SimdInput) -> CharacterBlock:
    """Classifies 64 bytes into whitespace and structural-operator masks."""
    comptime if _NEON:
        if not __is_run_in_comptime_interpreter:
            return _classify_neon(input)
    comptime if _AVX2:
        if not __is_run_in_comptime_interpreter:
            return _classify_avx2(input)

    var op_brace_open = input.eq(UInt8(0x7B))  # {
    var op_brace_close = input.eq(UInt8(0x7D))  # }
    var op_bracket_open = input.eq(UInt8(0x5B))  # [
    var op_bracket_close = input.eq(UInt8(0x5D))  # ]
    var op_colon = input.eq(UInt8(0x3A))  # :
    var op_comma = input.eq(UInt8(0x2C))  # ,
    var op_combined = (
        op_brace_open
        | op_brace_close
        | op_bracket_open
        | op_bracket_close
        | op_colon
        | op_comma
    )

    var ws_space = input.eq(UInt8(0x20))
    var ws_tab = input.eq(UInt8(0x09))
    var ws_lf = input.eq(UInt8(0x0A))
    var ws_cr = input.eq(UInt8(0x0D))
    var ws_combined = ws_space | ws_tab | ws_lf | ws_cr

    return CharacterBlock(whitespace=ws_combined, op=op_combined)
