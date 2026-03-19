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
    MergeAllOf,
    MergeAnyOf,
    MergeOneOf,
    MergeNoneOf,
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
from emberjson import deserialize, serialize, Value
from std.collections import Set, InlineArray
from std.testing import assert_equal, assert_raises, TestSuite


def test_range_int() raises:
    # Valid value
    var r1 = deserialize[Range[Int, 0, 10]]("5")
    assert_equal(r1[], 5)

    # Boundary values
    var r2 = deserialize[Range[Int, 0, 10]]("0")
    assert_equal(r2[], 0)

    var r3 = deserialize[Range[Int, 0, 10]]("10")
    assert_equal(r3[], 10)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Int, 0, 10]]("-1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Int, 0, 10]]("11")


def test_range_float() raises:
    # Valid value
    var r1 = deserialize[Range[Float64, 0.0, 1.0]]("0.5")
    assert_equal(r1[], 0.5)

    # Boundary values
    var r2 = deserialize[Range[Float64, 0.0, 1.0]]("0.0")
    assert_equal(r2[], 0.0)

    var r3 = deserialize[Range[Float64, 0.0, 1.0]]("1.0")
    assert_equal(r3[], 1.0)

    # Out of range (too low)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Float64, 0.0, 1.0]]("-0.1")

    # Out of range (too high)
    with assert_raises(contains="Value out of range"):
        _ = deserialize[Range[Float64, 0.0, 1.0]]("1.1")


def test_range_serialization() raises:
    var r = Range[Int, 0, 10](5)
    assert_equal(serialize(r), "5")

    var rf = Range[Float64, 0.0, 1.0](0.75)
    assert_equal(serialize(rf), "0.75")


def test_size_string() raises:
    # Valid size
    var s1 = deserialize[Size[String, 3, 5]]('"abc"')
    assert_equal(s1[], "abc")

    var s2 = deserialize[Size[String, 3, 5]]('"abcde"')
    assert_equal(s2[], "abcde")

    # Too short
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[String, 3, 5]]('"ab"')

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[String, 3, 5]]('"abcdef"')


def test_size_list() raises:
    # Valid size
    var l1 = deserialize[Size[List[Int], 1, 3]]("[1, 2]")
    assert_equal(len(l1[]), 2)
    assert_equal(l1[][0], 1)

    # Empty (too short)
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[List[Int], 1, 3]]("[]")

    # Too long
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[Size[List[Int], 1, 3]]("[1, 2, 3, 4]")


def test_one_of() raises:
    # String options
    var o1 = deserialize[OneOf[String, Eq["red"], Eq["green"], Eq["blue"]]](
        '"red"'
    )
    assert_equal(o1[], "red")

    with assert_raises(contains="Value didn't match any validators"):
        _ = deserialize[OneOf[String, Eq["red"], Eq["green"], Eq["blue"]]](
            '"yellow"'
        )

    # Int options
    var o2 = deserialize[OneOf[Int, Eq[1], Eq[2], Eq[3]]]("2")
    assert_equal(o2[], 2)

    with assert_raises(contains="Value didn't match any validators"):
        _ = deserialize[OneOf[Int, Eq[1], Eq[2], Eq[3]]]("4")

    with assert_raises(contains="Multiple validators matched"):
        _ = deserialize[
            OneOf[Int64, Eq[Int64(1)], Eq[Int64(4)], MultipleOf[Int64(2)]]
        ]("4")


def test_secret() raises:
    # Deserialize normally
    var s1 = deserialize[Secret[String]]('"my_super_secret_password"')
    assert_equal(s1[], "my_super_secret_password")

    # Serialize as masked
    assert_equal(serialize(s1), '"********"')

    var s2 = deserialize[Secret[Int]]("12345")
    assert_equal(s2[], 12345)
    assert_equal(serialize(s2), '"********"')


def test_clamp() raises:
    # Valid value
    var c1 = deserialize[Clamp[Int, 0, 10]]("5")
    assert_equal(c1[], 5)

    # Too low is clamped to min
    var c2 = deserialize[Clamp[Int, 0, 10]]("-5")
    assert_equal(c2[], 0)

    # Too high is clamped to max
    var c3 = deserialize[Clamp[Int, 0, 10]]("15")
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
    var c1 = deserialize[Coerce[Int, coerce_int]]('"123"')
    assert_equal(c1[], 123)

    var c2 = deserialize[Coerce[Int, coerce_int]]("123.45")
    assert_equal(c2[], 123)

    var c3 = deserialize[Coerce[Int, coerce_int]]("true")
    assert_equal(c3[], 1)


