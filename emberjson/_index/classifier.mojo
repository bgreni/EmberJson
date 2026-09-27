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

x86 path (`_X86_PSHUFB`, AVX2 targets): simdjson's haswell
formulation, which leans on raw VPSHUFB semantics (index by the low
nibble, zero when bit 7 is set) to classify with an exact-match table
instead of the nibble-descriptor intersection. That is roughly half the
vector ops per 32 bytes, and it is x86-only: NEON's TBL zeroes indexes
>= 16 rather than masking them, so aarch64 keeps the descriptor kernel.

Portable/comptime path: parallel equality compares (six operators, four
whitespace), which interpret cleanly at compile time. No per-byte
branching in any path.
"""

from std.sys.info import CompilationTarget
from std.sys.intrinsics import llvm_intrinsic
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


# --- x86 exact-match kernel ---------------------------------------------
comptime _X86_PSHUFB = CompilationTarget.has_avx2() and _CW == 32


def _x86_table(t: SIMD8[16]) -> _Chunk:
    # VPSHUFB looks up within each 128-bit half, so the table is tiled.
    return rebind[_Chunk](t.join(t))


def _exact_match(bytes: List[Int]) -> _Chunk:
    """The table T with T[b & 0xF] = b for each listed byte and 0xFF
    elsewhere, so `pshufb(T, v) == v` holds exactly for the listed bytes.
    0xFF never matches: a byte below 0x80 is never 0xFF, and a byte with
    bit 7 set looks up 0. The listed bytes need distinct low nibbles."""
    var t = SIMD8[16](0xFF)
    for b in bytes:
        t[b & 0xF] = UInt8(b)
    return _x86_table(t)


comptime _WS_EXACT = _exact_match([0x20, 0x09, 0x0A, 0x0D])
# b is an operator iff (b | CURLY[b & 0xF]) == OP[b & 0xF]. CURLY folds
# `[` `]` onto `{` `}` (they differ only in bit 5). simdjson ORs 0x20 into
# every byte instead, which also maps 0x0C onto `,` and 0x1A onto `:`;
# confining the OR to the two bracket nibbles keeps the masks exact.
comptime _OP_EXACT = _exact_match([0x3A, 0x7B, 0x2C, 0x7D])
comptime _CURLY = _x86_table(
    SIMD8[16](0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20, 0, 0x20, 0, 0)
)


@always_inline("nodebug")
def _pshufb(table: _Chunk, idx: _Chunk) -> _Chunk:
    """Raw VPSHUFB. Deliberately not `lookup`: the exact-match tables
    need its x86 semantics for lanes >= 16, which `lookup` leaves
    unspecified."""
    return llvm_intrinsic["llvm.x86.avx2.pshuf.b", _Chunk](table, idx)


@always_inline("nodebug")
def _classify_pshufb(input: SimdInput) -> CharacterBlock:
    var ops = Array[_BoolC, _N_CHUNKS](fill=_BoolC(fill=False))
    var wss = Array[_BoolC, _N_CHUNKS](fill=_BoolC(fill=False))
    comptime for i in range(_N_CHUNKS):
        var v = input.chunks[i]
        wss[i] = _pshufb(_WS_EXACT, v).eq(v)
        ops[i] = _pshufb(_OP_EXACT, v).eq(v | _pshufb(_CURLY, v))
    return CharacterBlock(whitespace=movemask64(wss), op=movemask64(ops))


@always_inline("nodebug")
def classify(input: SimdInput) -> CharacterBlock:
    """Classifies 64 bytes into whitespace and structural-operator masks."""
    comptime if _X86_PSHUFB:
        if not __is_run_in_comptime_interpreter:
            return _classify_pshufb(input)
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
