from emberjson.teju import write_float
from std.benchmark import (
    Bench,
    BenchId,
    Bencher,
    keep,
    BenchMetric,
    BenchConfig,
)
from std.format import Writer
from std.collections import List, Dict
from python import Python

comptime BenchResults = Dict[String, Float64]


@parameter
fn bench_teju[dtype: DType](mut b: Bencher, val: Scalar[dtype]):
    @always_inline
    @parameter
    fn do():
        for _ in range(1000):
            var writer = String()
            write_float[dtype](val, writer)

    b.iter[do]()


@parameter
fn bench_stdlib[dtype: DType](mut b: Bencher, val: Scalar[dtype]):
    @always_inline
    @parameter
    fn do():
        for _ in range(1000):
            var writer = String()
            writer.write(val)

    b.iter[do]()


fn run_group[
    dtype: DType
](mut m: Bench, name: String, val: Scalar[dtype]) raises:
    m.bench_with_input[Scalar[dtype], bench_teju[dtype]](
        BenchId("Teju/" + name), val
    )
    m.bench_with_input[Scalar[dtype], bench_stdlib[dtype]](
        BenchId("Stdlib/" + name), val
    )


fn capture_report(mut m: Bench) raises -> String:
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


fn parse_report(report: String) raises -> BenchResults:
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
            var val_str = parts[col_idx].strip()
            try:
                results[String(name)] = Float64(val_str)
            except:
                pass

    return results^


fn format_float(val: Float64) -> String:
    var s = String(val)
    if "e" in s:
        # Keep scientific notation but limit decimal places before 'e'
        var parts = s.split("e")
        var base = String(parts[0])
        var exp = String(parts[1])
        if len(base) > 6:
            base = String(base[0:6])
        return base + "e" + exp
    if len(s) > 8:
        return String(s[0:8])
    return s


fn print_comparison(var results: BenchResults, names: List[String]) raises:
    print("")
    print("Relative Performance (Teju vs Stdlib - 1k iterations)")
    print("-" * 105)
    print(
        "| "
        + pad_right("Benchmark Name", 45)
        + " | Teju (ms) | Stdlib (ms) | Speedup     |"
    )
    print(
        "|-----------------------------------------------|-----------|-------------|-------------|"
    )

    for i in range(len(names)):
        var name = names[i]
        var name_teju = "Teju/" + name
        var name_std = "Stdlib/" + name

        if name_teju in results and name_std in results:
            var t_val = results[name_teju]
            var s_val = results[name_std]

            var speedup_str = String("N/C")
            if t_val > 0:
                var speedup = s_val / t_val
                speedup_str = String(speedup)
                if len(speedup_str) > 5:
                    speedup_str = String(speedup_str[0:5])
                speedup_str += "x"

            var t_str = pad_right(format_float(t_val), 9)
            var s_str = pad_right(format_float(s_val), 11)
            var sp_str = pad_right(speedup_str, 11)

            print(
                "| "
                + pad_right(name, 45)
                + " | "
                + t_str
                + " | "
                + s_str
                + " | "
                + sp_str
                + " |"
            )

    print("-" * 105)
    print("")


fn pad_right(s: String, width: Int) -> String:
    var res = s
    while len(res) < width:
        res = res + " "
    return res


fn main() raises:
    print("Starting Float Formatting Benchmarks...")
    var config = BenchConfig()
    var m = Bench(config^)

    # Test cases
    var f64_vals = List[Float64]()
    f64_vals.append(1.23456789)
    f64_vals.append(0.0)
    f64_vals.append(1e-10)
    f64_vals.append(1e20)
    f64_vals.append(3.141592653589793)

    var f32_vals = List[Float32]()
    f32_vals.append(1.23456)
    f32_vals.append(0.0)
    f32_vals.append(1e-10)
    f32_vals.append(1e20)
    f32_vals.append(3.14159)

    var names = List[String]()

    for i in range(len(f64_vals)):
        var v = f64_vals[i]
        var name = "f64_" + String(v)
        names.append(name)
        run_group[DType.float64](m, name, v)

    for i in range(len(f32_vals)):
        var v = f32_vals[i]
        var name = "f32_" + String(v)
        names.append(name)
        run_group[DType.float32](m, name, v)

    # Float16
    names.append("Pi_f16")
    run_group[DType.float16](m, "Pi_f16", Scalar[DType.float16](3.14159))

    var report_str = capture_report(m)
    var results = parse_report(report_str)
    print_comparison(results^, names)
