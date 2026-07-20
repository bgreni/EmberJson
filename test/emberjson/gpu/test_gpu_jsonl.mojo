"""Batch (JSON Lines) GPU parsing differential tests.

The oracle is the CPU semantics of `read_lines`: parse each line
independently, silently skipping blank and malformed lines. The GPU
batch must produce the same number of documents with identical
serialization — including on corrupt batches, where segmented carry
resets keep one bad line from poisoning its neighbors.
"""

from emberjson import (
    Document,
    GpuSession,
    ParseOptions,
    to_string,
    try_parse_document,
)
from std.pathlib import Path
from std.sys import has_accelerator
from std.testing import *


def cpu_oracle[
    options: ParseOptions = ParseOptions()
](s: StringSlice) raises -> List[Document]:
    """Per-line `try_parse_document`, skipping failures — the reference
    for skip-malformed batch semantics."""
    var docs = List[Document]()
    var bytes = s.as_bytes()
    var n = len(bytes)
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
                var d = try_parse_document[options](line)
                if d:
                    docs.append(d.take())
            line_start = i + 1
        i += 1
    return docs^


def check_batch[
    options: ParseOptions = ParseOptions()
](mut s: GpuSession, text: String, label: String) raises:
    var cpu = cpu_oracle[options](text)
    var gpu = s.parse_documents[options](text)
    assert_equal(len(gpu), len(cpu), label + ": doc count")
    for i in range(len(cpu)):
        assert_equal(
            to_string(gpu[i]), to_string(cpu[i]), label + " doc " + String(i)
        )
    # Device stage-2 engine must match too.
    var gpu2 = s.parse_documents[options, True](text)
    assert_equal(len(gpu2), len(cpu), label + ": s2 doc count")
    for i in range(len(cpu)):
        assert_equal(
            to_string(gpu2[i]),
            to_string(cpu[i]),
            label + " s2 doc " + String(i),
        )


def _jsonl_checked_in_files(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        comptime files = [
            "bench_data/jsonl.jsonl",
            "bench_data/big_lines.jsonl",
            "bench_data/big_lines_complex.jsonl",
        ]
        comptime for i in range(len(files)):
            comptime path = files[i]
            var data: String
            with open(path, "r") as f:
                data = f.read()
            check_batch(s, data, path)


def _jsonl_handcrafted(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        check_batch(s, String(""), "empty input")
        check_batch(s, String("\n"), "lone newline")
        check_batch(s, String('{"a": 1}'), "single line no newline")
        check_batch(s, String('{"a": 1}\n'), "single line")
        check_batch(s, String('{"a": 1}\n\n\n{"b": 2}\n'), "blank lines")
        check_batch(s, String("   \n\t\n"), "whitespace lines")
        check_batch(
            s,
            String('{"a": 1}\r\n{"b": 2}\r\n'),
            "CRLF line endings",
        )
        check_batch(
            s,
            String('{"good": 1}\n{"broken": \n{"also good": 2}\n'),
            "malformed middle line",
        )
        check_batch(
            s,
            String('nonsense here\n[1, 2, 3]\ntru\n"str"\n12x\n'),
            "mixed garbage and valid",
        )


def _jsonl_state_isolation(mut s: GpuSession) raises:
    """The critical segmentation property: a corrupt line's carry state
    (open string, trailing backslash) must not leak into later lines."""
    comptime if not has_accelerator():
        return
    else:
        # Unclosed string: without per-segment resets the open-string
        # state would swallow the next line's structurals.
        check_batch(
            s,
            String('{"unclosed": "abc\n{"fine": 1}\n[2, 3]\n'),
            "unclosed string",
        )
        # Odd trailing backslash inside a string.
        check_batch(
            s,
            String('{"trailing": "x\\\n{"fine": 1}\n'),
            "line ends mid-escape",
        )
        # Unbalanced brackets.
        check_batch(
            s,
            String('[[[[\n{"fine": 1}\n]]]]\n{"also": 2}\n'),
            "unbalanced brackets",
        )
        # Quote parity odd across many lines.
        var batch = String()
        for k in range(20):
            if k % 3 == 0:
                batch += '"odd quote\n'
            else:
                batch += '{"k": ' + String(k) + "}\n"
        check_batch(s, batch, "alternating odd quotes")


def _jsonl_utf8_line_isolation(mut s: GpuSession) raises:
    """With validation on, only the invalid-UTF-8 line is skipped."""
    comptime if not has_accelerator():
        return
    else:
        var bytes = List[Byte]()
        for b in String('{"ok": 1}\n{"bad": "').as_bytes():
            bytes.append(b)
        bytes.append(0xC0)
        bytes.append(0x80)
        for b in String('"}\n{"ok": 2}\n').as_bytes():
            bytes.append(b)
        var text = String(StringSlice(unsafe_from_utf8=Span(bytes)))
        var gpu = s.parse_documents(text)
        assert_equal(len(gpu), 2, "bad-utf8 line skipped, neighbors kept")
        assert_equal(to_string(gpu[0]), '{"ok":1}')
        assert_equal(to_string(gpu[1]), '{"ok":2}')
        # With validation off, the tape carries the raw bytes and all
        # three lines parse — matching the CPU engines.
        comptime unchecked = ParseOptions(validate_utf8=False)
        var gpu_raw = s.parse_documents[unchecked](text)
        assert_equal(len(gpu_raw), 3, "raw mode keeps all lines")


def _jsonl_chunk_geometry(mut s: GpuSession) raises:
    """Lines sized around chunk (64) and block (16384) boundaries."""
    comptime if not has_accelerator():
        return
    else:
        for size in [3, 62, 63, 64, 65, 127, 128, 129, 1000]:
            var batch = String()
            for k in range(12):
                var line = String('{"k": [')
                var j = 0
                while line.byte_length() < size - 2:
                    if j > 0:
                        line += ","
                    line += String((k + j) % 10)
                    j += 1
                line += "]}"
                batch += line + "\n"
            check_batch(s, batch, "line size ~" + String(size))
        # One long line crossing the 16KB block boundary, between
        # normal lines.
        var big = String('{"big": [')
        var j = 0
        while big.byte_length() < 17000:
            if j > 0:
                big += ","
            big += String(j % 10)
            j += 1
        big += "]}"
        var batch = String('{"before": 1}\n') + big + String('\n{"after": 2}\n')
        check_batch(s, batch, "block-crossing line")


def test_gpu_jsonl_suite() raises:
    """All batch differentials on ONE shared session (a second
    in-process GpuSession construction deadlocks on the current CUDA
    toolchain; see test_gpu_utf8_suite). The gpu_parse_documents
    one-shot wrapper moved to test_gpu_free_functions.mojo."""
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        _jsonl_checked_in_files(s)
        _jsonl_handcrafted(s)
        _jsonl_state_isolation(s)
        _jsonl_utf8_line_isolation(s)
        _jsonl_chunk_geometry(s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
