from emberjson.utils import write
from emberjson import Value
from testing import assert_equal


def test_string_builder_string():
    assert_equal(write(Value("foo bar")), '"foo bar"')
