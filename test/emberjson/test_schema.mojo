from emberjson import (
    from_json,
    to_json,
    Alias,
    AnyOf,
    Default,
    Enum,
    Eq,
    NonEmpty,
    Range,
    Rename,
    SerializeWith,
    Size,
    Skip,
    Transform,
    Validate,
    Value,
    coerce_float,
    coerce_int,
    coerce_string,
    coerce_uint,
    clamp,
)
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


# What a failing `from_json[T](s)` raised. The sentinel idiom is emberserde's:
# `assert_true(False)` inside the `try` would not compile, because one `try`
# block cannot mix the typed and untyped raise flavours.
@fieldwise_init
struct _Failure(Copyable, Movable):
    var kind: String
    var message: String
    var path: String


def _failure_of[T: Movable & Deinitable](s: String) raises -> _Failure:
    var f = _Failure("<did not raise>", "", "")
    try:
        _ = from_json[T](s)
    except e:
        f = _Failure(String(e.kind), e.message, e.path)
    return f^


@fieldwise_init
struct Volume(Movable):
    @__annotation(Transform(clamp[0, 10]))
    var v: Int


def test_clamp() raises:
    # Pulled into range on read instead of rejected.
    assert_equal(from_json[Volume]('{"v":5}').v, 5)
    assert_equal(from_json[Volume]('{"v":-5}').v, 0)
    assert_equal(from_json[Volume]('{"v":15}').v, 10)


@fieldwise_init
struct Coerced(Defaultable, Movable):
    @__annotation(Transform(coerce_int))
    var i: Int64

    @__annotation(Transform(coerce_uint))
    var u: UInt64

    @__annotation(Transform(coerce_float))
    var f: Float64

    @__annotation(Transform(coerce_string))
    var s: String

    def __init__(out self):
        self.i = 0
        self.u = 0
        self.f = 0
        self.s = String()


def _coerced(i: String, u: String, f: String, s: String) -> String:
    return '{"i":' + i + ',"u":' + u + ',"f":' + f + ',"s":' + s + "}"


def test_coerce_through_transform() raises:
    var c = from_json[Coerced](_coerced('"123"', '"123"', '"123.45"', '"123"'))
    assert_equal(c.i, 123)
    assert_equal(c.u, 123)
    assert_equal(c.f, 123.45)
    assert_equal(c.s, "123")

    c = from_json[Coerced](_coerced("123.45", "123.45", "123", "123.45"))
    assert_equal(c.i, 123)
    assert_equal(c.u, 123)
    assert_equal(c.f, 123.0)
    assert_equal(c.s, "123.45")

    c = from_json[Coerced](_coerced("0", "123", "123.45", "null"))
    assert_equal(c.i, 0)
    assert_equal(c.s, "null")

    var f = _failure_of[Coerced](_coerced("null", "1", "1", "1"))
    assert_equal(f.kind, "InvalidValue")
    assert_equal(f.message, "Value cannot be converted to an integer")
    assert_equal(f.path, ".i")
    assert_equal(
        _failure_of[Coerced](_coerced("1", "null", "1", "1")).message,
        "Value cannot be converted to an unsigned integer",
    )
    assert_equal(
        _failure_of[Coerced](_coerced("1", "1", "null", "1")).message,
        "Value cannot be converted to a float",
    )


def test_coerce_rejects_out_of_range() raises:
    # Parsed outside the `assert_raises` blocks: one block cannot mix
    # `from_json`'s typed raise with the coercions' untyped one.
    var neg_int = from_json[Value]("-5")
    var neg_float = from_json[Value]("-1.5")
    var u64_max = from_json[Value]("18446744073709551615")
    var huge = from_json[Value]("1e300")
    var i64_min = from_json[Value]("-9223372036854775808")

    # Out-of-range numbers raise instead of wrapping or saturating.
    with assert_raises(contains="an unsigned integer"):
        _ = coerce_uint(neg_int)
    with assert_raises(contains="an unsigned integer"):
        _ = coerce_uint(neg_float)
    with assert_raises(contains="an integer"):
        _ = coerce_int(u64_max)
    with assert_raises(contains="an integer"):
        _ = coerce_int(huge)
    assert_equal(coerce_float(u64_max), Float64(UInt64.MAX))
    # The in-range extremes still convert.
    assert_equal(coerce_uint(u64_max), UInt64.MAX)
    assert_equal(coerce_int(i64_min), Int64.MIN)


