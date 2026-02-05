from std.testing import assert_equal, assert_raises, TestSuite
from emberjson import Value, Object, Array
from emberjson.patch._patch import patch


def test_patch_add():
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


def test_patch_remove():
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


def test_patch_replace():
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


def test_patch_move():
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


def test_patch_copy():
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


def test_patch_test():
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


def test_patch_from_string():
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


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