def test_coerce_int() raises:
    var c1 = deserialize[CoerceInt]('"123"')
    assert_equal(c1[], 123)

    var c2 = deserialize[CoerceInt]("123.45")
    assert_equal(c2[], 123)

    var c3 = deserialize[CoerceInt]("123")
    assert_equal(c3[], 123)

    var c4 = deserialize[CoerceInt]("0")
    assert_equal(c4[], 0)

    with assert_raises(contains="Value cannot be converted to an integer"):
        _ = deserialize[CoerceInt]("null")


def test_coerce_uint() raises:
    var c1 = deserialize[CoerceUInt]('"123"')
    assert_equal(c1[], 123)

    var c2 = deserialize[CoerceUInt]("123.45")
    assert_equal(c2[], 123)

    var c3 = deserialize[CoerceUInt]("123")
    assert_equal(c3[], 123)

    with assert_raises(
        contains="Value cannot be converted to an unsigned integer"
    ):
        _ = deserialize[CoerceUInt]("null")


def test_coerce_float() raises:
    var c1 = deserialize[CoerceFloat]('"123.45"')
    assert_equal(c1[], 123.45)

    var c2 = deserialize[CoerceFloat]("123")
    assert_equal(c2[], 123.0)

    var c3 = deserialize[CoerceFloat]("123.45")
    assert_equal(c3[], 123.45)

    with assert_raises(contains="Value cannot be converted to a float"):
        _ = deserialize[CoerceFloat]("null")


def test_coerce_string() raises:
    var c1 = deserialize[CoerceString]('"123"')
    assert_equal(c1[], "123")

    var c2 = deserialize[CoerceString]("123.45")
    assert_equal(c2[], "123.45")

    var c3 = deserialize[CoerceString]("123")
    assert_equal(c3[], "123")

    var c4 = deserialize[CoerceString]("0")
    assert_equal(c4[], "0")

    var c5 = deserialize[CoerceString]("null")
    assert_equal(c5[], "null")


struct TestDefault(Movable):
    var a: Int
    var b: Default[Int, 42]


def test_default() raises:
    var d1 = deserialize[Default[Int, 42]]("10")
    assert_equal(d1[], 10)

    var d2 = deserialize[Default[Int, 42]]("null")
    assert_equal(d2[], 42)

    var d3 = deserialize[TestDefault]('{"a": 10}')
    assert_equal(d3.a, 10)
    assert_equal(d3.b[], 42)


def date_to_int(s: String) -> Int:
    if s == "2024-01-01":
        return 1
    return 0


def test_transform() raises:
    var t1 = deserialize[Transform[String, Int, date_to_int]]('"2024-01-01"')
    assert_equal(t1[], 1)


def test_multiple_of() raises:
    # Valid Multiple
    var m1 = deserialize[MultipleOf[Int64(10)]]("50")
    assert_equal(m1[], 50)

    # Valid Float Multiple
    var m2 = deserialize[MultipleOf[Float64(0.5)]]("2.5")
    assert_equal(m2[], 2.5)

    var m3 = deserialize[MultipleOf[SIMD[DType.int64, 4](2, 3, 2, 3)]](
        "[4, 6, 8, 9]"
    )
    assert_equal(m3[], SIMD[DType.int64, 4](4, 6, 8, 9))

    # Invalid Multiple
    with assert_raises(contains="Value is not a multiple of"):
        _ = deserialize[MultipleOf[Int64(10)]]("55")

    with assert_raises(contains="Value is not a multiple of"):
        _ = deserialize[MultipleOf[SIMD[DType.int64, 4](2, 3, 2, 3)]](
            "[4, 6, 15, 9]"
        )

    # Serialize Matches
    assert_equal(serialize(m1), "50")
    assert_equal(serialize(m2), "2.5")
    assert_equal(serialize(m3), "[4,6,8,9]")


def test_all_of() raises:
    var s = '"astring"'
    var v = deserialize[
        AllOf[
            String,
            Size[String, 3, 7],
            OneOf[String, Eq["astring"], Eq["bstring"]],
        ]
    ](s)
    assert_equal(v[], "astring")

    s = '"a"'
    with assert_raises(contains="Value out of size range"):
        _ = deserialize[AllOf[String, Size[String, 3, 5]]](s)

    with assert_raises():
        _ = deserialize[
            AllOf[
                String,
                Size[String, 0, 10],
                OneOf[String, Eq["astring"], Eq["bstring"]],
            ]
        ](s)

    comptime S1 = AllOf[
        Int64, Range[Int64, 1, 30], MultipleOf[Int64(4)]
    ].validators
    comptime S2 = AllOf[Int64, MultipleOf[Int64(2)]].validators
    comptime VSet = MergeAllOf[Int64, S1, S2]
    var setv = deserialize[VSet]("8")
    assert_equal(setv[], 8)

    with assert_raises():
        _ = deserialize[VSet]("10")

    comptime VSet2 = MergeAllOf[
        Int64, VSet.validators, Variadic.types[MultipleOf[Int64(3)]]
    ]

    with assert_raises():
        _ = deserialize[VSet2]("8")

    var setv2 = deserialize[VSet2]("12")
    assert_equal(setv2[], 12)


