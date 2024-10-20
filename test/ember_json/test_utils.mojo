from ember_json.utils import StringBuilder
from ember_json import Value
from testing import *

def test_string_builder_string():
    var s = StringBuilder(7)
    s.write(Value("foo bar"))
    assert_equal(s.build(), '"foo bar"')

