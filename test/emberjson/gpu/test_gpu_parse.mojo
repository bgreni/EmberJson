"""End-to-end GPU parse differential: `GpuSession.parse_document` must
produce a `Document` with verdicts, tape words, and serialization
identical to the CPU `parse_document` — corpora, conformance fixtures,
options matrix, and edge cases."""

from emberjson import (
    GpuSession,
    ParseOptions,
    StrictOptions,
    gpu_parse_document,
    parse_document,
    to_string,
    try_gpu_parse_document,
    try_parse_document,
)
from std.pathlib import Path
from std.sys import has_accelerator
from std.testing import *


def check_doc[
    options: ParseOptions = ParseOptions()
](mut s: GpuSession, data: String, label: String) raises:
    """Verdict + tape + serialization equality for one input."""
    var cpu_doc = try_parse_document[options](data)
    # Device stage-2 engine: same verdict + tape as the default path.
    var s2_ok: Bool
    var s2_tape = List[UInt64]()
    try:
        var d2 = s.parse_document[options, True](data)
        s2_ok = True
        s2_tape = d2._tape.copy()
    except:
        s2_ok = False
    var gpu_ok = True
    try:
        var gpu_doc = s.parse_document[options](data)
        assert_equal(s2_ok, True, label + ": stage2 rejected, default ok")
        assert_equal(
            len(s2_tape), len(gpu_doc._tape), label + ": stage2 tape len"
        )
        for i in range(len(s2_tape)):
            assert_equal(
                s2_tape[i], gpu_doc._tape[i], label + ": stage2 tape word"
            )
        assert_true(Bool(cpu_doc), label + ": gpu accepted, cpu rejected")
        ref c = cpu_doc.value()
        assert_equal(len(gpu_doc._tape), len(c._tape), label + ": tape length")
        for i in range(len(c._tape)):
            assert_equal(
                gpu_doc._tape[i], c._tape[i], label + ": tape @" + String(i)
            )
        assert_equal(
            to_string(gpu_doc), to_string(c), label + ": serialization"
        )
    except e:
        gpu_ok = False
        assert_false(
            Bool(cpu_doc),
            label + ": cpu accepted, gpu rejected (" + String(e) + ")",
        )
        assert_equal(s2_ok, False, label + ": stage2 accepted, default not")


def test_parse_corpora() raises:
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
            check_doc(s, data, path)


def test_parse_conformance_fixtures() raises:
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        for i in range(1, 40):
            var name = String("./bench_data/data/jsonchecker/fail")
            if i < 10:
                name += "0"
            name += String(i) + ".json"
            var data: String
            try:
                with open(name, "r") as f:
                    data = f.read()
            except:
                continue
            check_doc(s, data, name)
        for i in range(1, 4):
            var name = (
                String("./bench_data/data/jsonchecker/pass0")
                + String(i)
                + ".json"
            )
            var data: String
            try:
                with open(name, "r") as f:
                    data = f.read()
            except:
                continue
            check_doc(s, data, name)


def test_parse_options_matrix() raises:
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        var docs = List[String]()
        docs.append(String('{"a": [1, 2.5, -3e10], "b": "h\\u00e9llo"}'))
        docs.append(String('{"dup": 1, "dup": 2}'))
        docs.append(String("[1, 2, 3,]"))
        docs.append(String('{"unicode": "héllo 🔥", "n": null}'))
        for d in docs:
            check_doc[ParseOptions()](s, d, "default: " + d)
            check_doc[ParseOptions(strict_mode=StrictOptions.LENIENT)](
                s, d, "lenient: " + d
            )
            check_doc[ParseOptions(ignore_unicode=True)](
                s, d, "ignore_unicode: " + d
            )
            check_doc[ParseOptions(validate_utf8=False)](s, d, "no_utf8: " + d)


def test_parse_edge_cases() raises:
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        check_doc(s, String(""), "empty")
        check_doc(s, String("   "), "whitespace only")
        check_doc(s, String("1"), "single digit")
        check_doc(s, String("{}"), "empty object")
        check_doc(s, String('"just a string"'), "bare string")
        check_doc(s, String("tru"), "truncated literal")
        check_doc(s, String('{"a": 12x}'), "bad token end")
        check_doc(s, String('{"a"'), "truncated object")

        # Depth 1025 must be rejected identically (stage-2 _MAX_DEPTH).
        var deep = String()
        for _ in range(1025):
            deep += "["
        deep += "1"
        for _ in range(1025):
            deep += "]"
        check_doc(s, deep, "depth 1025")

        # Invalid UTF-8 raises the same up-front error as the CPU path.
        var bad = List[Byte]()
        for b in String('{"a": "').as_bytes():
            bad.append(b)
        bad.append(0xC0)
        bad.append(0x80)
        for b in String('"}').as_bytes():
            bad.append(b)
        var bad_s = StringSlice(unsafe_from_utf8=Span(bad))
        with assert_raises(contains="Invalid UTF-8"):
            _ = s.parse_document(bad_s)
        # And parses when validation is explicitly off (tape carries raw
        # bytes), matching the CPU engine's behavior.
        comptime unchecked = ParseOptions(validate_utf8=False)
        var d_gpu = s.parse_document[unchecked](bad_s)
        var d_cpu = parse_document[unchecked](bad_s)
        assert_equal(len(d_gpu._tape), len(d_cpu._tape), "raw-bytes tape")


def test_parse_free_functions() raises:
    comptime if not has_accelerator():
        return
    else:
        var d = gpu_parse_document('{"x": [1, 2, 3]}')
        assert_equal(d.root()["x"][2].int(), 3)
        assert_true(Bool(try_gpu_parse_document('{"ok": true}')))
        assert_false(Bool(try_gpu_parse_document('{"nope"')))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
