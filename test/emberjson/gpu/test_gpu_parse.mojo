"""End-to-end GPU parse differential: `GpuSession.parse_document` must
produce a `Document` with verdicts, tape words, and serialization
identical to the CPU `parse_document` — corpora, conformance fixtures,
options matrix, and edge cases."""

from emberjson import (
    GpuSession,
    ParseOptions,
    StrictOptions,
    parse_document,
    to_string,
    try_parse_document,
)
from std.pathlib import Path
from std.sys import has_accelerator
from std.testing import *


def check_doc[
    options: ParseOptions = ParseOptions()
](mut s: GpuSession, data: String, label: String) raises:
    """Verdict + tape + serialization equality for one input.

    Each engine's verdict is captured in its OWN try/except first, and
    only then are the three compared. Asserting inside a `try` that also
    guards the parse means an assertion failure is caught by that same
    `except` and silently reinterpreted as "the engine rejected the
    input" — which lets a genuine GPU-accepts-invalid-JSON bug pass
    green. Keep the capture and the comparison separate.
    """
    var cpu_doc = try_parse_document[options](data)
    var cpu_ok = Bool(cpu_doc)

    # --- capture: GPU device-stage-2 engine ---
    var s2_ok: Bool
    var s2_tape = List[UInt64]()
    try:
        var d2 = s.parse_document[options, True](data)
        s2_ok = True
        s2_tape = d2._tape.copy()
    except:
        s2_ok = False

    # --- capture: GPU default engine ---
    var gpu_ok: Bool
    var gpu_tape = List[UInt64]()
    var gpu_str = String()
    var gpu_err = String()
    try:
        var gpu_doc = s.parse_document[options](data)
        gpu_ok = True
        gpu_tape = gpu_doc._tape.copy()
        gpu_str = to_string(gpu_doc)
    except e:
        gpu_ok = False
        gpu_err = String(e)

    # --- compare: verdicts first, so a mismatch names itself ---
    assert_equal(
        gpu_ok, cpu_ok, label + ": gpu/cpu verdict diverged (" + gpu_err + ")"
    )
    assert_equal(s2_ok, cpu_ok, label + ": stage2/cpu verdict diverged")
    if not cpu_ok:
        return

    ref c = cpu_doc.value()
    assert_equal(len(gpu_tape), len(c._tape), label + ": tape length")
    for i in range(len(c._tape)):
        assert_equal(gpu_tape[i], c._tape[i], label + ": tape @" + String(i))
    assert_equal(len(s2_tape), len(c._tape), label + ": stage2 tape len")
    for i in range(len(c._tape)):
        assert_equal(
            s2_tape[i], c._tape[i], label + ": stage2 tape @" + String(i)
        )
    assert_equal(gpu_str, to_string(c), label + ": serialization")


def _parse_corpora(mut s: GpuSession) raises:
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
            check_doc(s, data, path)


