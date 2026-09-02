from emberjson.simd import HAS_BYTE_SHUFFLE, KERNEL_WIDTH, lookup, SIMD8
from std.testing import assert_equal, assert_true, TestSuite


comptime _TABLE = SIMD8[16](3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3)


def _check_width[W: Int]() raises:
    """`lookup` must equal a scalar table index in every lane, for every
    index value, at every lane position."""
    comptime if HAS_BYTE_SHUFFLE:
        # A vector whose lane i holds (i + rot) % 16 exercises every
        # index value in every lane position as rot sweeps 0..15.
        for rot in range(16):
            var idx = SIMD8[W](0)
            for lane in range(W):
                idx[lane] = Byte((lane + rot) % 16)
            var got = lookup[W](_TABLE, idx)
            for lane in range(W):
                assert_equal(
                    got[lane],
                    _TABLE[Int(idx[lane])],
                    "W="
                    + String(W)
                    + " rot="
                    + String(rot)
                    + " lane="
                    + String(lane),
                )
        # All-same-index splats: catches a table that is tiled wrongly
        # in the upper 128-bit lanes.
        for v in range(16):
            var idx = SIMD8[W](Byte(v))
            var got = lookup[W](_TABLE, idx)
            for lane in range(W):
                assert_equal(
                    got[lane],
                    _TABLE[v],
                    "splat W="
                    + String(W)
                    + " v="
                    + String(v)
                    + " lane="
                    + String(lane),
                )


def test_lookup_width_16() raises:
    _check_width[16]()


def test_lookup_width_32() raises:
    _check_width[32]()


def test_lookup_width_64() raises:
    # Not a shipped configuration (KERNEL_WIDTH is capped at 32), but
    # tested so that raising the cap later is a one-line change rather
    # than a re-validation.
    _check_width[64]()


def test_kernel_width_is_a_shipped_configuration() raises:
    assert_true(KERNEL_WIDTH == 16 or KERNEL_WIDTH == 32)
    assert_true(64 % KERNEL_WIDTH == 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
