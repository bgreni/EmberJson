from emberjson._gpu import GpuSession, NO_ACCELERATOR_ERROR
from std.sys import has_accelerator
from std.testing import *


def test_session_smoke() raises:
    """On GPU machines: session construction + kernel round trip works."""
    comptime if not has_accelerator():
        return
    else:
        var s = GpuSession()
        assert_true(s._smoke_test())


def test_session_raises_without_gpu() raises:
    """On CPU-only machines: construction fails loud, never falls back."""
    comptime if has_accelerator():
        return
    else:
        with assert_raises(contains=NO_ACCELERATOR_ERROR):
            _ = GpuSession()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
