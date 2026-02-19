import mojo.importer
import sys

sys.path.insert(0, "")

from emberjson_python import parse, minify, Value
from time import perf_counter
import json

s: str

with open("./bench_data/data/canada.json") as f:
    s = f.read()

start = perf_counter()
res = parse(s)

print("EmberJSON: ", (perf_counter() - start) * 1000, "\n\n")

start = perf_counter()
res = json.loads(s)

print("Python stdlib:", (perf_counter() - start) * 1000, "\n\n")
