from emberjson.schema import (
    Range,
    ExclusiveRange,
    Size,
    NonEmpty,
    StartsWith,
    EndsWith,
    OneOf,
    AnyOf,
    NoneOf,
    Enum,
    AllOf,
    Eq,
    Ne,
    Not,
    Unique,
    Secret,
    Clamp,
    Coerce,
    CoerceInt,
    CoerceUInt,
    CoerceFloat,
    CoerceString,
    Default,
    Transform,
    MultipleOf,
    CrossFieldValidator,
)
from emberjson import from_json, to_json, Defaulted, Field, Value
from emberserde.error import DerErrorKind
from std.collections import Set, Array
from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)


def test_range_int() raises:
    # Valid value
    var r1 = from_json[Range[Int, 0, 10]]("5")
    assert_equal(r1[], 5)

    # Boundary values
    var r2 = from_json[Range[Int, 0, 10]]("0")
    assert_equal(r2[], 0)

    var r3 = from_json[Range[Int, 0, 10]]("10")
    assert_equal(r3[], 10)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = from_json[Range[Int, 0, 10]]("-1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = from_json[Range[Int, 0, 10]]("11")


def test_range_float() raises:
    # Valid value
    var r1 = from_json[Range[Float64, 0.0, 1.0]]("0.5")
    assert_equal(r1[], 0.5)

    # Boundary values
    var r2 = from_json[Range[Float64, 0.0, 1.0]]("0.0")
    assert_equal(r2[], 0.0)

    var r3 = from_json[Range[Float64, 0.0, 1.0]]("1.0")
    assert_equal(r3[], 1.0)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = from_json[Range[Float64, 0.0, 1.0]]("-0.1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = from_json[Range[Float64, 0.0, 1.0]]("1.1")


def test_range_serialization() raises:
    var r = Range[Int, 0, 10](5)
    assert_equal(to_json(r), "5")

    var rf = Range[Float64, 0.0, 1.0](0.75)
    assert_equal(to_json(rf), "0.75")


def test_size_string() raises:
    # Valid size
    var s1 = from_json[Size[String, 3, 5]]('"abc"')
    assert_equal(s1[], "abc")

    var s2 = from_json[Size[String, 3, 5]]('"abcde"')
    assert_equal(s2[], "abcde")

    # Too short
    with assert_raises(contains="Value out of size range"):
        _ = from_json[Size[String, 3, 5]]('"ab"')

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = from_json[Size[String, 3, 5]]('"abcdef"')


def test_size_list() raises:
    # Valid size
    var l1 = from_json[Size[List[Int], 1, 3]]("[1, 2]")
    assert_equal(len(l1[]), 2)
    assert_equal(l1[][0], 1)

    # Empty (too short)
    with assert_raises(contains="Value out of size range"):
        _ = from_json[Size[List[Int], 1, 3]]("[]")

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = from_json[Size[List[Int], 1, 3]]("[1, 2, 3, 4]")


def test_one_of() raises:
    # String options
    var o1 = from_json[OneOf[String, Eq["red"], Eq["green"], Eq["blue"]]](
        '"red"'
    )
    assert_equal(o1[], "red")

    with assert_raises(contains="Value didn't match any validators"):
        _ = from_json[OneOf[String, Eq["red"], Eq["green"], Eq["blue"]]](
            '"yellow"'
        )

    assert_equal(to_json(o1), '"red"')

    # Int options
    var o2 = from_json[OneOf[Int, Eq[1], Eq[2], Eq[3]]]("2")
    assert_equal(o2[], 2)

    with assert_raises(contains="Value didn't match any validators"):
        _ = from_json[OneOf[Int, Eq[1], Eq[2], Eq[3]]]("4")

    with assert_raises(contains="Multiple validators matched"):
        _ = from_json[
            OneOf[Int64, Eq[Int64(1)], Eq[Int64(4)], MultipleOf[Int64(2)]]
        ]("4")


def test_secret() raises:
    # Deserialize normally
    var s1 = from_json[Secret[String]]('"my_super_secret_password"')
    assert_equal(s1[], "my_super_secret_password")

    # Serialize as masked
    assert_equal(to_json(s1), '"********"')

    var s2 = from_json[Secret[Int]]("12345")
    assert_equal(s2[], 12345)
    assert_equal(to_json(s2), '"********"')


def test_clamp() raises:
    # Valid value
    var c1 = from_json[Clamp[Int, 0, 10]]("5")
    assert_equal(c1[], 5)

    # Too low is clamped to min
    var c2 = from_json[Clamp[Int, 0, 10]]("-5")
    assert_equal(c2[], 0)

    # Too high is clamped to max
    var c3 = from_json[Clamp[Int, 0, 10]]("15")
    assert_equal(c3[], 10)


def coerce_int(v: Value) raises -> Int:
    if v.is_int():
        return Int(v.int())
    elif v.is_string():
        return Int(v.string())
    elif v.is_float():
        return Int(v.float())
    elif v.is_bool():
        return Int(v.bool())
    raise Error("Invalid value")


def test_coerce() raises:
    var c1 = from_json[Coerce[Int, coerce_int]]('"123"')
    assert_equal(c1[], 123)

    var c2 = from_json[Coerce[Int, coerce_int]]("123.45")
    assert_equal(c2[], 123)

    var c3 = from_json[Coerce[Int, coerce_int]]("true")
    assert_equal(c3[], 1)


def test_coerce_int() raises:
    var c1 = from_json[CoerceInt]('"123"')
    assert_equal(c1[], 123)

    var c2 = from_json[CoerceInt]("123.45")
    assert_equal(c2[], 123)

    var c3 = from_json[CoerceInt]("123")
    assert_equal(c3[], 123)

    var c4 = from_json[CoerceInt]("0")
    assert_equal(c4[], 0)

    with assert_raises(contains="Value cannot be converted to an integer"):
        _ = from_json[CoerceInt]("null")


def test_coerce_uint() raises:
    var c1 = from_json[CoerceUInt]('"123"')
    assert_equal(c1[], 123)

    var c2 = from_json[CoerceUInt]("123.45")
    assert_equal(c2[], 123)

    var c3 = from_json[CoerceUInt]("123")
    assert_equal(c3[], 123)

    with assert_raises(
        contains="Value cannot be converted to an unsigned integer"
    ):
        _ = from_json[CoerceUInt]("null")


def test_coerce_float() raises:
    var c1 = from_json[CoerceFloat]('"123.45"')
    assert_equal(c1[], 123.45)

    var c2 = from_json[CoerceFloat]("123")
    assert_equal(c2[], 123.0)

    var c3 = from_json[CoerceFloat]("123.45")
    assert_equal(c3[], 123.45)

    with assert_raises(contains="Value cannot be converted to a float"):
        _ = from_json[CoerceFloat]("null")


def test_coerce_string() raises:
    var c1 = from_json[CoerceString]('"123"')
    assert_equal(c1[], "123")

    var c2 = from_json[CoerceString]("123.45")
    assert_equal(c2[], "123.45")

    var c3 = from_json[CoerceString]("123")
    assert_equal(c3[], "123")

    var c4 = from_json[CoerceString]("0")
    assert_equal(c4[], "0")

    var c5 = from_json[CoerceString]("null")
    assert_equal(c5[], "null")


struct TestDefault(Movable):
    var a: Int
    var b: Default[Int, 42]


struct TestOptDefault(Movable):
    var a: Int
    var b: Defaulted[Optional[Int], Optional[Int](42)]


def test_default() raises:
    var d1 = from_json[Default[Int, 42]]("10")
    assert_equal(d1[], 10)

    # DELIBERATE BEHAVIOUR CHANGE (emberserde port): `Default[T, d]` is now
    # a spelling of emberserde's `Field[T, default=d]`, whose default fills
    # a *missing key* only. An explicit `null` is a present value on the
    # wire and is parsed as `T`, so this raises where it previously
    # produced 42.
    with assert_raises():
        _ = from_json[Default[Int, 42]]("null")

    # The escape hatch for the old null-tolerance: make the payload itself
    # `Optional`, so `null` binds `None` instead of raising while a missing
    # key still takes the default.
    var d2 = from_json[Defaulted[Optional[Int], Optional[Int](42)]]("null")
    assert_false(d2[])

    # ...and the other half of that escape hatch: an absent key on an
    # `Optional` payload still takes the default rather than binding None.
    var d2b = from_json[TestOptDefault]('{"a": 10}')
    assert_true(d2b.b[])
    assert_equal(d2b.b[].value(), 42)

    var d2c = from_json[TestOptDefault]('{"a": 10, "b": null}')
    assert_false(d2c.b[])

    var d3 = from_json[TestDefault]('{"a": 10}')
    assert_equal(d3.a, 10)
    assert_equal(d3.b[], 42)

    # A present key still wins over the default.
    var d4 = from_json[TestDefault]('{"a": 10, "b": 7}')
    assert_equal(d4.b[], 7)

    # `Default` is a foreign type (emberserde's `Field`) whose
    # `Serializable`/`Deserializable` conformances live upstream. If those
    # ever go unseen the framework's `conforms_to` gate silently falls back
    # to walking `Field` as a plain struct and emits `{"value":42}` instead
    # of the payload, so pin the payload spelling in both directions.
    assert_equal(to_json(d1), "10")
    assert_equal(to_json(d3), '{"a":10,"b":42}')
    assert_equal(to_json(Default[Int, 42]()), "42")


def test_bare_field_round_trips_through_the_facade() raises:
    # An *unconfigured* `Field` -- which is what `Default` is -- read and
    # written through the public facade. The configured spellings
    # (`rename`/`extra_names`/`skip`) are covered in
    # `test/emberjson/serde/test_schema_fields.mojo`; before Task 8 they
    # were a hard compile error on this path, because the reflection walker
    # behind `deserialize`/`serialize` matched declared field names only.
    var f = from_json[Field[Int]]("5")
    assert_equal(f[], 5)
    assert_equal(f.value, 5)
    assert_equal(to_json(f), "5")

    var s = from_json[Field[String]]('"hi"')
    assert_equal(s[], "hi")
    assert_equal(to_json(s), '"hi"')


def date_to_int(s: String) -> Int:
    if s == "2024-01-01":
        return 1
    return 0


def test_transform() raises:
    var t1 = from_json[Transform[String, Int, date_to_int]]('"2024-01-01"')
    assert_equal(t1[], 1)


def test_multiple_of() raises:
    # Valid Multiple
    var m1 = from_json[MultipleOf[Int64(10)]]("50")
    assert_equal(m1[], 50)

    # Valid Float Multiple
    var m2 = from_json[MultipleOf[Float64(0.5)]]("2.5")
    assert_equal(m2[], 2.5)

    var m3 = from_json[MultipleOf[SIMD[DType.int64, 4](2, 3, 2, 3)]](
        "[4, 6, 8, 9]"
    )
    assert_equal(m3[], SIMD[DType.int64, 4](4, 6, 8, 9))

    # Invalid Multiple
    with assert_raises(contains="Value is not a multiple of"):
        _ = from_json[MultipleOf[Int64(10)]]("55")

    with assert_raises(contains="Value is not a multiple of"):
        _ = from_json[MultipleOf[SIMD[DType.int64, 4](2, 3, 2, 3)]](
            "[4, 6, 15, 9]"
        )

    # Serialize Matches
    assert_equal(to_json(m1), "50")
    assert_equal(to_json(m2), "2.5")
    assert_equal(to_json(m3), "[4,6,8,9]")


def test_all_of() raises:
    var s = '"astring"'
    var v = from_json[
        AllOf[
            String,
            Size[String, 3, 7],
            OneOf[String, Eq["astring"], Eq["bstring"]],
        ]
    ](s)
    assert_equal(v[], "astring")

    s = '"a"'
    with assert_raises(contains="Value out of size range"):
        _ = from_json[AllOf[String, Size[String, 3, 5]]](s)

    with assert_raises():
        _ = from_json[
            AllOf[
                String,
                Size[String, 0, 10],
                OneOf[String, Eq["astring"], Eq["bstring"]],
            ]
        ](s)

    comptime VSet = AllOf[
        Int64,
        Range[Int64, 1, 30],
        MultipleOf[Int64(4)],
        MultipleOf[Int64(2)],
    ]
    var setv = from_json[VSet]("8")
    assert_equal(setv[], 8)

    with assert_raises():
        _ = from_json[VSet]("10")

    comptime VSet2 = AllOf[
        Int64,
        Range[Int64, 1, 30],
        MultipleOf[Int64(4)],
        MultipleOf[Int64(2)],
        MultipleOf[Int64(3)],
    ]

    with assert_raises():
        _ = from_json[VSet2]("8")

    var setv2 = from_json[VSet2]("12")
    assert_equal(setv2[], 12)


def test_compound_type() raises:
    var s = "123"
    comptime SecretCoercedString = Secret[CoerceString]
    var v = from_json[SecretCoercedString](s)
    assert_equal(v[][], "123")
    assert_equal(to_json(v), '"********"')


def test_unique() raises:
    # Valid unique list
    var u1 = from_json[Unique[List[Int]]]("[1, 2, 3]")
    assert_equal(len(u1[]), 3)
    assert_equal(u1[][0], 1)
    assert_equal(u1[][1], 2)
    assert_equal(u1[][2], 3)

    # Duplicate elements
    with assert_raises(contains="Values are not unique"):
        _ = from_json[Unique[List[Int]]]("[1, 2, 1]")

    # Unique strings
    var u2 = from_json[Unique[List[String]]]('["a", "b", "c"]')
    assert_equal(len(u2[]), 3)

    with assert_raises(contains="Values are not unique"):
        _ = from_json[Unique[List[String]]]('["a", "b", "a"]')

    # Empty list is unique
    var u3 = from_json[Unique[List[Int]]]("[]")
    assert_equal(len(u3[]), 0)

    # Serialization
    var l = List[Int]()
    l.append(1)
    l.append(2)
    l.append(3)
    var u4 = Unique[List[Int]](l^)
    assert_equal(to_json(u4), "[1,2,3]")

    # Set (should always be unique, even if JSON has duplicates)
    var u5 = from_json[Unique[Set[Int]]]("[1, 2, 1, 2, 3]")
    assert_equal(len(u5[]), 3)

    # Array
    var u6 = from_json[Unique[Array[Int, 3]]]("[1, 2, 3]")
    assert_equal(len(u6[]), 3)

    with assert_raises(contains="Values are not unique"):
        _ = from_json[Unique[Array[Int, 3]]]("[1, 2, 1]")


def test_not_ne() raises:
    # Not
    var n1 = from_json[Not[Int, Range[Int, 0, 10]]]("15")
    assert_equal(n1[], 15)

    with assert_raises(contains="Expected validator to fail"):
        _ = from_json[Not[Int, Range[Int, 0, 10]]]("5")

    # Ne
    var n2 = from_json[Ne[10]]("5")
    assert_equal(n2[], 5)

    with assert_raises(contains="Expected validator to fail"):
        _ = from_json[Ne[10]]("10")

    # Ne string
    var n3 = from_json[Ne["forbidden"]]('"allowed"')
    assert_equal(n3[], "allowed")

    with assert_raises(contains="Expected validator to fail"):
        _ = from_json[Ne["forbidden"]]('"forbidden"')


def test_any_of() raises:
    # Multiple matches - AnyOf should pass (unlike OneOf)
    var a1 = from_json[
        AnyOf[Int64, Eq[Int64(1)], Eq[Int64(4)], MultipleOf[Int64(2)]]
    ]("4")
    assert_equal(a1[], 4)

    # Single match
    var a2 = from_json[AnyOf[Int, Eq[1], Eq[2], Eq[3]]]("2")
    assert_equal(a2[], 2)

    # No matches
    with assert_raises(contains="Value not in options"):
        _ = from_json[AnyOf[Int, Eq[1], Eq[2], Eq[3]]]("5")

    assert_equal(to_json(a1), "4")
    assert_equal(to_json(a2), "2")


def test_none_of() raises:
    # Value doesn't match any rejected
    var n1 = from_json[NoneOf[Int, Eq[1], Eq[2], Range[Int, 10, 20]]]("5")
    assert_equal(n1[], 5)

    # Value matches one of rejected
    with assert_raises():
        _ = from_json[NoneOf[Int, Eq[1], Eq[2], Range[Int, 0, 10]]]("5")

    assert_equal(to_json(n1), "5")


def test_exclusive_range() raises:
    var r1 = from_json[ExclusiveRange[Int, 0, 10]]("5")
    assert_equal(r1[], 5)

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json[ExclusiveRange[Int, 0, 10]]("0")

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json[ExclusiveRange[Int, 0, 10]]("10")

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json[ExclusiveRange[Int, 0, 10]]("11")

    var r2 = from_json[ExclusiveRange[Float64, 0.0, 1.0]]("0.5")
    assert_equal(r2[], 0.5)

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json[ExclusiveRange[Float64, 0.0, 1.0]]("0.0")

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = from_json[ExclusiveRange[Float64, 0.0, 1.0]]("1.0")


def test_non_empty() raises:
    var s1 = from_json[NonEmpty[String]]('"hello"')
    assert_equal(s1[], "hello")

    var l1 = from_json[NonEmpty[List[Int]]]("[1]")
    assert_equal(len(l1[]), 1)

    with assert_raises(contains="Value must not be empty"):
        _ = from_json[NonEmpty[String]]('""')

    with assert_raises(contains="Value must not be empty"):
        _ = from_json[NonEmpty[List[Int]]]("[]")

    assert_equal(to_json(s1), '"hello"')


def test_starts_ends_with() raises:
    var s1 = from_json[StartsWith["hello"]]('"hello world"')
    assert_equal(s1[], "hello world")

    with assert_raises(contains="Value does not start with expected prefix"):
        _ = from_json[StartsWith["hello"]]('"world"')

    var s2 = from_json[EndsWith[".json"]]('"config.json"')
    assert_equal(s2[], "config.json")

    with assert_raises(contains="Value does not end with expected suffix"):
        _ = from_json[EndsWith[".json"]]('"config.toml"')

    assert_equal(to_json(s1), '"hello world"')
    assert_equal(to_json(s2), '"config.json"')


def test_enum() raises:
    comptime Color = Enum["red", "green", "blue"]

    var c1 = from_json[Color]('"red"')
    assert_equal(c1[], "red")

    var c2 = from_json[Color]('"blue"')
    assert_equal(c2[], "blue")

    with assert_raises():
        _ = from_json[Color]('"yellow"')

    assert_equal(to_json(c1), '"red"')

    comptime Priority = Enum[1, 2, 3]

    var p1 = from_json[Priority]("2")
    assert_equal(p1[], 2)

    with assert_raises():
        _ = from_json[Priority]("5")


@fieldwise_init
struct TestStruct(Movable):
    var a: Int
    var b: Int


def test_cross_field_validator() raises:
    def validate_greater(a: Int, b: Int) raises:
        if a <= b:
            raise Error("a must be greater than b")

    var s1 = from_json[
        CrossFieldValidator[TestStruct, "a", "b", validate_greater]
    ]('{"a": 5, "b": 3}')
    assert_equal(s1[].a, 5)
    assert_equal(s1[].b, 3)

    with assert_raises(contains="a must be greater than b"):
        _ = from_json[
            CrossFieldValidator[TestStruct, "a", "b", validate_greater]
        ]('{"a": 2, "b": 3}')


def test_direct_construction_validates() raises:
    # Validated (via Range) — out-of-range value raises
    with assert_raises(contains="Value out of range"):
        _ = Range[Int, 0, 10](15)

    # Validated (via Size) — too-short value raises
    with assert_raises(contains="Value out of size range"):
        _ = Size[String, 3, 5](String("ab"))

    # Validated (via NonEmpty) — empty value raises
    with assert_raises(contains="Value must not be empty"):
        _ = NonEmpty[String](String(""))

    # Validated (via StartsWith) — wrong prefix raises
    with assert_raises(contains="Value does not start with expected prefix"):
        _ = StartsWith["hello"](String("world"))

    # Validated (via EndsWith) — wrong suffix raises
    with assert_raises(contains="Value does not end with expected suffix"):
        _ = EndsWith[".json"](String("config.toml"))

    # AllOf — value failing a validator raises
    with assert_raises(contains="Value out of size range"):
        _ = AllOf[String, Size[String, 3, 5]](String("ab"))

    # OneOf — value matching no validators raises
    with assert_raises(contains="Value didn't match any validators"):
        _ = OneOf[String, Eq["red"], Eq["green"]](String("yellow"))

    # AnyOf — value matching no validators raises
    with assert_raises(contains="Value not in options"):
        _ = AnyOf[Int, Eq[1], Eq[2]](5)

    # NoneOf — value matching a rejected validator raises
    with assert_raises(contains="Value matched a rejected validator"):
        _ = NoneOf[Int, Range[Int, 0, 10]](5)

    # Enum — value not in accepted set raises
    comptime Color = Enum["red", "green", "blue"]
    with assert_raises(contains="Value not in options"):
        _ = Color(String("yellow"))

    # CrossFieldValidator — failing cross-field check raises
    def validate_greater(a: Int, b: Int) raises:
        if a <= b:
            raise Error("a must be greater than b")

    with assert_raises(contains="a must be greater than b"):
        _ = CrossFieldValidator[TestStruct, "a", "b", validate_greater](
            TestStruct(2, 3)
        )


# ===========================================================================
# `Field`'s wire-metadata knobs (rename / skip / aliases) and how they compose
# with the value-semantics wrappers above. `Default` rides emberserde's
# `Field`, so these knobs came with it -- none has an equivalent among the
# older EmberJson schema types, which is why they are pinned here rather than
# folded into `test_default`.
# ===========================================================================


@fieldwise_init
struct Renamed(Movable):
    var a: Int
    var b: Field[Int, rename=String("bee"), default=7]


@fieldwise_init
struct Skipped(Movable):
    var a: Int
    var b: Field[Int, skip=True, default=3]


@fieldwise_init
struct Aliased(Movable):
    var a: Field[Int, extra_names=List[String]([String("a_alt")])]


# `Field` carries wire metadata, the validators carry value semantics, so
# they compose by nesting rather than competing for the same slot.
@fieldwise_init
struct RenamedBounded(Movable):
    var n: Field[Range[Int, 0, 10], rename=String("num")]


@fieldwise_init
struct Bounded(Movable):
    var n: Range[Int, 0, 10]


# `Defaultable` because the payload has a non-trivial destructor: the
# framework only claims an unwritten struct in place when every field is
# trivially destructible, otherwise it wants a real default to fill in.
@fieldwise_init
struct Creds(Defaultable, Movable):
    var user: String
    var password: Secret[String]

    def __init__(out self):
        self.user = String()
        self.password = Secret[String](String())


# A wrapper's failure has to surface as a typed `DeserializationError` (not
# the untyped `Error` the `Validator` implementations raise) so the
# framework's `kind`/`path` machinery still works. The sentinel idiom is
# emberserde's: `assert_true(False)` inside the `try` will not compile,
# because one `try` block cannot mix the typed and untyped raise flavours.
def _kind_of[T: Movable & Deinitable](s: String) raises -> String:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[T](s)
    except e:
        kind = e.kind
    return String(kind)


def _path_of[T: Movable & Deinitable](s: String) raises -> String:
    var path = String("<did not raise>")
    try:
        _ = from_json[T](s)
    except e:
        path = e.path
    return path^


def test_field_rename_skip_and_aliases() raises:
    var renamed = from_json[Renamed]('{"a":1,"bee":2}')
    assert_equal(renamed.b[], 2)
    # The default fills against the *wire* name, not the declared one.
    assert_equal(from_json[Renamed]('{"a":1}').b[], 7)
    assert_equal(to_json(Renamed(1, 2)), '{"a":1,"bee":2}')

    # A skipped field never appears on the wire in either direction.
    var skipped = from_json[Skipped]('{"a":1}')
    assert_equal(skipped.b[], 3)
    assert_equal(to_json(Skipped(1, 3)), '{"a":1}')

    # An alias binds the same field under a second accepted name.
    assert_equal(from_json[Aliased]('{"a":5}').a[], 5)
    assert_equal(from_json[Aliased]('{"a_alt":5}').a[], 5)


def test_field_composes_with_a_validator() raises:
    # Two different axes, so they stack: the rename decides which key the
    # value is read from, the `Range` decides whether the value is
    # acceptable once read.
    var ok = from_json[RenamedBounded]('{"num":5}')
    assert_equal(ok.n[][], 5)
    assert_equal(to_json(ok), '{"num":5}')

    with assert_raises(contains="Value out of range"):
        _ = from_json[RenamedBounded]('{"num":11}')

    # The rename is still in force on the failing path: the old key is
    # simply an unknown field, so the required one reads as missing.
    assert_equal(_kind_of[RenamedBounded]('{"n":5}'), String("MissingField"))


def test_validation_failure_reports_kind_and_path() raises:
    # A validator rejection is a bad *value*, not a bad shape.
    assert_equal(_kind_of[Range[Int, 0, 10]]("11"), String("InvalidValue"))
    # ...and it still rides the framework's error-path tracking when the
    # wrapper sits inside a struct field.
    assert_equal(_path_of[Bounded]('{"n":11}'), String(".n"))


def test_coerce_failure_reports_kind() raises:
    assert_equal(_kind_of[CoerceInt]("null"), String("InvalidValue"))


def test_secret_redaction_survives_nesting() raises:
    # The mask has to come from `Secret.serialize`, not from the field
    # walker, so it must survive being one field of a struct.
    var c = from_json[Creds]('{"user":"bg","password":"hunter2"}')
    assert_equal(c.password[], "hunter2")
    assert_equal(to_json(c), '{"user":"bg","password":"********"}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
