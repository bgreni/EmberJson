from sys import simd_width_of


alias SIMD8_WIDTH = simd_width_of[Byte.dtype]()
alias SIMD8 = SIMD[Byte.dtype, _]
alias SIMD8xT = SIMD8[SIMD8_WIDTH]
alias SIMDBool = SIMD[DType.bool, _]
