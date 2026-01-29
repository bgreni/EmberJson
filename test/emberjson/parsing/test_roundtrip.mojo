from emberjson import parse
from testing import assert_equal, TestSuite
from sys.param_env import is_defined


@always_inline
fn files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


def round_trip_test(filename: String):
    @parameter
    if files_enabled():
        var d = String("./bench_data/data/roundtrip/")
        with open(String(d, filename, ".json"), "r") as f:
            var src = f.read()
            var json = parse(src)
            assert_equal(String(json), src)


def test_roundtrip01():
    round_trip_test("roundtrip01")


def test_roundtrip02():
    round_trip_test("roundtrip02")


def test_roundtrip03():
    round_trip_test("roundtrip03")


def test_roundtrip04():
    round_trip_test("roundtrip04")


def test_roundtrip05():
    round_trip_test("roundtrip05")


def test_roundtrip06():
    round_trip_test("roundtrip06")


def test_roundtrip07():
    round_trip_test("roundtrip07")


def test_roundtrip08():
    round_trip_test("roundtrip08")


def test_roundtrip09():
    round_trip_test("roundtrip09")


def test_roundtrip10():
    round_trip_test("roundtrip10")


def test_roundtrip11():
    round_trip_test("roundtrip11")


def test_roundtrip12():
    round_trip_test("roundtrip12")


def test_roundtrip13():
    round_trip_test("roundtrip13")


def test_roundtrip14():
    round_trip_test("roundtrip14")


def test_roundtrip15():
    round_trip_test("roundtrip15")


def test_roundtrip16():
    round_trip_test("roundtrip16")


def test_roundtrip17():
    round_trip_test("roundtrip17")


def test_roundtrip18():
    round_trip_test("roundtrip18")


def test_roundtrip19():
    round_trip_test("roundtrip19")


def test_roundtrip20():
    round_trip_test("roundtrip20")


def test_roundtrip21():
    round_trip_test("roundtrip21")


def test_roundtrip22():
    round_trip_test("roundtrip22")


def test_roundtrip23():
    round_trip_test("roundtrip23")


def test_roundtrip27():
    round_trip_test("roundtrip27")


def test_roundtrip24():
    round_trip_test("roundtrip24")


def test_roundtrip25():
    round_trip_test("roundtrip25")


def test_roundtrip26():
    round_trip_test("roundtrip26")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
