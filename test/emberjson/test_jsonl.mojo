from emberjson import read_lines, Object
from testing import *
from sys.param_env import is_defined


def test_read_lines():
    if is_defined["DISABLE_TEST_FILES"]():
        return

    var lines = List[Object]({"test": 1}, {"test": 2}, {"test": 3}, {"test": 4})

    var i = 0

    for line in read_lines("./bench_data/jsonl.jsonl"):
        assert_equal(line, lines[i].copy())
        i += 1


def test_read_lines_big():
    if is_defined["DISABLE_TEST_FILES"]():
        return

    var i = 0
    for line in read_lines("./bench_data/big_lines.jsonl"):
        assert_equal(line.object(), Object({"key": i}))
        i += 1

def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
