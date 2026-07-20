"""One-shot GPU free-function coverage — deliberately ONE call.

Each `gpu_*` free function constructs a transient `GpuSession`
internally. The current NVIDIA/CUDA toolchain deadlocks whenever a
process constructs a SECOND DeviceContext-owning session (AsyncRT
multi-context hang: the first construction always works; Metal is
unaffected — probed 2026-07-19, Mojo 1.0.0b3.dev2026071006, driver
580.119.02, RTX 3080). So this file exercises exactly one free-function
call per process: `gpu_parse_document`, the deepest wrapper (session +
full parse + Document plumbing). The other one-shots
(`try_gpu_parse_document`, `gpu_parse_documents`, `gpu_is_valid_utf8`)
are 3-line wrappers over the same session methods the suite files gate
exhaustively; restore direct calls here once the toolchain bug is
fixed.
"""

from emberjson import gpu_parse_document
from std.sys import has_accelerator
from std.testing import *


def test_gpu_one_shot_parse_document() raises:
    comptime if not has_accelerator():
        return
    else:
        var d = gpu_parse_document('{"x": [1, 2, 3]}')
        assert_equal(d.root()["x"][2].int(), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
