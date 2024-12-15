from sys import simdwidthof


alias SIMD8_WIDTH = simdwidthof[DType.uint8]()
alias SIMD8 = SIMD[DType.uint8, _]
alias SIMD8xT = SIMD8[SIMD8_WIDTH]

alias SIMDBool = SIMD[DType.bool, _]

alias SIMDu64 = SIMD[DType.uint64, _]

# fn u64_from_bits[Size: Int,//](out out: UInt64, v: SIMD[DType.bool, Size]):
#     constrained[Size <= 64, "SIMDBool size must fit in 64 bits"]()

#     out = 0

#     @parameter
#     for i in range(Size):
#         out += int(v[i]) << (Size - i - 1)
