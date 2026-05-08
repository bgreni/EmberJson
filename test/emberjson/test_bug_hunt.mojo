"""Tests for bugs discovered during a code audit.

Each test documents a specific bug and asserts the *correct* behaviour, so
the test will fail until the bug is fixed. A short comment above each test
explains the bug and where it lives.
"""

from emberjson import (
    parse,
    Object,
    Array,
    Value,
    ParseOptions,
    StrictOptions,
    read_lines,
    write_lines,
)
from std.pathlib import Path
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)


# ---------------------------------------------------------------------------
# Bug 1: Object dict-literal __init__ does not deduplicate keys.
#
# emberjson/object.mojo `__init__(out self, var keys, var values, __dict_literal__)`
# blindly appends every (key, value) pair. By contrast `__setitem__` updates
# in place when a key already exists, and an Object literal in source code is
# semantically a Mojo dict literal. The two construction paths therefore
# produce different sized objects for the same source text:
#     var a: Object = {"x": 1, "x": 2}   # currently len(a) == 2
#     var b = Object(); b["x"] = 1; b["x"] = 2  # len(b) == 1
# ---------------------------------------------------------------------------
def test_dict_literal_dedupes_keys() raises:
    var a: Object = {"x": 1, "x": 2}
    assert_equal(len(a), 1)
    assert_equal(a["x"].int(), 2)


# ---------------------------------------------------------------------------
# Bug 2: Object equality is wrong when one side has duplicate keys.
#
# Originally, lenient parsing kept both entries of `{"a":1,"a":2}` so the
# object had len 2. `Object.__eq__` walked only `self`'s keys, so two same-
# length objects with different key sets compared equal. The fix (centralized
# `_upsert` insertion + cached key hash) makes the duplicate state structurally
# unreachable: lenient mode now collapses duplicates with last-write-wins,
# matching dict-literal and `__setitem__` semantics.
# ---------------------------------------------------------------------------
def test_eq_with_duplicate_keys() raises:
    var dup = parse[ParseOptions(strict_mode=StrictOptions.LENIENT)](
        '{"a":1,"a":2}'
    )
    var unique = parse[ParseOptions(strict_mode=StrictOptions.LENIENT)](
        '{"a":1,"b":2}'
    )
    # Lenient parsing now collapses duplicates (last-write-wins).
    assert_equal(len(dup.object()), 1)
    assert_equal(dup.object()["a"].int(), 2)
    assert_equal(len(unique.object()), 2)
    # Different lengths can never compare equal — and even if both sides had
    # the same keys, `__eq__` now respects the unique-keys invariant.
    assert_false(dup.object() == unique.object())
    assert_true(dup.object() != unique.object())


# ---------------------------------------------------------------------------
# Bug 3: JSONLinesIter terminates early when it encounters a blank line.
#
# `JSONLinesIter.__next__` (jsonl.mojo) reads a line and unconditionally
# tries to parse it. When the line is empty (e.g. a stray blank line in the
# middle of a JSONL file) parse fails and the iterator turns it into
# StopIteration, hiding the rest of the file. JSONL implementations should
# tolerate or skip blank lines, not silently truncate input.
# ---------------------------------------------------------------------------
def test_jsonl_blank_line_does_not_truncate() raises:
    var p = Path("/tmp/test_bug_jsonl_blank.jsonl")
    with open(p, "w") as f:
        f.write('{"a":1}\n')
        f.write("\n")
        f.write('{"a":2}\n')

    var seen = List[Value]()
    for line in read_lines(p):
        seen.append(line.copy())

    assert_equal(len(seen), 2)
    assert_equal(seen[0].object()["a"].int(), 1)
    assert_equal(seen[1].object()["a"].int(), 2)


# ---------------------------------------------------------------------------
# Bug 4: JSONLinesIter swallows parse errors as StopIteration.
#
# `JSONLinesIter.__next__` catches every exception from the parser and turns
# it into StopIteration. A malformed line therefore looks identical to EOF,
# so the caller silently gets a truncated stream instead of an error. That
# is dangerous because data corruption is undetectable.
# ---------------------------------------------------------------------------
def test_jsonl_malformed_line_raises() raises:
    var p = Path("/tmp/test_bug_jsonl_malformed.jsonl")
    with open(p, "w") as f:
        f.write('{"a":1}\n')
        f.write("{not valid json}\n")
        f.write('{"a":2}\n')

    var raised = False
    var collected = List[Value]()
    try:
        for line in read_lines(p):
            collected.append(line.copy())
    except:
        raised = True

    # Either we raised on the malformed line, or we kept going and got every
    # valid record. Silently stopping at line 2 (current behaviour) is the
    # bug: we end up with exactly 1 item and no error.
    assert_true(
        raised or len(collected) >= 2,
        "JSONL parser silently truncated stream after a malformed line",
    )


# ---------------------------------------------------------------------------
# Bug 5: write_lines omits the trailing newline.
#
# `write_lines` (jsonl.mojo) writes "\n" only between records, so the last
# record has no newline terminator. The JSON Lines spec (jsonlines.org)
# requires every line to end with `\n`, and many parsers (including a
# stricter version of read_lines) treat the final unterminated chunk as an
# error or drop it.
# ---------------------------------------------------------------------------
def test_write_lines_terminates_last_line() raises:
    var p = Path("/tmp/test_bug_jsonl_trailing.jsonl")
    var rows = List[Value]()
    rows.append(parse('{"a":1}'))
    rows.append(parse('{"a":2}'))
    write_lines(p, rows)

    var content = open(p, "r").read()
    assert_true(
        content.endswith("\n"),
        "write_lines should terminate the last record with a newline",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
