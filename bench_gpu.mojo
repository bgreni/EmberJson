"""GPU benchmarks: the end-to-end parse pipeline.

Separate from `bench.mojo` so the machine-pinned CPU baseline in
`bench_result.txt` stays a clean regression oracle. Later phases add
pipeline rows (UTF-8, stage 1, end-to-end batch parses) and the
`--print-relative` harness against `bench_gpu_result.txt`.

Only inputs at or above the GPU's measured crossover are benchmarked:
batch JSONL from ~1 MB, single documents only above ~120-150 MB. The
stage-1 and full-parse rows on the small single-document corpora
(twitter/citm/canada) were dropped — they measured launch and staging
floors, not throughput anyone would choose the GPU for. `GpuUtf8Canada`
survives because UTF-8 validation's crossover is far lower, putting
2.25 MB right at the turn of that curve.

Skips (with a message) on machines without an accelerator.
"""

from std.benchmark import (
    Bench,
    BenchId,
    ThroughputMeasure,
    Bencher,
    BenchMetric,
    BenchConfig,
)
from emberjson import GpuSession, ParseOptions, try_parse_document
from std.benchmark import keep
from std.gpu.host import DeviceContext
from std.pathlib import Path
from std.sys import has_accelerator


def run_gpu_benches(mut m: Bench) raises:
    comptime if not has_accelerator():
        pass
    else:
        # ONE GpuSession per process. A second in-process
        # DeviceContext-owning construction (raw ctx + later session, or
        # two sessions) deadlocks on the current CUDA toolchain (AsyncRT
        # multi-context hang; Metal unaffected).
        var session = GpuSession()
        # --- UTF-8 validation, end-to-end (staging + upload + kernel +
        # sync), comparable to the CPU Utf8Validate* rows' inputs.
        # Canada (2.25 MB) is kept as the near-crossover datapoint: the
        # GPU validator only overtakes the 20-30 GB/s CPU one at several
        # MB, so this row is where the curve turns. ---
        var canada = Path("./bench_data/data/canada.json").read_text()
        var jsonl = Path("./bench_data/big_lines_complex.jsonl").read_text()

        @parameter
        def bench_utf8_canada(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(session.is_valid_utf8(canada))

            b.iter[do]()

        m.bench_function[bench_utf8_canada](
            BenchId("GpuUtf8Canada"),
            [ThroughputMeasure(BenchMetric.bytes, canada.byte_length())],
        )

        @parameter
        def bench_utf8_jsonl(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(session.is_valid_utf8(jsonl))

            b.iter[do]()

        m.bench_function[bench_utf8_jsonl](
            BenchId("GpuUtf8Jsonl11MB"),
            [ThroughputMeasure(BenchMetric.bytes, jsonl.byte_length())],
        )

        # --- Stage 1 end-to-end (staging + K1..K5 + sync + positions
        # readback), UTF-8 off to match the CPU Stage1* rows. Only the
        # 11 MB batch input: the small single-document corpora sit far
        # below the crossover where GPU stage 1 is worth running. ---
        comptime no_utf8 = ParseOptions(validate_utf8=False)

        @parameter
        def bench_s1_jsonl(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(
                    len(
                        session._structural_index_gpu[no_utf8](jsonl.as_bytes())
                    )
                )

            b.iter[do]()

        m.bench_function[bench_s1_jsonl](
            BenchId("GpuStage1Jsonl11MB"),
            [ThroughputMeasure(BenchMetric.bytes, jsonl.byte_length())],
        )

        # --- Batch JSONL end-to-end (GPU stage 1 + fused UTF-8 + CPU
        # stage 2) vs the fair in-memory CPU baseline (per-line
        # parse_document loop). This is the headline workload: batch
        # parsing wins from ~1 MB up, whereas single-document GPU parse
        # only overtakes the CPU above ~120-150 MB, so no single-doc row
        # below that crossover is benchmarked here. ---
        @parameter
        def bench_batch_gpu(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                var docs = session.parse_documents(jsonl)
                keep(len(docs))

            b.iter[do]()

        m.bench_function[bench_batch_gpu](
            BenchId("GpuParseJsonl11MB"),
            [ThroughputMeasure(BenchMetric.bytes, jsonl.byte_length())],
        )

        @parameter
        def bench_batch_cpu(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                var bytes = jsonl.as_bytes()
                var n = len(bytes)
                var count = 0
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
                            if try_parse_document(line):
                                count += 1
                        line_start = i + 1
                    i += 1
                keep(count)

            b.iter[do]()

        m.bench_function[bench_batch_cpu](
            BenchId("CpuParseJsonlDocLoop11MB"),
            [ThroughputMeasure(BenchMetric.bytes, jsonl.byte_length())],
        )

        @parameter
        def bench_batch_gpu_s2(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                var docs = session.parse_documents[ParseOptions(), True](jsonl)
                keep(len(docs))

            b.iter[do]()

        m.bench_function[bench_batch_gpu_s2](
            BenchId("GpuParseJsonlS2_11MB"),
            [ThroughputMeasure(BenchMetric.bytes, jsonl.byte_length())],
        )


def main() raises:
    comptime if not has_accelerator():
        print("bench_gpu: no accelerator on this machine; nothing to run")
    else:
        var config = BenchConfig()
        config.verbose_timing = True
        config.flush_denormals = True
        config.show_progress = True
        var m = Bench(config^)
        run_gpu_benches(m)
        m.dump_report()
