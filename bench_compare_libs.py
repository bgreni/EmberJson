#!/usr/bin/env python3
"""Throughput of Python JSON libraries on EmberJson's bench files, in the same
unit bench.mojo reports (GB/s = input bytes / best-of-N wall time), so the two
tables can sit side by side.  Run from the repo root:

    python bench_compare_libs.py            # stdlib json only
    pip install orjson pysimdjson           # optional columns

Numbers are single-machine and single-process; compare ratios, not absolutes,
against another host's bench_result.txt.
"""
import json, sys, time
from pathlib import Path

ITERS = 100
FILES = {"Twitter": "twitter.json", "CitmCatalog": "citm_catalog.json", "Canada": "canada.json"}
DATA = Path("bench_data/data")

libs = {"json": (json.loads, lambda o: json.dumps(o, separators=(",", ":")))}
try:
    import orjson
    libs["orjson"] = (orjson.loads, orjson.dumps)
except ImportError:
    pass
try:
    import simdjson
    _p = simdjson.Parser()
    libs["simdjson(loads)"] = (simdjson.loads, None)
    libs["simdjson(lazy)"] = (lambda b: _p.parse(b), None)  # no materialisation; compare with *Doc/Lazy rows
except ImportError:
    pass


def best(fn, arg):
    t = float("inf")
    for _ in range(ITERS):
        t0 = time.perf_counter(); fn(arg); t = min(t, time.perf_counter() - t0)
    return t


rows = []
for name, fname in FILES.items():
    raw = (DATA / fname).read_bytes()
    n = len(raw)
    for lib, (loads, dumps) in libs.items():
        rows.append((f"Parse{name}", lib, n / best(loads, raw) / 1e9))
        if dumps is not None:
            obj = json.loads(raw)
            out = dumps(obj)
            rows.append((f"Stringify{name}", lib, len(out) / best(dumps, obj) / 1e9))

print(f"| benchmark | library | GB/s |\n|---|---|---|")
for b, lib, gbs in rows:
    print(f"| {b} | {lib} | {gbs:.3f} |")
print(f"\npython {sys.version.split()[0]}, {ITERS} iters, best-of-N", file=sys.stderr)
