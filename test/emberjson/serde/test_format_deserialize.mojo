from std.testing import assert_equal, TestSuite
from emberjson._serde import from_json_string
from emberserde.error import DerErrorKind


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


@fieldwise_init
struct Outer(Copyable, Defaultable, Movable):
    var label: String
    var inner: Point

    def __init__(out self):
        self.label = String()
        self.inner = Point()


def test_struct_from_wire() raises:
    var p = from_json_string[Point]('{"x":1,"y":2}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_missing_field_reports_kind_and_path() raises:
    # `assert_true(False)` inside the `try` won't compile here: it raises
    # the untyped `Error`, while `from_json_string` raises the typed
    # `DeserializationError`, and a single `try` block can't mix raise
    # types under Mojo's typed-raises inference. Use a sentinel instead
    # (same idiom as emberserde's own `test_missing_field_raises`): if the
    # call doesn't raise, `kind` keeps its wrong default and the assertion
    # below fails.
    var kind = DerErrorKind.Custom
    try:
        _ = from_json_string[Point]('{"x":1}')
    except e:
        kind = e.kind
    assert_equal(String(kind), String("MissingField"))


def test_list_from_wire() raises:
    var xs = from_json_string[List[Int]]("[1,2,3]")
    assert_equal(len(xs), 3)
    assert_equal(xs[2], 3)


def test_error_path_points_at_nested_field() raises:
    var path = String("unset")
    try:
        _ = from_json_string[Outer]('{"label":"a","inner":{"x":1}}')
    except e:
        path = e.path
    assert_equal(path, String(".inner"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
