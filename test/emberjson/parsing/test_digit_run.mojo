from std.random import seed, random_ui64
from std.sys.info import CompilationTarget
from std.testing import assert_equal, TestSuite


def _reference(bytes: Array[Byte, 32]) -> Tuple[UInt64, Int]:
    """The leading run of ASCII digits (at most 16) and its value."""
    var v: UInt64 = 0
    var n = 0
    while n < 16 and Byte(0x30) <= bytes[n] <= Byte(0x39):
        v = v * 10 + UInt64(bytes[n] - 0x30)
        n += 1
    return (v, n)


def _check(bytes: Array[Byte, 32]) raises:
    from emberjson._deserialize._parser_helper import (
        unsafe_parse_digit_run16,
    )

    var got = unsafe_parse_digit_run16(bytes.unsafe_ptr())
    var want = _reference(bytes)
    assert_equal(got[1], want[1], "run length")
    assert_equal(got[0], want[0], "run value")


def test_every_length_and_terminator() raises:
    """Runs of every length 0-16 of 9s (the largest lane values), ended by
    every possible non-digit byte."""
    comptime if not CompilationTarget.has_avx2():
        return
    for n in range(17):
        for term in range(256):
            if 0x30 <= term <= 0x39:
                continue
            var bytes = Array[Byte, 32](fill=Byte(0x39))
            for k in range(n, 32):
                bytes[k] = Byte(term)
            _check(bytes)


def test_random_runs() raises:
    """Random digits, random run lengths, random bytes after the run."""
    comptime if not CompilationTarget.has_avx2():
        return
    seed(20260925)
    for _ in range(20000):
        var bytes = Array[Byte, 32](fill=Byte(0))
        var n = Int(random_ui64(0, 17))
        for k in range(32):
            bytes[k] = Byte(random_ui64(0, 255))
        for k in range(min(n, 32)):
            bytes[k] = Byte(0x30 + random_ui64(0, 9))
        _check(bytes)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
