from emberjson import Parser
from std.benchmark import (
    Bench,
    BenchId,
    Bencher,
    keep,
    BenchMetric,
    BenchConfig,
)
from std.collections import List, Dict
from std.python import Python

comptime BenchResults = Dict[String, Float64]
comptime iters = 1_000_000


@parameter
def bench_emberjson(mut b: Bencher, val: String) raises:
    @always_inline
    @parameter
    def do() raises:
        for _ in range(iters):
            var p = Parser(val)
            var f = p.expect_float()
            keep(f)

    b.iter[do]()


@parameter
def bench_stdlib(mut b: Bencher, val: String) raises:
    @always_inline
    @parameter
    def do() raises:
        for _ in range(iters):
            var f = Float64(val)
            keep(f)

    b.iter[do]()


def run_group(mut m: Bench, name: String, val: String) raises:
    m.bench_with_input[String, bench_emberjson](
        BenchId("EmberJson/" + name), val
    )
    m.bench_with_input[String, bench_stdlib](BenchId("Stdlib/" + name), val)


def capture_report(mut m: Bench) raises -> String:
    var os = Python.import_module("os")
    var sys_py = Python.import_module("sys")

    # Create pipe
    var r_w = os.pipe()
    var r = r_w[0]
    var w = r_w[1]

    var stdout_fd = sys_py.stdout.fileno()
    var saved_stdout = os.dup(stdout_fd)

    # Redirect stdout to pipe
    _ = os.dup2(w, stdout_fd)

    m.dump_report()

    # Flush and restore
    _ = sys_py.stdout.flush()
    _ = os.dup2(saved_stdout, stdout_fd)
    _ = os.close(w)

    # Read from pipe
    var file_obj = os.fdopen(r)
    var content = file_obj.read()

    return String(content)


def parse_report(report: String) raises -> BenchResults:
    var lines = report.split("\n")
    var results = BenchResults()

    # Find column for "met (ms)"
    var col_idx = -1
    for i in range(len(lines)):
        if "met (ms)" in lines[i]:
            var parts = lines[i].split("|")
            for j in range(len(parts)):
                if "met (ms)" in parts[j]:
                    col_idx = j
            break

    if col_idx == -1:
        return results^

    for i in range(len(lines)):
        var line = lines[i]
        if "|" not in line or "iters" in line or line.strip().startswith("-"):
            continue

        var parts = line.split("|")
        if len(parts) > col_idx:
            var name = parts[1].strip()
            var time_str = parts[col_idx].strip()

            try:
                results[String(name)] = Float64(time_str)
            except:
                pass

    return results^


def compare_implementations() raises:
    print("Starting Float64 String Parsing Benchmarks...")
    var config = BenchConfig()
    var m = Bench(config^)

    run_group(m, "f64_1.23456789", "1.23456789")
    run_group(m, "f64_0.0", "0.0")
    run_group(m, "f64_1e-10", "1e-10")
    run_group(m, "f64_1e+20", "1e+20")
    run_group(m, "f64_3.141592653589793", "3.141592653589793")

    var report = capture_report(m)
    var results = parse_report(report)

    print(
        "\nRelative Parsing Performance (EmberJson vs Stdlib - 1M iterations)"
    )
    print("-" * 105)
    print(
        "| Benchmark Name                                | EmberJson (ms)"
        " | Stdlib (ms)   | Speedup     |"
    )
    print("-" * 105)

    var groups = List[String]()
    groups.append("f64_1.23456789")
    groups.append("f64_0.0")
    groups.append("f64_1e-10")
    groups.append("f64_1e+20")
    groups.append("f64_3.141592653589793")

    for i in range(len(groups)):
        var group = groups[i]
        var name = group
        var ember_key = "EmberJson/" + group
        var stdlib_key = "Stdlib/" + group

        var ember_time = results.get(ember_key, -1.0)
        var stdlib_time = results.get(stdlib_key, -1.0)

        if ember_time >= 0 and stdlib_time >= 0:
            var speedup_str = String("N/C")
            if ember_time > 0:
                var speedup = stdlib_time / ember_time
                speedup_str = String(speedup)
                if len(speedup_str) > 5:
                    speedup_str = String(speedup_str[0:5])
                speedup_str += "x"

            var e_str = pad_right(format_float(ember_time), 15)
            var s_str = pad_right(format_float(stdlib_time), 13)
            var sp_str = pad_right(speedup_str, 11)

            print(
                "| "
                + pad_right(name, 45)
                + " | "
                + e_str
                + " | "
                + s_str
                + " | "
                + sp_str
                + " |"
            )

    print("-" * 105)


def format_float(val: Float64) -> String:
    var s = String(val)
    if "e" in s:
        var parts = s.split("e")
        var base = String(parts[0])
        var exp = String(parts[1])
        if len(base) > 6:
            base = String(base[0:6])
        return base + "e" + exp
    if len(s) > 8:
        return String(s[0:8])
    return s


def pad_right(s: String, width: Int) -> String:
    var res = s
    while len(res) < width:
        res = res + " "
    return res


def main():
    try:
        compare_implementations()
    except:
        print("Failed")
