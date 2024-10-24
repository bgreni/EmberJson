from ember_json.reader import Reader
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
    r = Reader("Some String".as_bytes())
    r.inc()
    assert_true(r.peek() == ord("o"))

def test_next():
    r = Reader("Some String".as_bytes())
    assert_true(compare(r.next(4), String("Some").as_bytes()))

def test_read_until():
    r = Reader("Some String".as_bytes())
    assert_true(compare(r.read_until(ord("r")), String("Some St").as_bytes()))