from ember_json import JSON, Null, Array, Object
from ember_json import write_pretty
from testing import *

def test_fix_simd_string_parse():
    var s = R'{           "quote": "\"",           "backslash": "\\"}'
    var json = JSON.from_string(s)
    assert_equal(len(json), 2)

def test_json_object():
    var s = '{"key": 123}'
    var json = JSON.from_string(s)
    assert_true(json.is_object())
    assert_equal(json.object()["key"].int(), 123)
    assert_equal(json["key"].int(), 123)

    assert_equal(str(json), '{"key":123}')

    assert_equal(len(json), 1)

    with assert_raises():
        _ = json[2]

def test_json_array():
    var s = '[123, 345]'
    var json = JSON.from_string(s)
    assert_true(json.is_array())
    assert_equal(json.array()[0].int(), 123)
    assert_equal(json.array()[1].int(), 345)
    assert_equal(json[0].int(), 123)

    assert_equal(str(json), '[123,345]')

    assert_equal(len(json), 2)

    with assert_raises():
        _ = json["key"]

    json = JSON.from_string("[1, 2, 3]")
    assert_true(json.is_array())
    assert_equal(json[0], 1)
    assert_equal(json[1], 2)
    assert_equal(json[2], 3)

def test_equality():

    var ob = JSON.from_string('{"key": 123}')
    var ob2 = JSON.from_string('{"key": 123}')
    var arr = JSON.from_string('[123, 345]')

    assert_equal(ob, ob2)
    ob["key"] = 456
    assert_not_equal(ob, ob2)
    assert_not_equal(ob, arr)

def test_setter_object():
    var ob: JSON = Object()
    ob["key"] = "foo"
    assert_true("key" in ob)
    assert_equal(ob["key"], "foo")

def test_setter_array():
    var arr: JSON = Array(123, "foo")
    arr[0] = Null()
    assert_true(arr[0].isa[Null]())
    assert_equal(arr[1], "foo")

def test_stringify_array():
    var arr = JSON.from_string('[123,"foo",false,null]')
    assert_equal(str(arr), '[123,"foo",false,null]')

def test_pretty_print_array():
    var arr = JSON.from_string('[123,"foo",false,null]')
    var expected = """[
    123,
    "foo",
    false,
    null
]"""
    assert_equal(expected, write_pretty(arr))

    expected = """[
iamateapot123,
iamateapot"foo",
iamateapotfalse,
iamateapotnull
]"""
    assert_equal(expected, write_pretty(arr, indent=String("iamateapot")))

    arr = JSON.from_string('[123,"foo",false,{"key": null}]')
    expected = """[
    123,
    "foo",
    false,
    {
        "key": null
    }
]"""

    assert_equal(expected, write_pretty(arr))


def test_pretty_print_object():
    var ob = JSON.from_string('{"k1": null, "k2": 123}')    
    var expected = """{
    "k1": null,
    "k2": 123
}"""
    assert_equal(expected, write_pretty(ob))

    ob = JSON.from_string('{"key": 123, "k": [123, false, null]}')

    expected = """{
    "key": 123,
    "k": [
        123,
        false,
        null
    ]
}"""


def test_trailing_tokens():
    with assert_raises(contains="Invalid json, expected end of input, recieved: garbage tokens"):
        _ = JSON.from_string('[1, null, false] garbage tokens')

    with assert_raises(contains='Invalid json, expected end of input, recieved: "trailing string"'):
        _ = JSON.from_string('{"key": null} "trailing string"')

var dir = String("./bench_data/data/jsonchecker/")

def test_min_size_for_string():
    var s = '["foo",1234,null,true,{"key":"some long string teehee","other":null}]'
    var json = JSON.from_string(s)
    assert_equal(json.min_size_for_string(), s.byte_length())

def check_bytes_length(file: String):
    with open("./bench_data/data/" + file + ".json", "r") as f:
        var data = "".join(f.read().split())
        assert_equal(JSON.from_string(data).min_size_for_string(), data.byte_length())

