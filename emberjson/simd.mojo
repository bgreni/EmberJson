from sys import simdwidthof


alias SIMD8_WIDTH = simdwidthof[DType.uint8]()
alias SIMD8 = SIMD[DType.uint8, _]
alias SIMD8xT = SIMD8[SIMD8_WIDTH]

alias SIMDBool = SIMD[DType.bool, _]

alias SIMDu64 = SIMD[DType.uint64, _]
