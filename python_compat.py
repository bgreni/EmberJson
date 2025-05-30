import max._mojo.mojo_importer
import os
import sys

sys.path.insert(0, "")
os.environ["MOJO_PYTHON_LIBRARY"] = ""

from emberjson_python import parse, minify
from time import perf_counter
import json

s: str

s = r"""{
    "key": [
        1.234,
        352.329384920,
        123412512,
        -12234,
        true,
        false,
        null,
        "shortstr",
        "longer string that would trigger simd code usually but can't be invoked at ctime",
        "string that has unicode in it: \u00FC"
    ]
}"""


# with open('./bench_data/data/citm_catalog.json') as f:
#     s = f.read()

start = perf_counter()
res = parse(s)

print(perf_counter() - start, '\n\n')

start = perf_counter()
res = json.loads(s)

print(perf_counter() - start, '\n\n')