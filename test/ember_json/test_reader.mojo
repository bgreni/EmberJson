from ember_json.reader import Reader, StringBlock
from ember_json.simd import *
from ember_json.utils import Bytes
from testing import *

def compare(l: Bytes, r: Bytes):
    if len(l) != len(r):
        return False
    for i in range(len(l)):
        if l[i] != r[i]:
            return False
    return True

def test_peek():
    var r = Reader("Some String".as_bytes())
    r.inc()
    assert_true(r.peek() == ord("o"))

def test_next():
    var r = Reader("Some String".as_bytes())
    assert_true(compare(r.next(4), String("Some").as_bytes()))

def test_read_until():
    var r = Reader("Some String".as_bytes())
    assert_true(compare(r.read_until(ord("r")), String("Some St").as_bytes()))

def test_get_nonspace_bits():
    var r = Reader("   as   ".as_bytes())
    var bits = r.get_non_space_bits(r.ptr().load[width=8]())
    assert_equal(bits, SIMD[DType.bool, 8](False, False, False, True, True, False, False, False))

def test_stringblock():
    # pad it out for platforms with longer vector lengths
    var s = String(' a str"' + (' ' * 100))
    var block = StringBlock.find(s.unsafe_ptr())
    assert_equal(block.quote_index(), 6)
    assert_true(block.has_quote_first())

    s = String('a str "\n'+ (' ' * 100))
    block = StringBlock.find(s.unsafe_ptr())
    assert_equal(block.quote_index(), 6)
    assert_equal(block.unescaped_index(), 7)
    # assert_true(block.has_quote_first())
    assert_false(block.has_unescaped())

    s = R'\"",\n' + '           "backslash": "\\"}'
    block = StringBlock.find(s.unsafe_ptr())
    assert_false(block.has_unescaped(), "Expected has_unescaped to be false")
    assert_true(block.has_backslash(), "Expected has_backslash to be true")
    assert_false(block.has_quote_first(), "Expected has_quote_first to be false")
    assert_equal(block.quote_index(), 1)


