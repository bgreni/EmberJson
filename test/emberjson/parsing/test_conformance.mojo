from emberjson import parse
from testing import assert_raises, TestSuite
from sys.param_env import is_defined


@always_inline
fn files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


comptime dir = String("./bench_data/data/jsonchecker/")


def expect_fail(datafile: String):
    @parameter
    if files_enabled():
        with open(String(dir, datafile, ".json"), "r") as f:
            with assert_raises():
                var v = parse(f.read())
                print(v)


def expect_pass(datafile: String):
    @parameter
    if files_enabled():
        with open(String(dir, datafile, ".json"), "r") as f:
            _ = parse(f.read())


def test_fail02():
    expect_fail("fail02")


def test_fail03():
    expect_fail("fail03")


def test_fail04():
    expect_fail("fail04")


def test_fail05():
    expect_fail("fail05")


def test_fail06():
    expect_fail("fail06")


def test_fail07():
    expect_fail("fail07")


def test_fail08():
    expect_fail("fail08")


def test_fail09():
    expect_fail("fail09")


def test_fail10():
    expect_fail("fail10")


def test_fail11():
    expect_fail("fail11")


def test_fail12():
    expect_fail("fail12")


def test_fail13():
    expect_fail("fail13")


def test_fail14():
    expect_fail("fail14")


def test_fail15():
    expect_fail("fail15")


def test_fail16():
    expect_fail("fail16")


def test_fail17():
    expect_fail("fail17")


def test_fail19():
    expect_fail("fail19")


def test_fail20():
    expect_fail("fail20")


def test_fail21():
    expect_fail("fail21")


def test_fail22():
    expect_fail("fail22")


def test_fail23():
    expect_fail("fail23")


def test_fail24():
    expect_fail("fail24")


def test_fail25():
    expect_fail("fail25")


def test_fail26():
    expect_fail("fail26")


def test_fail27():
    expect_fail("fail27")


def test_fail28():
    expect_fail("fail28")


def test_fail29():
    expect_fail("fail29")


def test_fail30():
    expect_fail("fail30")


def test_fail31():
    expect_fail("fail31")


def test_fail32():
    expect_fail("fail32")


def test_fail33():
    expect_fail("fail33")


def test_pass():
    expect_pass("pass01")
    expect_pass("pass02")
    expect_pass("pass03")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
