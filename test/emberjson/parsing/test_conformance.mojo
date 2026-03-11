from emberjson import parse
from std.testing import assert_raises, TestSuite
from std.sys.param_env import is_defined


@always_inline
fn files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


comptime dir = String("./bench_data/data/jsonchecker/")


def expect_fail(datafile: String) raises:
    comptime if files_enabled():
        with open(String(dir, datafile, ".json"), "r") as f:
            with assert_raises():
                var v = parse(f.read())
                print(v)


def expect_pass(datafile: String) raises:
    comptime if files_enabled():
        with open(String(dir, datafile, ".json"), "r") as f:
            _ = parse(f.read())


def test_fail02() raises:
    expect_fail("fail02")


def test_fail03() raises:
    expect_fail("fail03")


def test_fail04() raises:
    expect_fail("fail04")


def test_fail05() raises:
    expect_fail("fail05")


def test_fail06() raises:
    expect_fail("fail06")


def test_fail07() raises:
    expect_fail("fail07")


def test_fail08() raises:
    expect_fail("fail08")


def test_fail09() raises:
    expect_fail("fail09")


def test_fail10() raises:
    expect_fail("fail10")


def test_fail11() raises:
    expect_fail("fail11")


def test_fail12() raises:
    expect_fail("fail12")


def test_fail13() raises:
    expect_fail("fail13")


def test_fail14() raises:
    expect_fail("fail14")


def test_fail15() raises:
    expect_fail("fail15")


def test_fail16() raises:
    expect_fail("fail16")


def test_fail17() raises:
    expect_fail("fail17")


def test_fail19() raises:
    expect_fail("fail19")


def test_fail20() raises:
    expect_fail("fail20")


def test_fail21() raises:
    expect_fail("fail21")


def test_fail22() raises:
    expect_fail("fail22")


def test_fail23() raises:
    expect_fail("fail23")


def test_fail24() raises:
    expect_fail("fail24")


def test_fail25() raises:
    expect_fail("fail25")


def test_fail26() raises:
    expect_fail("fail26")


def test_fail27() raises:
    expect_fail("fail27")


def test_fail28() raises:
    expect_fail("fail28")


def test_fail29() raises:
    expect_fail("fail29")


def test_fail30() raises:
    expect_fail("fail30")


def test_fail31() raises:
    expect_fail("fail31")


def test_fail32() raises:
    expect_fail("fail32")


def test_fail33() raises:
    expect_fail("fail33")


def test_pass() raises:
    expect_pass("pass01")
    expect_pass("pass02")
    expect_pass("pass03")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
