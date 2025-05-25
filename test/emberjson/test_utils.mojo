from emberjson.utils import write, estimate_bytes_to_write
from emberjson import Value
from testing import assert_equal, assert_true


def test_string_builder_string():
    assert_equal(write(Value("foo bar")), '"foo bar"')


def estimate_bytes_to_write_int():
    assert_equal(estimate_bytes_to_write(123), 3)
    assert_equal(estimate_bytes_to_write(-123), 4)
    assert_equal(estimate_bytes_to_write(1234567890), 10)
    assert_equal(estimate_bytes_to_write(-1234567890), 11)


def estimate_bytes_to_write_float():
    assert_true(estimate_bytes_to_write(Float64(1.0)) >= 2)
    assert_true(estimate_bytes_to_write(Float64(-1.0)) >= 3)
    assert_true(estimate_bytes_to_write(Float64(0.1)) >= 3)
    assert_true(estimate_bytes_to_write(Float64(-0.1)) >= 4)
    assert_true(estimate_bytes_to_write(Float64(1e123)) >= 5)
    assert_true(estimate_bytes_to_write(Float64(-1e123)) >= 6)
    assert_true(estimate_bytes_to_write(Float64(1e-123)) >= 6)
    assert_true(estimate_bytes_to_write(Float64(-1e-123)) >= 7)
    assert_true(estimate_bytes_to_write(Float64(1.23e123)) >= 8)
    assert_true(estimate_bytes_to_write(Float64(-1.23e123)) >= 9)
    assert_true(estimate_bytes_to_write(Float64(1.23e-123)) >= 9)
    assert_true(estimate_bytes_to_write(Float64(-1.23e-123)) >= 10)
    assert_true(estimate_bytes_to_write(Float64(0.3)) >= 3)
    assert_true(estimate_bytes_to_write(Float64(-0.3)) >= 4)