def test_compound_type() raises:
    var s = "123"
    comptime SecretCoercedString = Secret[CoerceString]
    var v = deserialize[SecretCoercedString](s)
    assert_equal(v[][], "123")
    assert_equal(serialize(v), '"********"')


def test_unique() raises:
    # Valid unique list
    var u1 = deserialize[Unique[List[Int]]]("[1, 2, 3]")
    assert_equal(len(u1[]), 3)
    assert_equal(u1[][0], 1)
    assert_equal(u1[][1], 2)
    assert_equal(u1[][2], 3)

    # Duplicate elements
    with assert_raises(contains="Values are not unique"):
        _ = deserialize[Unique[List[Int]]]("[1, 2, 1]")

    # Unique strings
    var u2 = deserialize[Unique[List[String]]]('["a", "b", "c"]')
    assert_equal(len(u2[]), 3)

    with assert_raises(contains="Values are not unique"):
        _ = deserialize[Unique[List[String]]]('["a", "b", "a"]')

    # Empty list is unique
    var u3 = deserialize[Unique[List[Int]]]("[]")
    assert_equal(len(u3[]), 0)

    # Serialization
    var l = List[Int]()
    l.append(1)
    l.append(2)
    l.append(3)
    var u4 = Unique[List[Int]](l^)
    assert_equal(serialize(u4), "[1,2,3]")

    # Set (should always be unique, even if JSON has duplicates)
    var u5 = deserialize[Unique[Set[Int]]]("[1, 2, 1, 2, 3]")
    assert_equal(len(u5[]), 3)

    # InlineArray
    var u6 = deserialize[Unique[InlineArray[Int, 3]]]("[1, 2, 3]")
    assert_equal(len(u6[]), 3)

    with assert_raises(contains="Values are not unique"):
        _ = deserialize[Unique[InlineArray[Int, 3]]]("[1, 2, 1]")


def test_not_ne() raises:
    # Not
    var n1 = deserialize[Not[Int, Range[Int, 0, 10]]]("15")
    assert_equal(n1[], 15)

    with assert_raises(contains="Expected validator to fail"):
        _ = deserialize[Not[Int, Range[Int, 0, 10]]]("5")

    # Ne
    var n2 = deserialize[Ne[10]]("5")
    assert_equal(n2[], 5)

    with assert_raises(contains="Expected validator to fail"):
        _ = deserialize[Ne[10]]("10")

    # Ne string
    var n3 = deserialize[Ne["forbidden"]]('"allowed"')
    assert_equal(n3[], "allowed")

    with assert_raises(contains="Expected validator to fail"):
        _ = deserialize[Ne["forbidden"]]('"forbidden"')


def test_any_of() raises:
    # Multiple matches - AnyOf should pass (unlike OneOf)
    var a1 = deserialize[
        AnyOf[Int64, Eq[Int64(1)], Eq[Int64(4)], MultipleOf[Int64(2)]]
    ]("4")
    assert_equal(a1[], 4)

    # Single match
    var a2 = deserialize[AnyOf[Int, Eq[1], Eq[2], Eq[3]]]("2")
    assert_equal(a2[], 2)

    # No matches
    with assert_raises(contains="Value not in options"):
        _ = deserialize[AnyOf[Int, Eq[1], Eq[2], Eq[3]]]("5")


def test_none_of() raises:
    # Value doesn't match any rejected
    var n1 = deserialize[NoneOf[Int, Eq[1], Eq[2], Range[Int, 10, 20]]]("5")
    assert_equal(n1[], 5)

    # Value matches one of rejected
    with assert_raises():
        _ = deserialize[NoneOf[Int, Eq[1], Eq[2], Range[Int, 0, 10]]]("5")


def test_merge_any_of() raises:
    comptime S1 = AnyOf[Int64, Range[Int64, 0, 10]].accepted
    comptime S2 = AnyOf[Int64, MultipleOf[Int64(2)]].accepted
    comptime VSet = MergeAnyOf[Int64, S1, S2]

    var v1 = deserialize[VSet]("4")  # matches both
    assert_equal(v1[], 4)

    var v2 = deserialize[VSet]("7")  # matches range only
    assert_equal(v2[], 7)

    var v3 = deserialize[VSet]("12")  # matches multiple of only
    assert_equal(v3[], 12)

    with assert_raises(contains="Value not in options"):
        _ = deserialize[VSet]("11")


