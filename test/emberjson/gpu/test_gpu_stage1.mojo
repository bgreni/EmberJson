"""GPU stage-1 differential tests: positions must be STRICTLY EQUAL to
the CPU `structural_index[True]` output (+ the three sentinels) on every
input — corpora, adversarial chunk-boundary cases, and random byte soups
(stage 1 classifies arbitrary bytes; validity is stage 2's concern)."""

from emberjson import GpuSession, ParseOptions
from emberjson._index import structural_index
from emberjson.utils import PaddedBuffer
from std.sys import has_accelerator
from std.testing import *
from std.testing.prop.strategy import Rng


def check_positions(mut s: GpuSession, data: Span[Byte, _]) raises:
    var n = len(data)
    # CPU reference: index + sentinels, as parse_document_tape_indexed
    # builds them.
    var buf = PaddedBuffer(data)
    var cpu = List[UInt32]()
    structural_index[True](buf.span().unsafe_ptr(), n, cpu)
    for _ in range(3):
        cpu.append(UInt32(n))

    comptime opts = ParseOptions(validate_utf8=False)
    var gpu = s._structural_index_gpu[opts](data)

    assert_equal(len(gpu), len(cpu), "count mismatch (n=" + String(n) + ")")
    for i in range(len(cpu)):
        assert_equal(
            gpu[i],
            cpu[i],
            "position " + String(i) + " (n=" + String(n) + ")",
        )


def check_positions_str(mut s: GpuSession, data: String) raises:
    check_positions(s, data.as_bytes())


def test_stage1_corpora() raises:
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
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
            check_positions_str(s, data)


def test_stage1_boundaries() raises:
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        # Sizes around chunk and block edges.
        check_positions_str(s, "")
        check_positions_str(s, "1")
        check_positions_str(s, "   ")
        check_positions_str(s, "{}")
        for size in [1, 63, 64, 65, 127, 128, 129, 4095, 4096, 4097]:
            var doc = String("[")
            var i = 0
            while doc.byte_length() < size - 1:
                if i > 0:
                    doc += ","
                doc += String(i % 10)
                i += 1
            doc += "]"
            check_positions_str(s, doc)

        # Backslash runs straddling the 64-byte chunk boundary at every
        # alignment — the exact case the escape formulation is subtle
        # about (an escaped backslash at the edge followed by a quote).
        for pad in range(50, 80):
            for run in range(1, 10):
                var doc = String('{"')
                while doc.byte_length() < pad:
                    doc += "a"
                for _ in range(run):
                    doc += "\\"
                doc += '"' + String(": 1}")
                check_positions_str(s, doc)

        # Quotes landing on bits 0 and 63 of a chunk.
        for pad in range(60, 70):
            var doc = String('["')
            while doc.byte_length() < pad:
                doc += "x"
            doc += '", 42, "tail"]'
            check_positions_str(s, doc)

        # Scalars spanning a chunk boundary.
        for pad in range(55, 70):
            var doc = String("[")
            while doc.byte_length() < pad:
                doc += " "
            doc += "123456789012345, true, null]"
            check_positions_str(s, doc)

        # Scalar spanning a BLOCK boundary (chunk 256 = byte 16384):
        # regression for the identity element zeroing the scalar carry at
        # block heads (found on twitter.json at chunk 3840).
        for shift in range(-2, 3):
            var doc = String("[")
            while doc.byte_length() < 16384 + shift - 8:
                doc += "1,"
            doc += "123456789012345]"
            check_positions_str(s, doc)


def test_stage1_random_bytes() raises:
    """Stage 1 must agree on ARBITRARY bytes, not just valid JSON."""
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        var rng = Rng(seed=0x57A6E1)
        # Structural-ish alphabet to hit interesting densities, plus raw
        # byte soup.
        comptime alphabet = String(' {}[]:,"\\ab1.-\n\ttrue')
        var alpha = alphabet.as_bytes()
        for _ in range(120):
            var n = rng.rand_int(min=0, max=2000)
            var buf = List[Byte]()
            for _ in range(n):
                buf.append(alpha[rng.rand_int(min=0, max=len(alpha) - 1)])
            check_positions(s, Span(buf))
        for _ in range(60):
            var n = rng.rand_int(min=0, max=800)
            var buf = List[Byte]()
            for _ in range(n):
                buf.append(Byte(rng.rand_int(min=0, max=255)))
            check_positions(s, Span(buf))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
