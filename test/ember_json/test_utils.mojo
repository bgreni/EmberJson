from ember_json.utils import write
from ember_json import Value
from testing import *

def test_string_builder_string():
    assert_equal(write(Value("foo bar")), '"foo bar"')