def _parse_conformance_fixtures(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        # `except: continue` below means a missing corpus silently
        # turns this whole suite into a no-op that still reports pass —
        # so count what loaded and assert the floor.
        var loaded = 0
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
            loaded += 1
            check_doc(s, data, name)
        assert_true(
            loaded >= 31,
            "jsonchecker fail corpus missing: only "
            + String(loaded)
            + " of >=31 fixtures loaded",
        )
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


def _parse_options_matrix(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
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


def _parse_edge_cases(mut s: GpuSession) raises:
    comptime if not has_accelerator():
        return
    else:
        check_doc(s, String(""), "empty")
        check_doc(s, String("   "), "whitespace only")
        check_doc(s, String("1"), "single digit")
        check_doc(s, String("{}"), "empty object")
        check_doc(s, String('"just a string"'), "bare string")
        check_doc(s, String("tru"), "truncated literal")
        check_doc(s, String('{"a": 12x}'), "bad token end")
        check_doc(s, String('{"a"'), "truncated object")

        # \u surrogate-escape handling: `_device_string_pass` has
        # dedicated lone/unpaired-surrogate, bad-hex and >0x10FFFF
        # rejection that no test input previously reached.
        var esc = List[String]()
        esc.append(String('{"a": "\\uD800"}'))  # lone high
        esc.append(String('{"a": "\\uDC00"}'))  # lone low
        esc.append(String('{"a": "\\uD800\\uE000"}'))  # high + non-low
        esc.append(String('{"a": "\\uD800\\u0041"}'))  # high + ascii
        esc.append(String('{"a": "\\uD83D\\uDD25"}'))  # valid pair
        esc.append(String('{"a": "\\uZZZZ"}'))  # bad hex
        esc.append(String('{"a": "\\uD8"}'))  # truncated
        esc.append(String('{"a": "\\u00e9"}'))  # valid BMP
        for e in esc:
            check_doc(s, e, "escape: " + e)
            check_doc[ParseOptions(ignore_unicode=True)](
                s, e, "escape ignore_unicode: " + e
            )

        # Number leads that route through `device_parse_number`'s
        # not-ok return and escalate to the CPU redo path.
        var nums = List[String]()
        nums.append(String("[+1]"))
        nums.append(String("[.5]"))
        nums.append(String("[-]"))
        nums.append(String("[1e]"))
        nums.append(String("[1.]"))
        nums.append(String("[00]"))
        nums.append(String("[-0]"))
        nums.append(String("[1e+]"))
        nums.append(String("[--1]"))
        # 40-digit mantissa forces the CPU-only slow float path.
        nums.append(String("[1.2345678901234567890123456789012345678901]"))
        nums.append(String("[1e400]"))
        nums.append(String("[1e-400]"))
        for nm in nums:
            check_doc(s, nm, "number: " + nm)

        # The FUSED stage-1 UTF-8 validator is a different
        # implementation from the standalone `is_valid_utf8` kernel that
        # test_gpu_utf8 sweeps, and the parse path uses this one. Drive
        # the invalid classes through it, at varying offsets so the
        # 64-byte chunk boundary and the `rem == 64` dangling-lead case
        # are both hit.
        var bad_seqs = List[List[Byte]]()

        def _seq(*bs: Int) -> List[Byte]:
            var o = List[Byte]()
            for b in bs:
                o.append(Byte(b))
            return o^

        bad_seqs.append(_seq(0xC0, 0x80))  # overlong 2-byte
        bad_seqs.append(_seq(0xE0, 0x80, 0x80))  # overlong 3-byte
        bad_seqs.append(_seq(0xF0, 0x80, 0x80, 0x80))  # overlong 4-byte
        bad_seqs.append(_seq(0xED, 0xA0, 0x80))  # surrogate D800
        bad_seqs.append(_seq(0xED, 0xBF, 0xBF))  # surrogate DFFF
        bad_seqs.append(_seq(0xF5, 0x80, 0x80, 0x80))  # > U+10FFFF
        bad_seqs.append(_seq(0xF8, 0x88, 0x80, 0x80, 0x80))  # 5-byte
        bad_seqs.append(_seq(0xFE))  # invalid lead
        bad_seqs.append(_seq(0xFF))  # invalid lead
        bad_seqs.append(_seq(0xC2))  # truncated 2-byte
        bad_seqs.append(_seq(0xE1, 0x80))  # truncated 3-byte
        bad_seqs.append(_seq(0x80))  # bare continuation

        comptime pads = [0, 1, 30, 55, 60, 61, 62, 63, 64, 65, 120]
        for seq in bad_seqs:
            comptime for pi in range(len(pads)):
                comptime pad = pads[pi]
                var buf = List[Byte]()
                for b in String('{"a": "').as_bytes():
                    buf.append(b)
                for _ in range(pad):
                    buf.append(Byte(ord("x")))
                for b in seq:
                    buf.append(b)
                for b in String('"}').as_bytes():
                    buf.append(b)
                var sl = StringSlice(unsafe_from_utf8=Span(buf))
                # CPU is the oracle: whatever it says, the fused GPU
                # validator must say too.
                var cpu_ok = Bool(try_parse_document(sl))
                var gpu_ok = True
                try:
                    _ = s.parse_document(sl)
                except:
                    gpu_ok = False
                assert_equal(
                    gpu_ok,
                    cpu_ok,
                    "fused utf8 verdict diverged at pad " + String(pad),
                )
                assert_false(cpu_ok, "expected rejection at pad " + String(pad))

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

        # Error-message parity. Accept/reject parity is covered by the
        # differential above; this pins the *wording*, a separate claim
        # `assemble.mojo` makes that two inputs currently break. Pinning
        # both the matching and the diverging cases means a NEW
        # divergence fails here rather than being absorbed by the
        # verdict-only check.
        var msgs = List[String]()
        msgs.append(String("[1, 2, 3,]"))
        msgs.append(String('{"a": 1,}'))
        msgs.append(String("[1 2]"))
        msgs.append(String("tru"))
        for m in msgs:
            var cpu_msg = String()
            try:
                _ = parse_document(m)
            except e:
                cpu_msg = String(e)
            assert_true(
                cpu_msg.byte_length() > 0, "expected CPU rejection for " + m
            )
            with assert_raises(contains=cpu_msg):
                _ = s.parse_document(m)

        # Known wording divergences (verdicts still agree). The GPU walk
        # drops the CPU's trailing context on `Invalid identifier`, and
        # for a bad token end names the offending value rather than the
        # delimiter it expected. Recorded, not endorsed.
        var diverging = List[String]()
        diverging.append(String('{"a" 1}'))
        diverging.append(String('{"a": 12x}'))
        var gpu_says = List[String]()
        gpu_says.append(String("Invalid identifier"))
        gpu_says.append(String("Invalid json value: x"))
        for i in range(len(diverging)):
            var dm = diverging[i]
            with assert_raises():
                _ = parse_document(dm)
            with assert_raises(contains=gpu_says[i]):
                _ = s.parse_document(dm)


def test_gpu_parse_suite() raises:
    """All parse differentials on ONE shared session (a second
    in-process GpuSession construction deadlocks on the current CUDA
    toolchain; see test_gpu_utf8_suite). The one-shot free-function
    wrappers (transient session per call) moved to
    test_gpu_free_functions.mojo for the same reason."""
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        _parse_corpora(s)
        _parse_conformance_fixtures(s)
        _parse_options_matrix(s)
        _parse_edge_cases(s)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
