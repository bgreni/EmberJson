from std.testing import assert_equal, TestSuite
from emberjson import Value, Object, Array, Null
from emberjson.patch._merge import merge_patch


def test_merge_simple_replace():
    var target = Value("foo")
    var patch = Value("bar")
    merge_patch(target, patch)
    assert_equal(target, "bar")

    target = Value(1)
    patch = Value(2)
    merge_patch(target, patch)
    assert_equal(target, 2)

    target = Value(True)
    patch = Value(Null())
    merge_patch(target, patch)
    assert_equal(target, Null())


def test_merge_object_add():
    var target = Value(Object())
    target.object()["a"] = Value("b")

    var patch = Value(Object())
    patch.object()["c"] = Value("d")

    merge_patch(target, patch)

    assert_equal(target["a"], "b")
    assert_equal(target["c"], "d")


def test_merge_object_remove():
    var target = Value(Object())
    target.object()["a"] = Value("b")
    target.object()["c"] = Value("d")

    var patch = Value(Object())
    patch.object()["a"] = Value(Null())

    merge_patch(target, patch)

    assert_equal(False, "a" in target.object())
    assert_equal(target["c"], "d")


def test_merge_object_replace():
    var target = Value(Object())
    target.object()["a"] = Value("b")

    var patch = Value(Object())
    patch.object()["a"] = Value("c")

    merge_patch(target, patch)

    assert_equal(target["a"], "c")


def test_merge_nested():
    var target = Value(Object())
    target.object()["title"] = Value("Goodbye!")

    var author = Object()
    author["givenName"] = Value("John")
    author["familyName"] = Value("Doe")
    target.object()["author"] = Value(author^)

    var tags = Array()
    tags.append(Value("example"))
    tags.append(Value("sample"))
    target.object()["tags"] = Value(tags^)

    target.object()["content"] = Value("This will be unchanged")

    # Patch
    var patch = Value(Object())
    patch.object()["title"] = Value("Hello!")
    patch.object()["phoneNumber"] = Value("+01-123-456-7890")

    var patch_author = Object()
    patch_author["familyName"] = Value(Null())  # Remove familyName
    patch.object()["author"] = Value(patch_author^)

    var patch_tags = Array()
    patch_tags.append(Value("example"))
    patch.object()["tags"] = Value(patch_tags^)  # Replace array completely

    merge_patch(target, patch)

    assert_equal(target["title"], "Hello!")
    assert_equal(target["author"]["givenName"], "John")
    assert_equal(False, "familyName" in target["author"].object())
    assert_equal(target["tags"][0], "example")
    assert_equal(len(target["tags"]), 1)
    assert_equal(target["content"], "This will be unchanged")
    assert_equal(target["phoneNumber"], "+01-123-456-7890")


def test_rfc7386_example():
    # Example from RFC 7386
    var target_json = String(
        "{"
        ' "title": "Goodbye!",'
        ' "author": {'
        ' "givenName": "John",'
        ' "familyName": "Doe"'
        " },"
        ' "tags": ["example", "sample"],'
        ' "content": "This will be unchanged"'
        "}"
    )
    var target = Value(parse_string=target_json)

    var patch_json = String(
        "{"
        ' "title": "Hello!",'
        ' "phoneNumber": "+01-123-456-7890",'
        ' "author": {'
        ' "familyName": null'
        " },"
        ' "tags": ["example"]'
        "}"
    )
    var patch = Value(parse_string=patch_json)

    merge_patch(target, patch)

    assert_equal(target["title"], "Hello!")
    assert_equal(target["author"]["givenName"], "John")
    assert_equal(False, "familyName" in target["author"].object())
    assert_equal(target["tags"][0], "example")
    assert_equal(len(target["tags"]), 1)
    assert_equal(target["content"], "This will be unchanged")
    assert_equal(target["phoneNumber"], "+01-123-456-7890")


def test_array_replace():
    # Arrays are replaced, not merged
    var target = Value(Array())
    target.array().append(Value(1))

    var patch = Value(Array())
    patch.array().append(Value(2))

    merge_patch(target, patch)

    assert_equal(len(target.array()), 1)
    assert_equal(target[0], 2)


def test_null_patch():
    # Null patch implies deletion/null replacement for root?
    # If target is root Value, and patch is null:
    # merge_patch(target, null) -> target = null
    var target = Value("foo")
    merge_patch(target, Null())
    assert_equal(target, Null())


def test_merge_from_string():
    var target = Value(Object())
    target.object()["a"] = Value("b")

    var patch_str = '{"a": "c", "d": "e"}'
    merge_patch(target, patch_str)

    assert_equal(target["a"], "c")
    assert_equal(target["d"], "e")


def test_merge_null_string():
    var target = Value("foo")
    merge_patch(target, "null")
    assert_equal(target, Null())


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
