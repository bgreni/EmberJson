from sys import simdwidthof


alias SIMD8_WIDTH = simdwidthof[Byte.dtype]()
alias SIMD8 = SIMD[Byte.dtype, _]
alias SIMD8xT = SIMD8[SIMD8_WIDTH]
alias SIMDBool = SIMD[DType.bool, _]
