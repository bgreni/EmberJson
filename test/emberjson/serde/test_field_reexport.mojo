"""`from emberjson import Field` must be self-sufficient.

`Field.__getitem__` is added by an `__extension`, and an extension method
only resolves where the module declaring it is itself in scope. It first
landed in `emberjson/schema.mojo`, which made
`from emberjson import Defaulted` followed by `f[]` a compile error
("not subscriptable") unless the caller *also* imported
`emberjson.schema` — a trap the existing schema tests could never catch,
because they import both. This file deliberately imports nothing but the
`emberjson` facade so that regression cannot come back.
"""

from emberjson import Defaulted, Field, from_json, to_json
from std.testing import assert_equal, TestSuite


def test_subscript_resolves_from_the_facade_alone() raises:
    var f = Defaulted[Int, 42](7)
    assert_equal(f[], 7)
    # emberserde's own spelling keeps working too.
    assert_equal(f.value, 7)

    var d = Defaulted[Int, 42]()
    assert_equal(d[], 42)

    var s = Field[String](String("hi"))
    assert_equal(s[], "hi")


def test_public_entry_points_resolve_from_the_facade_alone() raises:
    assert_equal(from_json[Defaulted[Int, 42]]("10")[], 10)
    assert_equal(to_json(Defaulted[Int, 42](10)), "10")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
