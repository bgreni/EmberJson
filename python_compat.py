import mojo.importer
import sys

sys.path.insert(0, "")

from emberjson_python import parse, minify
from time import perf_counter
import json

s: str

# s = r"""{
#     "key": [
#         1.234,
#         352.329384920,
#         123412512,
#         -12234,
#         true,
#         false,
#         null,
#         "shortstr",
#         "longer string that would trigger simd code usually but can't be invoked at ctime",
#         "string that has unicode in it: \u00FC"
#     ]
# }"""


with open("./bench_data/data/canada.json") as f:
    s = f.read()

start = perf_counter()
res = parse(s)

print((perf_counter() - start) * 1000, "\n\n")

start = perf_counter()
res = json.loads(s)

print((perf_counter() - start) * 1000, "\n\n")
