# Deeply nested reflection input must fail with a `DeserializationError`, not
# overflow the stack. Kept in its own file because a failure here is a crash,
# which would hide every other result in a shared test file.
#
# 7000 levels is well inside what the reflection path handled before the
# `List` deserializer's per-level stack use grew (~15,800 levels on an 8 MB
# stack), and fails either way a fix goes: smaller frames, or a depth limit.
#
# Depth counts JSON containers, arrays and objects combined, root = 1, as the
# `Value` parser always has: `ParseOptions.max_depth` levels parse, one more
# raises. One `Node` level is two containers (`{` and its `kids` `[`).

from std.testing import TestSuite, assert_true, assert_raises
from emberjson import from_json, ParseOptions, Value, Document
from emberjson._serde import from_json_bytewalk, from_json_indexed


@fieldwise_init
struct Node(Copyable, Defaultable, Movable):
    var v: Int
    var kids: List[Node]

    def __init__(out self):
        self.v = 0
        self.kids = List[Node]()

    # A recursive `List[Node]` field is not implicitly `Deinitable`.
    def __deinit__(deinit self):
        pass


@fieldwise_init
struct Holder(Defaultable, Movable):
    var a: Int

    def __init__(out self):
        self.a = 0


def _nested(depth: Int, leaf: String) -> String:
    var s = String()
    for _ in range(depth):
        s += '{"v":1,"kids":['
    s += leaf
    for _ in range(depth):
        s += "]}"
    return s


def _wrap(open: String, close: String, n: Int, middle: String) -> String:
    var s = String()
    for _ in range(n):
        s += open
    s += middle
    for _ in range(n):
        s += close
    return s^


def _is_depth_error[
    T: Movable & Deinitable, options: ParseOptions = ParseOptions()
](s: String) -> Bool:
    try:
        _ = from_json[T, options](s)
    except e:
        return "Exceeded maximum nesting depth" in String(e)
    return False


def test_malformed_deep_list_is_an_error_not_a_crash() raises:
    var raised = False
    try:
        _ = from_json[Node](_nested(7000, '{"v":"x","kids":[]}'))
    except:
        raised = True
    assert_true(raised)


def test_valid_deep_list_is_an_error_not_a_crash() raises:
    var s = _nested(12_000, '{"v":1,"kids":[]}')
    assert_true(_is_depth_error[Node](s))
    with assert_raises():
        _ = from_json_bytewalk[Node](s)
    with assert_raises():
        _ = from_json_indexed[Node](s)


def test_reflection_default_limit_boundary() raises:
    # `_nested(k, "")` ends in an empty `kids` array: 2k containers.
    var d1023 = "[" + _nested(511, "") + "]"
    var d1024 = _nested(512, "")
    var d1025 = "[" + _nested(512, "") + "]"
    _ = from_json[List[Node]](d1023)
    _ = from_json_bytewalk[List[Node]](d1023)
    _ = from_json_indexed[List[Node]](d1023)
    _ = from_json[Node](d1024)
    _ = from_json_bytewalk[Node](d1024)
    _ = from_json_indexed[Node](d1024)
    assert_true(_is_depth_error[List[Node]](d1025))
    with assert_raises(contains="Exceeded maximum nesting depth"):
        _ = from_json_bytewalk[List[Node]](d1025)
    with assert_raises():
        _ = from_json_indexed[List[Node]](d1025)


comptime O16 = ParseOptions(max_depth=16)


def test_custom_limit_reflection() raises:
    _ = from_json[Node, O16](_nested(8, ""))
    _ = from_json_bytewalk[Node, O16](_nested(8, ""))
    _ = from_json_indexed[Node, O16](_nested(8, ""))
    # Keys out of order: the indexed engine's in-order read enters each
    # `{`, then rewinds to the framework's driver, which enters it again.
    var rev = String()
    for _ in range(8):
        rev += '{"kids":['
    for _ in range(8):
        rev += '],"v":1}'
    _ = from_json_indexed[Node, O16](rev)
    var d17 = "[" + _nested(8, "") + "]"
    assert_true(_is_depth_error[List[Node], O16](d17))
    with assert_raises(contains="Exceeded maximum nesting depth"):
        _ = from_json_bytewalk[List[Node], O16](d17)
    with assert_raises():
        _ = from_json_indexed[List[Node], O16](d17)


def test_custom_limit_value_and_document() raises:
    # Short inputs take the byte-walk builders, padded ones (>= 128 bytes)
    # the indexed tape builder; both must honor the limit.
    var pad = String(" ") * 200
    for p in [String(""), pad]:
        var arr16 = _wrap("[", "]", 16, "") + p
        var obj16 = _wrap('{"a":', "}", 16, "1") + p
        var arr17 = _wrap("[", "]", 17, "") + p
        var obj17 = _wrap('{"a":', "}", 17, "1") + p
        _ = from_json[Value, O16](arr16)
        _ = from_json[Value, O16](obj16)
        _ = from_json[Document, O16](arr16)
        _ = from_json[Document, O16](obj16)
        assert_true(_is_depth_error[Value, O16](arr17))
        assert_true(_is_depth_error[Value, O16](obj17))
        assert_true(_is_depth_error[Document, O16](arr17))
        assert_true(_is_depth_error[Document, O16](obj17))


def test_custom_limit_skipped_and_value_fields() raises:
    # Unknown-field skips and `Value` fields count from the enclosing
    # struct's depth, like everything else.
    var ok = '{"a":1,"x":' + _wrap("[", "]", 15, "") + "}"
    var deep = '{"a":1,"x":' + _wrap("[", "]", 16, "") + "}"
    _ = from_json[Holder, O16](ok)
    assert_true(_is_depth_error[Holder, O16](deep))
    with assert_raises():
        _ = from_json_indexed[Holder, O16](deep)
    _ = from_json[List[Value], O16](_wrap("[", "]", 16, ""))
    assert_true(_is_depth_error[List[Value], O16](_wrap("[", "]", 17, "")))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
