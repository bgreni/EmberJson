"""GPU microbenchmarks (Phase 0): launch overhead and staging bandwidth.

Separate from `bench.mojo` so the machine-pinned CPU baseline in
`bench_result.txt` stays a clean regression oracle. Later phases add
pipeline rows (UTF-8, stage 1, end-to-end parses) and the
`--print-relative` harness against `bench_gpu_result.txt`.

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
from std.gpu import global_idx
from std.gpu.host import DeviceContext
from std.pathlib import Path
from std.sys import has_accelerator
from layout import TileTensor, row_major

comptime MB11 = 11 << 20
comptime _TOUCH_BYTES_PER_THREAD = 256
comptime _TOUCH_THREADS = MB11 // _TOUCH_BYTES_PER_THREAD
comptime _touch_out_layout = row_major[_TOUCH_THREADS]()


def empty_kernel():
    pass


def touch_kernel(
    inp: UnsafePointer[UInt8, MutAnyOrigin],
    outp: TileTensor[DType.uint64, type_of(_touch_out_layout), MutAnyOrigin],
):
    """Streams 256 bytes per thread as u64 loads: device read bandwidth."""
    comptime assert outp.flat_rank == 1
    var tid = global_idx.x
    if tid < _TOUCH_THREADS:
        var base = inp + tid * _TOUCH_BYTES_PER_THREAD
        var acc: UInt64 = 0
        comptime for i in range(_TOUCH_BYTES_PER_THREAD // 8):
            acc += base.bitcast[UInt64]().load(i)
        outp[tid] = rebind[outp.ElementType](acc)


def run_gpu_benches(mut m: Bench) raises:
    comptime if not has_accelerator():
        pass
    else:
        var ctx = DeviceContext()
        var dev = ctx.enqueue_create_buffer[DType.uint8](MB11)
        var hbuf = ctx.enqueue_create_host_buffer[DType.uint8](MB11)
        var touch_out = ctx.enqueue_create_buffer[DType.uint64](_TOUCH_THREADS)
        dev.enqueue_fill(0x61)
        ctx.synchronize()
        var hptr = hbuf.unsafe_ptr()
        for i in range(MB11):
            hptr[i] = 0x61

        @parameter
        def bench_launch(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                ctx.enqueue_function[empty_kernel](grid_dim=1, block_dim=1)
                ctx.synchronize()

            b.iter[do]()

        m.bench_function[bench_launch](BenchId("GpuLaunchOverhead"))

        @parameter
        def bench_pipeline_floor(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                # The stage-1 pipeline shape: ~20 enqueues, one sync.
                for _ in range(20):
                    ctx.enqueue_function[empty_kernel](grid_dim=1, block_dim=1)
                ctx.synchronize()

            b.iter[do]()

        m.bench_function[bench_pipeline_floor](BenchId("GpuPipelineFloor20K"))

        @parameter
        def bench_upload(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                ctx.enqueue_copy(dst_buf=dev, src_buf=hbuf)
                ctx.synchronize()

            b.iter[do]()

        m.bench_function[bench_upload](
            BenchId("GpuUploadH2D11MB"),
            [ThroughputMeasure(BenchMetric.bytes, MB11)],
        )

        @parameter
        def bench_readback(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                ctx.enqueue_copy(dst_buf=hbuf, src_buf=dev)
                ctx.synchronize()

            b.iter[do]()

        m.bench_function[bench_readback](
            BenchId("GpuReadbackD2H11MB"),
            [ThroughputMeasure(BenchMetric.bytes, MB11)],
        )

        @parameter
        def bench_touch(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                ctx.enqueue_function[touch_kernel](
                    dev.unsafe_ptr(),
                    TileTensor(touch_out, _touch_out_layout),
                    grid_dim=_TOUCH_THREADS // 256,
                    block_dim=256,
                )
                ctx.synchronize()

            b.iter[do]()

        m.bench_function[bench_touch](
            BenchId("GpuDeviceRead11MB"),
            [ThroughputMeasure(BenchMetric.bytes, MB11)],
        )

        # --- UTF-8 validation, end-to-end (staging + upload + kernel +
        # sync), comparable to the CPU Utf8Validate* rows' inputs. ---
        var twitter = Path("./bench_data/data/twitter.json").read_text()
        var canada = Path("./bench_data/data/canada.json").read_text()
        var jsonl = Path("./bench_data/big_lines_complex.jsonl").read_text()
        var session = GpuSession()

        @parameter
        def bench_utf8_twitter(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(session.is_valid_utf8(twitter))

            b.iter[do]()

        m.bench_function[bench_utf8_twitter](
            BenchId("GpuUtf8Twitter"),
            [ThroughputMeasure(BenchMetric.bytes, twitter.byte_length())],
        )

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
        # readback), UTF-8 off to match the CPU Stage1* rows. ---
        var citm = Path("./bench_data/data/citm_catalog.json").read_text()
        comptime no_utf8 = ParseOptions(validate_utf8=False)

        @parameter
        def bench_s1_twitter(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(
                    len(
                        session._structural_index_gpu[no_utf8](
                            twitter.as_bytes()
                        )
                    )
                )

            b.iter[do]()

        m.bench_function[bench_s1_twitter](
            BenchId("GpuStage1Twitter"),
            [ThroughputMeasure(BenchMetric.bytes, twitter.byte_length())],
        )

        @parameter
        def bench_s1_citm(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(
                    len(session._structural_index_gpu[no_utf8](citm.as_bytes()))
                )

            b.iter[do]()

        m.bench_function[bench_s1_citm](
            BenchId("GpuStage1CitmCatalog"),
            [ThroughputMeasure(BenchMetric.bytes, citm.byte_length())],
        )

        @parameter
        def bench_s1_canada(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                keep(
                    len(
                        session._structural_index_gpu[no_utf8](
                            canada.as_bytes()
                        )
                    )
                )

            b.iter[do]()

        m.bench_function[bench_s1_canada](
            BenchId("GpuStage1Canada"),
            [ThroughputMeasure(BenchMetric.bytes, canada.byte_length())],
        )

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

        # --- Full parse end-to-end (GPU stage 1 + fused UTF-8 + CPU
        # stage 2), comparable to CPU ParseTwitterDoc/ParseCanadaDoc. ---
        @parameter
        def bench_parse_twitter(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                var d = session.parse_document(twitter)
                keep(len(d._tape))

            b.iter[do]()

        m.bench_function[bench_parse_twitter](
            BenchId("GpuParseTwitterDoc"),
            [ThroughputMeasure(BenchMetric.bytes, twitter.byte_length())],
        )

        @parameter
        def bench_parse_canada(mut b: Bencher) raises:
            @always_inline
            @parameter
            def do() raises:
                var d = session.parse_document(canada)
                keep(len(d._tape))

            b.iter[do]()

        m.bench_function[bench_parse_canada](
            BenchId("GpuParseCanadaDoc"),
            [ThroughputMeasure(BenchMetric.bytes, canada.byte_length())],
        )

        # --- Batch JSONL end-to-end (the headline workload) vs the fair
        # in-memory CPU baseline (per-line parse_document loop). ---
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
