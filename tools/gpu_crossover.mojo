"""Scale crossover measurement: CPU vs GPU engines at 11MB / 100MB /
400MB, single-document and batch. Min-of-3, whole-pipeline wall clock.

Usage (after `pixi run gen_large`):
    pixi run mojo build -I . tools/gpu_crossover.mojo -o /tmp/crossover
    /tmp/crossover single bench_data/large/single_420mb.json
    /tmp/crossover batch  bench_data/large/batch_400mb.jsonl
    /tmp/crossover index  bench_data/large/single_420mb.json
Engines filter (3rd arg): c=cpu g=gpu-default s=gpu-stage2
"""

from emberjson import (
    GpuSession,
    ParseOptions,
    parse_document,
    try_parse_document,
)
from std.pathlib import Path
from std.sys import argv, has_accelerator
from std.time import perf_counter_ns


def _report(name: String, best_ns: UInt64, n: Int):
    var ms = Float64(best_ns) / 1e6
    var gbs = Float64(n) / Float64(best_ns)
    print("  ", name, ":", ms, "ms /", gbs, "GB/s")


def bench_single(data: String, engines: String) raises:
    var n = data.byte_length()
    comptime if has_accelerator():
        var s = GpuSession()
        if "g" in engines:
            var best = UInt64.MAX
            for _ in range(3):
                var t0 = perf_counter_ns()
                var d = s.parse_document(data)
                var t1 = perf_counter_ns()
                if UInt64(t1 - t0) < best:
                    best = UInt64(t1 - t0)
                _ = d^
            _report("gpu-default single", best, n)
        if "s" in engines:
            var best = UInt64.MAX
            for _ in range(3):
                var t0 = perf_counter_ns()
                var d = s.parse_document[ParseOptions(), True](data)
                var t1 = perf_counter_ns()
                if UInt64(t1 - t0) < best:
                    best = UInt64(t1 - t0)
                _ = d^
            _report("gpu-stage2  single", best, n)
    if "c" in engines:
        var best = UInt64.MAX
        for _ in range(3):
            var t0 = perf_counter_ns()
            var d = parse_document(data)
            var t1 = perf_counter_ns()
            if UInt64(t1 - t0) < best:
                best = UInt64(t1 - t0)
            _ = d^
        _report("cpu         single", best, n)


def bench_index(data: String) raises:
    """cuJSON-equivalent deliverable: full structural index + token
    types + bracket pairs + validation (no tape/values — that is what
    cuJSON's 'parse' produces)."""
    var n = data.byte_length()
    comptime if has_accelerator():
        var s = GpuSession()
        comptime opts = ParseOptions(validate_utf8=False)
        var best = UInt64.MAX
        var oc = 0
        for _ in range(3):
            var t0 = perf_counter_ns()
            var positions = s._structural_index_gpu[opts](data.as_bytes())
            var total = len(positions) - 3
            s._tokenize_only[opts](total, 1)
            var r = s._match_brackets(total)
            var t1 = perf_counter_ns()
            if UInt64(t1 - t0) < best:
                best = UInt64(t1 - t0)
            oc = r[0]
            _ = positions^
        _report("gpu index+pairs   ", best, n)
        print("    containers paired:", oc)


def bench_batch(data: String, engines: String) raises:
    var n = data.byte_length()
    comptime if has_accelerator():
        var s = GpuSession()
        if "g" in engines:
            var best = UInt64.MAX
            for _ in range(3):
                var t0 = perf_counter_ns()
                var docs = s.parse_documents(data)
                var t1 = perf_counter_ns()
                if UInt64(t1 - t0) < best:
                    best = UInt64(t1 - t0)
                _ = docs^
            _report("gpu-default batch", best, n)
        if "s" in engines:
            var best = UInt64.MAX
            for _ in range(3):
                var t0 = perf_counter_ns()
                var docs = s.parse_documents[ParseOptions(), True](data)
                var t1 = perf_counter_ns()
                if UInt64(t1 - t0) < best:
                    best = UInt64(t1 - t0)
                _ = docs^
            _report("gpu-stage2  batch", best, n)
    if "c" in engines:
        var best = UInt64.MAX
        for _ in range(3):
            var count = 0
            var bytes = data.as_bytes()
            var t0 = perf_counter_ns()
            var line_start = 0
            var i = 0
            while i <= n:
                if i == n or bytes[i] == 0x0A:
                    if i > line_start:
                        var line = StringSlice(
                            unsafe_from_utf8=Span(
                                ptr=bytes.unsafe_ptr() + line_start,
                                length=i - line_start,
                            )
                        )
                        var d = try_parse_document(line)
                        if d:
                            count += 1
                    line_start = i + 1
                i += 1
            var t1 = perf_counter_ns()
            if UInt64(t1 - t0) < best:
                best = UInt64(t1 - t0)
            _ = count
        _report("cpu 1-core  batch", best, n)


def main() raises:
    var args = argv()
    var mode = String(args[1])
    var path = String(args[2])
    var engines = String(args[3]) if len(args) > 3 else String("cgs")
    var data = Path(path).read_text()
    print(path, "(", data.byte_length() // (1024 * 1024), "MB )")
    if mode == "index":
        bench_index(data)
    elif mode == "single":
        bench_single(data, engines)
    else:
        bench_batch(data, engines)
