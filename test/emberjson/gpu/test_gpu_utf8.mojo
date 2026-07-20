from emberjson import GpuSession, is_valid_utf8
from emberjson._utf8 import _is_valid_utf8_scalar
from std.sys import has_accelerator
from std.testing import *
from std.testing.prop.strategy import Rng


def check_gpu(
    mut s: GpuSession, bytes: List[Byte], expected: Bool, label: String
) raises:
    """The GPU validator must match the expectation AND the scalar
    reference (three-way agreement with the CPU dispatch validator is
    covered by `is_valid_utf8`'s own tests)."""
    var span = Span(bytes)
    var sl = StringSlice(unsafe_from_utf8=span)
    assert_equal(s.is_valid_utf8(sl), expected, label + " (gpu)")
    assert_equal(
        _is_valid_utf8_scalar(span.unsafe_ptr(), len(span)),
        expected,
        label + " (scalar ref)",
    )


def sweep_gpu(
    mut s: GpuSession,
    pattern: List[Byte],
    expected: Bool,
    label: String,
    at_end: Bool = False,
) raises:
    """Places `pattern` at every offset 0..39 (crossing the 16-byte block
    and 64-byte chunk boundaries), optionally terminating the input."""
    for pad in range(0, 40):
        var buf = List[Byte]()
        for _ in range(pad):
            buf.append(0x61)
        for b in pattern:
            buf.append(b)
        if not at_end:
            buf.append(0x62)
        check_gpu(s, buf, expected, label + " @pad " + String(pad))


def _valid_sequences(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        sweep_gpu(s, [0xC3, 0xA9], True, "é")
        sweep_gpu(s, [0xE2, 0x82, 0xAC], True, "€")
        sweep_gpu(s, [0xF0, 0x9F, 0x94, 0xA5], True, "🔥")
        sweep_gpu(s, [0x7F], True, "U+007F")
        sweep_gpu(s, [0xC2, 0x80], True, "U+0080")
        sweep_gpu(s, [0xDF, 0xBF], True, "U+07FF")
        sweep_gpu(s, [0xE0, 0xA0, 0x80], True, "U+0800")
        sweep_gpu(s, [0xED, 0x9F, 0xBF], True, "U+D7FF")
        sweep_gpu(s, [0xEE, 0x80, 0x80], True, "U+E000")
        sweep_gpu(s, [0xEF, 0xBF, 0xBF], True, "U+FFFF")
        sweep_gpu(s, [0xF0, 0x90, 0x80, 0x80], True, "U+10000")
        sweep_gpu(s, [0xF4, 0x8F, 0xBF, 0xBF], True, "U+10FFFF")
        sweep_gpu(s, [0xF0, 0x9F, 0x94, 0xA5], True, "🔥 at end", at_end=True)
        check_gpu(s, List[Byte](), True, "empty input")


def _invalid_sequences(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        sweep_gpu(s, [0x80], False, "bare continuation")
        sweep_gpu(s, [0xC0, 0xAF], False, "overlong 2-byte")
        sweep_gpu(s, [0xC1, 0xBF], False, "overlong 2-byte C1")
        sweep_gpu(s, [0xE0, 0x80, 0x80], False, "overlong 3-byte")
        sweep_gpu(s, [0xF0, 0x80, 0x80, 0x80], False, "overlong 4-byte")
        sweep_gpu(s, [0xED, 0xA0, 0x80], False, "surrogate U+D800")
        sweep_gpu(s, [0xED, 0xBF, 0xBF], False, "surrogate U+DFFF")
        sweep_gpu(s, [0xF4, 0x90, 0x80, 0x80], False, "above U+10FFFF")
        sweep_gpu(s, [0xF5, 0x80, 0x80, 0x80], False, "invalid lead F5")
        sweep_gpu(s, [0xFF], False, "invalid byte FF")
        sweep_gpu(s, [0xE2, 0x28, 0xA1], False, "broken continuation")
        sweep_gpu(s, [0xC3], False, "truncated lead mid-input")
        sweep_gpu(s, [0xC3], False, "dangling 2-byte lead", at_end=True)
        sweep_gpu(s, [0xE2, 0x82], False, "dangling 3-byte lead", at_end=True)
        sweep_gpu(
            s, [0xF0, 0x9F, 0x94], False, "dangling 4-byte lead", at_end=True
        )


def _corpus_agrees_with_cpu(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        comptime files = [
            "bench_data/data/twitter.json",
            "bench_data/data/citm_catalog.json",
            "bench_data/data/canada.json",
            "bench_data/data/citm_catalog_minify.json",
        ]
        comptime for i in range(len(files)):
            comptime path = files[i]
            var data: String
            with open(path, "r") as f:
                data = f.read()
            var sl = StringSlice(data)
            assert_equal(s.is_valid_utf8(sl), is_valid_utf8(sl), path)
            assert_true(s.is_valid_utf8(sl), path)


def _random_mutation_agreement(mut s: GpuSession) raises:
    """Mutation fuzz: random byte soups and corrupted valid strings must
    get identical verdicts from the GPU kernel and the scalar reference.
    Fixed seed for reproducibility."""
    comptime if not has_accelerator():
        return
    else:
        var rng = Rng(seed=0xE77BE12)

        # Random byte soups (mostly invalid) across chunk-count regimes.
        for _ in range(150):
            var n = rng.rand_int(min=0, max=400)
            var buf = List[Byte]()
            for _ in range(n):
                buf.append(Byte(rng.rand_int(min=0, max=255)))
            var span = Span(buf)
            var expect = _is_valid_utf8_scalar(span.unsafe_ptr(), len(span))
            var got = s.is_valid_utf8(StringSlice(unsafe_from_utf8=span))
            assert_equal(got, expect, "byte soup n=" + String(n))

        # Valid multibyte base with a single random byte corrupted.
        var base = String()
        for _ in range(10):
            base += "ascii héllo 日本語 🔥 padding "
        for _ in range(150):
            var buf = List[Byte]()
            for b in base.as_bytes():
                buf.append(b)
            var pos = rng.rand_int(min=0, max=len(buf) - 1)
            buf[pos] = Byte(rng.rand_int(min=0, max=255))
            var span = Span(buf)
            var expect = _is_valid_utf8_scalar(span.unsafe_ptr(), len(span))
            var got = s.is_valid_utf8(StringSlice(unsafe_from_utf8=span))
            assert_equal(got, expect, "corrupt @" + String(pos))


def test_gpu_utf8_suite() raises:
    """All UTF-8 differentials on ONE shared session.

    The current NVIDIA/CUDA toolchain deadlocks when a process
    constructs a second DeviceContext-owning session (AsyncRT
    multi-context hang; the first construction always works, Metal is
    unaffected) — so this file runs every subtest against a single
    session, which is also `GpuSession`'s documented usage pattern.
    The `gpu_is_valid_utf8` one-shot wrapper (a transient session per
    call) moved to test_gpu_free_functions.mojo for the same reason.
    """
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        _valid_sequences(s)
        _invalid_sequences(s)
        _corpus_agrees_with_cpu(s)
        _random_mutation_agreement(s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
