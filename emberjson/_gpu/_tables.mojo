"""Register-resident 16-entry byte-table lookup for the GPU kernels.

`SIMD._dynamic_shuffle` is the obvious spelling for a nibble-indexed
table lookup, and it is correct on every backend — but on NVIDIA it is
also a performance trap. Its own docstring describes it as "an unrolled
for loop": PTX has no 16-byte shuffle instruction, so the comptime table
gets materialized in *local memory* and each lane does a data-dependent
byte gather from it.

Measured on sm_86, `classify_kernel[validate_utf8=True]` (the default
parse path) against the same kernel with UTF-8 off:

    UTF-8 off:  1027 instrs,   64 B local depot,   0 stack stores
    UTF-8 on:   4497 instrs, 3216 B local depot, 788 stack stores

Turning validation on made the kernel 4.4x larger and added 788
local-memory stores per thread — for 184K threads that is hundreds of MB
of local traffic to validate 11 MB of input.

`prmt` (exposed as `byte_permute`) selects four bytes out of eight source
bytes in a single instruction. Two of them cover a 16-entry table, and a
per-byte blend on bit 3 of the index picks the right half — all in
registers, no memory. Same values as `_dynamic_shuffle`, so the
validator's verdicts are unchanged.
"""

from std.gpu.intrinsics import byte_permute
from std.memory import bitcast
from std.sys.info import is_nvidia_gpu

comptime _C16 = SIMD[DType.uint8, 16]


@always_inline
def tbl16(table: _C16, idx: _C16) -> _C16:
    """`table[idx[i]]` per lane, for a 16-entry table and nibble indices.

    Indices must be < 16; callers feed nibbles, so that holds by
    construction.
    """
    comptime if is_nvidia_gpu():
        var t = bitcast[DType.uint32, 4](table)
        var ix = bitcast[DType.uint32, 4](idx)
        var out = SIMD[DType.uint32, 4](0)

        comptime for k in range(4):
            var n = ix[k]
            # `prmt` selects from the eight bytes of {a, b} by the low
            # three bits of each control nibble, so mask the index down
            # and run both halves of the table.
            #
            # The control word packs its four selectors as NIBBLES in the
            # low 16 bits, while `n` holds them one per byte — so squeeze
            # bytes 0/1/2/3 down into nibbles 0/1/2/3 first. (Passing the
            # byte-packed form straight through reads garbage selectors
            # and silently returns wrong table entries.)
            var b = n & 0x07070707
            var sel = (
                (b & 0xF)
                | ((b >> 4) & 0xF0)
                | ((b >> 8) & 0xF00)
                | ((b >> 12) & 0xF000)
            )
            var lo = byte_permute(t[0], t[1], sel)  # entries 0-7
            var hi = byte_permute(t[2], t[3], sel)  # entries 8-15
            # Bit 3 of each index byte says which half won. `* 0xFF`
            # widens the per-byte 0/1 to 0x00/0xFF without carrying
            # across byte lanes (1 * 255 still fits in a byte).
            var m = ((n & 0x08080808) >> 3) * 0xFF
            out[k] = (hi & m) | (lo & ~m)

        return bitcast[DType.uint8, 16](out)
    else:
        # Metal: `_dynamic_shuffle` crashes the shader compiler, so the
        # per-lane extract stays the portable path.
        var r = _C16(0)
        comptime for i in range(16):
            r[i] = table[Int(idx[i])]
        return r
