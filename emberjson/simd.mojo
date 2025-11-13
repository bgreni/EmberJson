from sys import simd_width_of


comptime SIMD8_WIDTH = simd_width_of[Byte.dtype]()
comptime SIMD8 = SIMD[Byte.dtype, _]
comptime SIMD8xT = SIMD8[SIMD8_WIDTH]
comptime SIMDBool = SIMD[DType.bool, _]
