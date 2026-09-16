from std.testing import assert_equal, assert_raises, TestSuite
from emberjson import Value, Object, Array, from_json, to_json
from emberjson.patch._patch import patch


def test_patch_add() raises:
    # Test add to object
    var doc = Value(Object())
    var patch_ops = Array()
    var op = Object()
    op["op"] = Value("add")
    op["path"] = Value("/foo")
    op["value"] = Value("bar")
    patch_ops.append(Value(op.copy()))

    patch(doc, patch_ops)
    assert_equal(doc["foo"], "bar")

    # Test add to array
    var arr = Array()
    arr.append(Value(1))
    doc = Value(arr^)
    patch_ops = Array()
    op = Object()
    op["op"] = Value("add")
    op["path"] = Value("/-")
    op["value"] = Value(2)
    patch_ops.append(Value(op.copy()))

    patch(doc, patch_ops)
    assert_equal(doc[1], 2)

    # Test add to array insert
    op["path"] = Value("/0")
    op["value"] = Value(0)
    patch_ops = Array()
    patch_ops.append(Value(op.copy()))

    patch(doc, patch_ops)
    assert_equal(doc[0], 0)
    assert_equal(doc[1], 1)


def test_patch_remove() raises:
    var obj = Object()
    obj["foo"] = Value("bar")
    var doc = Value(obj^)

    var patch_ops = Array()
    var op = Object()
    op["op"] = Value("remove")
    op["path"] = Value("/foo")
    patch_ops.append(Value(op^))

    patch(doc, patch_ops)
    assert_equal(len(doc.object().keys()), 0)


def test_patch_replace() raises:
    var obj = Object()
    obj["foo"] = Value("bar")
    var doc = Value(obj^)

    var patch_ops = Array()
    var op = Object()
    op["op"] = Value("replace")
    op["path"] = Value("/foo")
    op["value"] = Value("baz")
    patch_ops.append(Value(op^))

    patch(doc, patch_ops)
    assert_equal(doc["foo"], "baz")


def test_patch_move() raises:
    var obj = Object()
    obj["foo"] = Value("bar")
    var doc = Value(obj^)

    var patch_ops = Array()
    var op = Object()
    op["op"] = Value("move")
    op["from"] = Value("/foo")
    op["path"] = Value("/baz")
    patch_ops.append(Value(op^))

    patch(doc, patch_ops)
    assert_equal(doc["baz"], "bar")


def test_patch_copy() raises:
    var obj = Object()
    obj["foo"] = Value("bar")
    var doc = Value(obj^)

    var patch_ops = Array()
    var op = Object()
    op["op"] = Value("copy")
    op["from"] = Value("/foo")
    op["path"] = Value("/baz")
    patch_ops.append(Value(op^))

    patch(doc, patch_ops)
    assert_equal(doc["foo"], "bar")
    assert_equal(doc["baz"], "bar")


def test_patch_test() raises:
    var obj = Object()
    obj["foo"] = Value("bar")
    var doc = Value(obj^)

    var patch_ops = Array()
    var op = Object()
    op["op"] = Value("test")
    op["path"] = Value("/foo")
    op["value"] = Value("bar")
    patch_ops.append(Value(op.copy()))

    patch(doc, patch_ops)  # Should succeed

    op["value"] = Value("baz")
    patch_ops = Array()
    patch_ops.append(Value(op^))

    var failed = False
    try:
        patch(doc, patch_ops)
    except:
        failed = True
    assert_equal(failed, True)


def test_patch_from_string() raises:
    var doc = Value(Object())
    # Define a patch string with multiple operations
    # 1. Add /foo: "bar"
    # 2. Add /baz: "qux"
    # 3. Replace /foo: "changed"
    var patch_str = String(
        "["
        '  {"op": "add", "path": "/foo", "value": "bar"},'
        '  {"op": "add", "path": "/baz", "value": "qux"},'
        '  {"op": "replace", "path": "/foo", "value": "changed"}'
        "]"
    )

    patch(doc, patch_str)

    assert_equal(doc["foo"], "changed")
    assert_equal(doc["baz"], "qux")


def test_non_string_op_path_from_are_rejected_and_leave_doc_unchanged() raises:
    var doc = from_json[Value]('{"a": 1}')
    var bad: List[String] = [
        '[{"op": 1, "path": "/a", "value": 2}]',
        '[{"op": null, "path": "/a", "value": 2}]',
        '[{"op": true, "path": "/a", "value": 2}]',
        '[{"op": [], "path": "/a", "value": 2}]',
        '[{"op": {}, "path": "/a", "value": 2}]',
        '[{"op": 1e308, "path": "/a", "value": 2}]',
        '[{"op": "add", "path": 1, "value": 2}]',
        '[{"op": "add", "path": null, "value": 2}]',
        '[{"op": "add", "path": {}, "value": 2}]',
        '[{"op": "add", "path": [], "value": 2}]',
        '[{"op": "add", "path": true, "value": 2}]',
        '[{"op": "add", "path": 9007199254740993, "value": 2}]',
        '[{"op": "remove", "path": 1}]',
        '[{"op": "replace", "path": 1e308, "value": 2}]',
        '[{"op": "test", "path": false, "value": 2}]',
        '[{"op": "move", "from": 1, "path": "/b"}]',
        '[{"op": "copy", "from": {}, "path": "/b"}]',
    ]
    for s in bad:
        with assert_raises():
            patch(doc, s)
        assert_equal(to_json(doc), '{"a":1}')


def test_non_string_root_path_does_not_replace_document() raises:
    var doc = from_json[Value]("{}")
    with assert_raises():
        patch(doc, '[{"op": "add", "path": {}, "value": 1}]')
    assert_equal(to_json(doc), "{}")


def test_op_test_uses_numeric_equality() raises:
    var docs: List[String] = [
        '{"a":1}',
        '{"a":1.0}',
        '{"a":100}',
        '{"a":1e2}',
        '{"a":3}',
        '{"a":-0.0}',
        '{"a":[1]}',
        '{"a":{"x":1}}',
    ]
    var values: List[String] = [
        "1.0",
        "1",
        "1e2",
        "100",
        "3e0",
        "0",
        "[1.0]",
        '{"x":1.0}',
    ]
    for i in range(len(docs)):
        var doc = from_json[Value](docs[i])
        patch(doc, '[{"op":"test","path":"/a","value":' + values[i] + "}]")


def test_op_test_still_distinguishes_types_and_values() raises:
    var docs: List[String] = [
        '{"a":"1"}',
        '{"a":true}',
        '{"a":false}',
        '{"a":false}',
        '{"a":2}',
    ]
    var values: List[String] = ["1", "1", "0", "null", "2.0000000000000004"]
    for i in range(len(docs)):
        var doc = from_json[Value](docs[i])
        with assert_raises():
            patch(doc, '[{"op":"test","path":"/a","value":' + values[i] + "}]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
