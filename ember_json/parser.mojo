# from .utils import *
# from .string_reader import Reader
# from .json import JSON
# from .simd import *
# from .array import Array
# from .object import Object
# from .value import Value

# struct Parser[origin: ImmutableOrigin, //]:
#     var reader: Reader[origin]

#     fn __init__(out self, b: ByteView[origin]):
#         self.reader = Reader(b)
    
#     fn parse(mut self) -> JSON:

#         self.reader.skip_whitespace()
#         var n = self.reader.peek()
#         if n == LCURLY:
#             return self.parse_array()
#         elif n == LBRACKET:
#             return self.parse_object()
#         else:
#             raise Error("Invalid json")

#     fn parse_array(mut self) -> Array:
#         pass

#     fn parse_object(mut self) -> Object:
#         pass

        