def expect_fail(datafile: String):
    with open(dir + datafile + ".json", "r") as f:
        with assert_raises():
            var v = JSON.from_string(f.read())
            print(v)

def expect_pass(datafile: String):
    with open(dir + datafile + ".json", "r") as f:
        _ = JSON.from_string(f.read())

def test_fail02():
    expect_fail("fail02")

def test_fail03():
    expect_fail("fail03")

def test_fail04():
    expect_fail("fail04")

def test_fail05():
    expect_fail("fail05")

def test_fail06():
    expect_fail("fail06")

def test_fail07():
    expect_fail("fail07")

def test_fail08():
    expect_fail("fail08")

def test_fail09():
    expect_fail("fail09")

def test_fail10():
    expect_fail("fail10")

def test_fail11():
    expect_fail("fail11")

def test_fail12():
    expect_fail("fail12")

def test_fail13():
    expect_fail("fail13")

def test_fail14():
    expect_fail("fail14")

def test_fail15():
    expect_fail("fail15")

def test_fail16():
    expect_fail("fail16")

def test_fail17():
    expect_fail("fail17")

def test_fail19():
    expect_fail("fail19")

def test_fail20():
    expect_fail("fail20")

def test_fail21():
    expect_fail("fail21")

def test_fail22():
    expect_fail("fail22")

def test_fail23():
    expect_fail("fail23")

def test_fail24():
    expect_fail("fail24")

def test_fail25():
    expect_fail("fail25")

def test_fail26():
    expect_fail("fail26")

def test_fail27():
    expect_fail("fail27")

def test_fail28():
    expect_fail("fail28")

def test_fail29():
    expect_fail("fail29")

def test_fail30():
    expect_fail("fail30")

def test_fail31():
    expect_fail("fail31")

def test_fail32():
    expect_fail("fail32")

def test_fail33():
    expect_fail("fail33")

def test_pass():
    expect_pass("pass01")
    expect_pass("pass02")
    expect_pass("pass03")

def round_trip_test(filename: String):
    var d = String("./bench_data/data/roundtrip/")
    with open(d + filename + ".json", "r") as f:
        var src = f.read()
        var json = JSON.from_string(src)
        assert_equal(str(json), src)

def test_roundtrip01():
    round_trip_test("roundtrip01")

def test_roundtrip02():
    round_trip_test("roundtrip02")

def test_roundtrip03():
    round_trip_test("roundtrip03")

def test_roundtrip04():
    round_trip_test("roundtrip04")

def test_roundtrip05():
    round_trip_test("roundtrip05")

def test_roundtrip06():
    round_trip_test("roundtrip06")

def test_roundtrip07():
    round_trip_test("roundtrip07")

def test_roundtrip08():
    round_trip_test("roundtrip08")

def test_roundtrip09():
    round_trip_test("roundtrip09")

def test_roundtrip10():
    round_trip_test("roundtrip10")

def test_roundtrip11():
    round_trip_test("roundtrip11")

def test_roundtrip12():
    round_trip_test("roundtrip12")

def test_roundtrip13():
    round_trip_test("roundtrip13")

def test_roundtrip14():
    round_trip_test("roundtrip14")

def test_roundtrip15():
    round_trip_test("roundtrip15")

def test_roundtrip16():
    round_trip_test("roundtrip16")

def test_roundtrip17():
    round_trip_test("roundtrip17")

def test_roundtrip18():
    round_trip_test("roundtrip18")

def test_roundtrip19():
    round_trip_test("roundtrip19")

def test_roundtrip20():
    round_trip_test("roundtrip20")

def test_roundtrip21():
    round_trip_test("roundtrip21")

def test_roundtrip22():
    round_trip_test("roundtrip22")

def test_roundtrip23():
    round_trip_test("roundtrip23")


# TODO: Makes '0.0'??
# def test_roundtrip27():
#     round_trip_test("roundtrip27")


# TODO: too big so atof returns 'inf'
# def test_roundtrip24():
#     round_trip_test("roundtrip24")

# def test_roundtrip25():
#     round_trip_test("roundtrip25")

# def test_roundtrip26():
#     round_trip_test("roundtrip26")