"""Stage-1 character classifier: 64 bytes -> whitespace + operator masks.

Ported from simdjson. `classify` turns one 64-byte `SimdInput`
chunk into a `CharacterBlock` of two 64-bit masks — one bit per byte.

Byte-shuffle path (`HAS_BYTE_SHUFFLE` targets, guarded by
`__is_run_in_comptime_interpreter`): simdjson's low/high-nibble
shuffle-table intersection — two table lookups (TBL1 / VPSHUFB) and an
AND give every byte a class descriptor in one pass, then one movemask
per class. One kernel serves NEON and AVX2: it runs over `SimdInput`'s
`_N_CHUNKS` vectors of `KERNEL_WIDTH` bytes, so the wider target does
half as many shuffles and movemasks without a separate code path.
Class bits: comma=1, colon=2, brackets/braces=4
(operator = desc & 0x7), space=8, tab/lf/cr=16 (whitespace =
desc & 0x18). The tables are constructed so `low[b & 15] & high[b >> 4]`
is non-zero for exactly the ten classified bytes;
`test_classifier_exhaustive` verifies all 256 byte values.

Portable/comptime path: parallel equality compares (six operators, four
whitespace), which interpret cleanly at compile time. No per-byte
branching in either path.
"""

from emberjson.simd import HAS_BYTE_SHUFFLE, lookup, SIMD8
from .portable import (
    CLASSIFY_LOW_NIBBLE,
    CLASSIFY_HIGH_NIBBLE,
    CLASS_OP_BITS,
    CLASS_WS_BITS,
)
from .simd_ops import SimdInput, movemask64, _CW, _N_CHUNKS, _Chunk, _BoolC


@fieldwise_init
struct CharacterBlock(Copyable, Movable):
    """Whitespace and structural-operator bitmasks for a 64-byte chunk."""

    var whitespace: UInt64
    var op: UInt64


# Class-bit tables live in `portable.mojo`, indexed by a byte's low/high
# nibble. A byte's class descriptor is LOW[b & 0xF] & HIGH[b >> 4]:
#   ','  0x2C -> 1     ':'  0x3A -> 2     '[' ']' '{' '}' -> 4
#   ' '  0x20 -> 8     '\t' '\n' '\r'     -> 16


@always_inline("nodebug")
def _classify_desc[W: Int](v: SIMD8[W]) -> SIMD8[W]:
    """Each byte's class descriptor: LOW[b & 0xF] & HIGH[b >> 4].

    Non-zero for exactly the ten classified bytes; `& CLASS_OP_BITS`
    selects operators and `& CLASS_WS_BITS` selects whitespace.
    Parameterized on width so it can be tested at widths other than the
    one this build ships.
    """
    return lookup[W](CLASSIFY_LOW_NIBBLE, v & SIMD8[W](0xF)) & lookup[W](
        CLASSIFY_HIGH_NIBBLE, v >> 4
    )


@always_inline("nodebug")
def _classify_shuffle(input: SimdInput) -> CharacterBlock:
    comptime ZERO = _Chunk(0)
    comptime OP_BITS = _Chunk(CLASS_OP_BITS)
    comptime WS_BITS = _Chunk(CLASS_WS_BITS)

    var ops = Array[_BoolC, _N_CHUNKS](fill=_BoolC(fill=False))
    var wss = Array[_BoolC, _N_CHUNKS](fill=_BoolC(fill=False))
    comptime for i in range(_N_CHUNKS):
        var d = _classify_desc[_CW](input.chunks[i])
        ops[i] = (d & OP_BITS).ne(ZERO)
        wss[i] = (d & WS_BITS).ne(ZERO)
    return CharacterBlock(whitespace=movemask64(wss), op=movemask64(ops))


@always_inline("nodebug")
def classify(input: SimdInput) -> CharacterBlock:
    """Classifies 64 bytes into whitespace and structural-operator masks."""
    comptime if HAS_BYTE_SHUFFLE:
        if not __is_run_in_comptime_interpreter:
            return _classify_shuffle(input)

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
