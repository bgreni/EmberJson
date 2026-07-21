"""Parallel bracket-matcher differential: the GPU depth-sort pairing
(cuJSON's structure recognizer) must exactly match a CPU stack matcher
over the same token stream — including error verdicts on malformed
nesting."""

from emberjson import GpuSession, ParseOptions
from emberjson._gpu.stage2 import (
    TOK_CLOSE_ARR,
    TOK_CLOSE_OBJ,
    TOK_KIND_MASK,
    TOK_OPEN_ARR,
    TOK_OPEN_OBJ,
)
from emberjson.utils import PaddedBuffer
from std.pathlib import Path
from std.sys import has_accelerator
from std.testing import *


def cpu_match(
    types: UnsafePointer[UInt8, _], n: Int
) raises -> Tuple[List[Int], Bool]:
    """Reference stack matcher: partner token index per token (-1 for
    non-containers), plus structural validity."""
    var partner = List[Int]()
    for _ in range(n):
        partner.append(-1)
    var stack = List[Int]()
    var ok = True
    for t in range(n):
        var kind = types[t] & TOK_KIND_MASK
        if kind == TOK_OPEN_OBJ or kind == TOK_OPEN_ARR:
            stack.append(t)
        elif kind == TOK_CLOSE_OBJ or kind == TOK_CLOSE_ARR:
            if len(stack) == 0:
                ok = False
                break
            var o = stack.pop()
            var okind = types[o] & TOK_KIND_MASK
            if (okind ^ kind) != 1:
                ok = False
                break
            partner[o] = t
            partner[t] = o
        if len(stack) > 1024:
            ok = False
            break
    if len(stack) != 0:
        ok = False
    return (partner^, ok)


def check_brackets(mut s: GpuSession, data: String, label: String) raises:
    comptime opts = ParseOptions(validate_utf8=False)
    var buf = PaddedBuffer(data.as_bytes())
    var positions = s._structural_index_gpu[opts](buf.span())
    var total = len(positions) - 3
    if total == 0:
        return
    _ = s._run_stage2[opts](total, 1)
    var r = s._match_brackets(total)
    var oc_cnt = r[0]
    var gpu_ok = r[1]

    var tp = s._s2.types_host.unsafe_ptr()
    var cpu = cpu_match(tp, total)
    assert_equal(gpu_ok, cpu[1], label + ": validity verdict")
    if not cpu[1]:
        return
    var oc = s._br.oc_tok_host.unsafe_ptr()
    var pr = s._br.pair_host.unsafe_ptr()
    var checked = 0
    for i in range(oc_cnt):
        var tok = Int(oc[i])
        var expect = cpu[0][tok]
        assert_equal(
            Int(pr[i]),
            expect,
            label + ": pair @token " + String(tok),
        )
        checked += 1
    assert_true(checked == oc_cnt, label + ": all containers checked")


def _brackets_corpora(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        comptime files = [
            "bench_data/data/twitter.json",
            "bench_data/data/citm_catalog.json",
            "bench_data/data/canada.json",
        ]
        comptime for i in range(len(files)):
            comptime path = files[i]
            var data: String
            with open(path, "r") as f:
                data = f.read()
            check_brackets(s, data, path)


def _brackets_shapes(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        # Deep nesting (within limits).
        var deep = String()
        for _ in range(1000):
            deep += "["
        deep += "1"
        for _ in range(1000):
            deep += "]"
        check_brackets(s, deep, "deep 1000")
        # Wide single level: a giant same-depth run crossing many sort
        # blocks (stresses stable ranks + histogram bases).
        var wide = String("[")
        for k in range(100000):
            if k > 0:
                wide += ","
            wide += "{}" if k % 2 == 0 else "[]"
        wide += "]"
        check_brackets(s, wide, "wide 100K siblings")
        # Mixed ragged nesting.
        var mixed = String('{"a": [1, {"b": [[], [2, {"c": {}}]]}], "d": []}')
        check_brackets(s, mixed, "mixed")


def _brackets_invalid(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        check_brackets(s, String("[}"), "type mismatch")
        check_brackets(s, String("[[1, 2]"), "unclosed")
        check_brackets(s, String("[1, 2]]"), "extra close")
        check_brackets(s, String("{]"), "brace-bracket")
        check_brackets(s, String('{"a": [1, 2}]'), "crossed pair")
        # Depth 1025: matcher must reject like the walker.
        var too_deep = String()
        for _ in range(1025):
            too_deep += "["
        too_deep += "1"
        for _ in range(1025):
            too_deep += "]"
        check_brackets(s, too_deep, "depth 1025")


def test_gpu_brackets_suite() raises:
    """All bracket-matcher differentials on ONE shared session (a second
    in-process GpuSession construction deadlocks on the current CUDA
    toolchain; see test_gpu_utf8_suite)."""
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        _brackets_corpora(s)
        _brackets_shapes(s)
        _brackets_invalid(s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