def coerce_bool_or_number(v: Value) raises -> Int:
    if v.is_int():
        return Int(v.int())
    elif v.is_string():
        return Int(v.string())
    elif v.is_float():
        return Int(v.float())
    elif v.is_bool():
        return Int(v.bool())
    raise Error("Invalid value")


@fieldwise_init
struct CustomCoerced(Movable):
    @__annotation(Transform(coerce_bool_or_number))
    var n: Int


def test_custom_coercion() raises:
    assert_equal(from_json[CustomCoerced]('{"n":"123"}').n, 123)
    assert_equal(from_json[CustomCoerced]('{"n":123.45}').n, 123)
    assert_equal(from_json[CustomCoerced]('{"n":true}').n, 1)


def date_to_int(s: String) -> Int:
    if s == "2024-01-01":
        return 1
    return 0


@fieldwise_init
struct Dated(Movable):
    @__annotation(Transform(date_to_int))
    var day: Int


def test_transform() raises:
    assert_equal(from_json[Dated]('{"day":"2024-01-01"}').day, 1)
    # One-way: written back as the field's own type.
    assert_equal(to_json(Dated(1)), '{"day":1}')


struct TestDefault(Movable):
    var a: Int

    @__annotation(Default(42))
    var b: Int


struct TestOptDefault(Movable):
    var a: Int

    @__annotation(Default(Optional[Int](42)))
    var b: Optional[Int]


def test_default() raises:
    var d3 = from_json[TestDefault]('{"a": 10}')
    assert_equal(d3.a, 10)
    assert_equal(d3.b, 42)
    assert_equal(to_json(d3), '{"a":10,"b":42}')

    # A present key still wins over the default.
    var d4 = from_json[TestDefault]('{"a": 10, "b": 7}')
    assert_equal(d4.b, 7)

    # The default fills a *missing key* only: an explicit `null` is a
    # present value on the wire and is parsed as `Int`.
    with assert_raises():
        _ = from_json[TestDefault]('{"a": 10, "b": null}')

    # The escape hatch for null-tolerance: make the field itself
    # `Optional`, so `null` binds `None` while a missing key still takes
    # the default rather than binding None.
    var d2b = from_json[TestOptDefault]('{"a": 10}')
    assert_true(d2b.b)
    assert_equal(d2b.b.value(), 42)

    var d2c = from_json[TestOptDefault]('{"a": 10, "b": null}')
    assert_false(d2c.b)


# ===========================================================================
# emberserde's field annotations through the `emberjson` facade.
# ===========================================================================


@fieldwise_init
struct Renamed(Movable):
    var a: Int

    @__annotation(Rename("bee"), Default(7))
    var b: Int


@fieldwise_init
struct Skipped(Movable):
    var a: Int

    @__annotation(Skip(), Default(3))
    var b: Int


@fieldwise_init
struct Aliased(Movable):
    @__annotation(Alias("a_alt"))
    var a: Int


def test_field_rename_skip_and_aliases() raises:
    var renamed = from_json[Renamed]('{"a":1,"bee":2}')
    assert_equal(renamed.b, 2)
    # The default fills against the *wire* name, not the declared one.
    assert_equal(from_json[Renamed]('{"a":1}').b, 7)
    assert_equal(to_json(Renamed(1, 2)), '{"a":1,"bee":2}')

    # A skipped field never appears on the wire in either direction.
    var skipped = from_json[Skipped]('{"a":1}')
    assert_equal(skipped.b, 3)
    assert_equal(to_json(Skipped(1, 3)), '{"a":1}')

    # An alias binds the same field under a second accepted name.
    assert_equal(from_json[Aliased]('{"a":5}').a, 5)
    assert_equal(from_json[Aliased]('{"a_alt":5}').a, 5)