def test_merge_one_of() raises:
    comptime S1 = OneOf[Int64, MultipleOf[Int64(2)]].accepted
    comptime S2 = OneOf[Int64, MultipleOf[Int64(3)]].accepted
    comptime VSet = MergeOneOf[Int64, S1, S2]

    var v1 = deserialize[VSet]("2")  # matches multiple of 2 only
    assert_equal(v1[], 2)

    var v2 = deserialize[VSet]("3")  # matches multiple of 3 only
    assert_equal(v2[], 3)

    with assert_raises(contains="Multiple validators matched"):
        _ = deserialize[VSet]("6")  # matches both

    with assert_raises(contains="Value didn't match any validators"):
        _ = deserialize[VSet]("5")  # matches neither


def test_merge_none_of() raises:
    comptime S1 = NoneOf[Int64, Range[Int64, 0, 5]].rejected
    comptime S2 = NoneOf[Int64, Range[Int64, 10, 15]].rejected
    comptime VSet = MergeNoneOf[Int64, S1, S2]

    var v1 = deserialize[VSet]("7")  # matches none
    assert_equal(v1[], 7)

    with assert_raises(contains="Value matched a rejected validator"):
        _ = deserialize[VSet]("3")  # matches first range

    with assert_raises(contains="Value matched a rejected validator"):
        _ = deserialize[VSet]("12")  # matches second range


def test_exclusive_range() raises:
    var r1 = deserialize[ExclusiveRange[Int, 0, 10]]("5")
    assert_equal(r1[], 5)

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = deserialize[ExclusiveRange[Int, 0, 10]]("0")

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = deserialize[ExclusiveRange[Int, 0, 10]]("10")

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = deserialize[ExclusiveRange[Int, 0, 10]]("11")

    var r2 = deserialize[ExclusiveRange[Float64, 0.0, 1.0]]("0.5")
    assert_equal(r2[], 0.5)

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = deserialize[ExclusiveRange[Float64, 0.0, 1.0]]("0.0")

    with assert_raises(contains="Value out of range (exclusive)"):
        _ = deserialize[ExclusiveRange[Float64, 0.0, 1.0]]("1.0")


def test_non_empty() raises:
    var s1 = deserialize[NonEmpty[String]]('"hello"')
    assert_equal(s1[], "hello")

    var l1 = deserialize[NonEmpty[List[Int]]]("[1]")
    assert_equal(len(l1[]), 1)

    with assert_raises(contains="Value must not be empty"):
        _ = deserialize[NonEmpty[String]]('""')

    with assert_raises(contains="Value must not be empty"):
        _ = deserialize[NonEmpty[List[Int]]]("[]")

    assert_equal(serialize(s1), '"hello"')


def test_starts_ends_with() raises:
    var s1 = deserialize[StartsWith["hello"]]('"hello world"')
    assert_equal(s1[], "hello world")

    with assert_raises(contains="Value does not start with expected prefix"):
        _ = deserialize[StartsWith["hello"]]('"world"')

    var s2 = deserialize[EndsWith[".json"]]('"config.json"')
    assert_equal(s2[], "config.json")

    with assert_raises(contains="Value does not end with expected suffix"):
        _ = deserialize[EndsWith[".json"]]('"config.toml"')

    assert_equal(serialize(s1), '"hello world"')
    assert_equal(serialize(s2), '"config.json"')


def test_enum() raises:
    comptime Color = Enum[String, "red", "green", "blue"]

    var c1 = deserialize[Color]('"red"')
    assert_equal(c1[], "red")

    var c2 = deserialize[Color]('"blue"')
    assert_equal(c2[], "blue")

    with assert_raises():
        _ = deserialize[Color]('"yellow"')

    assert_equal(serialize(c1), '"red"')

    comptime Priority = Enum[Int, 1, 2, 3]

    var p1 = deserialize[Priority]("2")
    assert_equal(p1[], 2)

    with assert_raises():
        _ = deserialize[Priority]("5")


struct TestStruct(Movable):
    var a: Int
    var b: Int

def test_cross_field_validator() raises:

    def validate_greater(a: Int, b: Int) raises:
        if a <= b:
            raise Error("a must be greater than b")

    var s1 = deserialize[
        CrossFieldValidator[TestStruct, "a", "b", validate_greater]
    ]('{"a": 5, "b": 3}')
    assert_equal(s1[].a, 5)
    assert_equal(s1[].b, 3)

    with assert_raises(contains="a must be greater than b"):
        _ = deserialize[
            CrossFieldValidator[TestStruct, "a", "b", validate_greater]
        ]('{"a": 2, "b": 3}')

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