@fieldwise_init
struct RenamedBounded(Movable):
    @__annotation(Rename("num"), Range(0, 10))
    var n: Int


def test_rename_composes_with_a_check() raises:
    var ok = from_json[RenamedBounded]('{"num":5}')
    assert_equal(ok.n, 5)
    assert_equal(to_json(ok), '{"num":5}')

    with assert_raises(contains="Value out of range"):
        _ = from_json[RenamedBounded]('{"num":11}')

    # The rename is still in force on the failing path: the old key is
    # simply an unknown field, so the required one reads as missing.
    assert_equal(_failure_of[RenamedBounded]('{"n":5}').kind, "MissingField")


@__annotation(
    Validate(
        lambda (c: Cfg) -> Bool: c.env != "prod" or c.level != 0,
        "prod needs a level",
    )
)
@fieldwise_init
struct Cfg(Defaultable, Movable):
    @__annotation(Range(1, 65535, msg="bad port"))
    var port: Int

    @__annotation(NonEmpty(), Size(1, 64))
    var host: String

    @__annotation(Enum["dev", "prod"]())
    var env: String

    @__annotation(AnyOf(Eq(0), Range(10, 20)))
    var level: Int

    def __init__(out self):
        self.port = 0
        self.host = String()
        self.env = String()
        self.level = 0


def _cfg(port: String, host: String, env: String, level: String) -> String:
    return (
        '{"port":'
        + port
        + ',"host":'
        + host
        + ',"env":'
        + env
        + ',"level":'
        + level
        + "}"
    )


def _assert_cfg_fails(s: String, message: String, path: String) raises:
    var f = _failure_of[Cfg](s)
    assert_equal(f.kind, "InvalidValue")
    assert_equal(f.message, message)
    assert_equal(f.path, path)


def test_annotations_through_from_json() raises:
    var c = from_json[Cfg](_cfg("8080", '"h"', '"prod"', "15"))
    assert_equal(c.port, 8080)
    assert_equal(c.level, 15)
    assert_equal(to_json(c), '{"port":8080,"host":"h","env":"prod","level":15}')

    _assert_cfg_fails(_cfg("0", '"h"', '"dev"', "0"), "bad port", ".port")
    _assert_cfg_fails(
        _cfg("80", '""', '"dev"', "0"), "Value must not be empty", ".host"
    )
    _assert_cfg_fails(
        _cfg("80", '"h"', '"qa"', "0"), "Value not in options", ".env"
    )
    _assert_cfg_fails(
        _cfg("80", '"h"', '"dev"', "5"), "Value not in options", ".level"
    )
    _assert_cfg_fails(
        _cfg("80", '"h"', '"prod"', "0"), "prod needs a level", ""
    )


def redact(s: String) -> String:
    return "********"


def redact_int(n: Int) -> String:
    return "********"


@fieldwise_init
struct Creds(Defaultable, Movable):
    var user: String

    @__annotation(SerializeWith(redact))
    var password: String

    @__annotation(SerializeWith(redact_int))
    var pin: Int

    def __init__(out self):
        self.user = String()
        self.password = String()
        self.pin = 0


def test_redaction() raises:
    # Read as sent, written through the redacting function.
    var c = from_json[Creds]('{"user":"bg","password":"hunter2","pin":1234}')
    assert_equal(c.password, "hunter2")
    assert_equal(c.pin, 1234)
    assert_equal(
        to_json(c), '{"user":"bg","password":"********","pin":"********"}'
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
