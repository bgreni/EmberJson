from emberjson import (
    JSON,
    Null,
    Array,
    Object,
    parse,
    ParseOptions,
    minify,
    try_parse,
)
from emberjson import write_pretty
from testing import assert_equal, assert_true, assert_raises, assert_not_equal, TestSuite
from sys.param_env import is_defined


@always_inline
fn files_enabled() -> Bool:
    return not is_defined["DISABLE_TEST_FILES"]()


def test_minify():
    assert_equal(
        minify('{"key"\r\n: \t123\n, "k": \r\t[123, false, [1, \r2,   3]]}'),
        '{"key":123,"k":[123,false,[1,2,3]]}',
    )


def test_nested_access():
    var nested: JSON = {"key": [True, None, {"inner2": False}]}

    assert_equal(nested["key"][2]["inner2"].bool(), False)


def test_reject_comment():
    var s = """
    {
        // a comment
        "key": 123
    }
"""
    with assert_raises():
        _ = parse(s)


def test_json_object():
    var s = '{"key": 123}'
    var json = parse(s)
    assert_true(json.is_object())
    assert_equal(json.object()["key"].int(), 123)
    assert_equal(json.object()["key"].int(), 123)

    assert_equal(String(json), '{"key":123}')

    assert_equal(len(json), 1)


def test_json_array():
    var s = "[123, 345]"
    var json = parse(s)
    assert_true(json.is_array())
    assert_equal(json.array()[0].int(), 123)
    assert_equal(json.array()[1].int(), 345)
    assert_equal(json.array()[0].int(), 123)

    assert_equal(String(json), "[123,345]")

    assert_equal(len(json), 2)

    json = parse("[1, 2, 3]")
    assert_true(json.is_array())
    assert_equal(json.array()[0], 1)
    assert_equal(json.array()[1], 2)
    assert_equal(json.array()[2], 3)


def test_equality():
    var ob = parse('{"key": 123}')
    var ob2 = parse('{"key": 123}')
    var arr = parse("[123, 345]")

    assert_equal(ob, ob2)
    ob.object()["key"] = 456
    assert_not_equal(ob, ob2)
    assert_not_equal(ob, arr)


def test_setter_object():
    var ob: JSON = Object()
    ob.object()["key"] = "foo"
    assert_true("key" in ob)
    assert_equal(ob.object()["key"], "foo")


def test_setter_array():
    var arr: JSON = Array(123, "foo")
    arr.array()[0] = Null()
    assert_true(arr.array()[0].is_null())
    assert_equal(arr.array()[1], "foo")


def test_stringify_array():
    var arr = parse('[123,"foo",false,null]')
    assert_equal(String(arr), '[123,"foo",false,null]')


def test_pretty_print_array():
    var arr = parse('[123,"foo",false,null]')
    var expected: String = """[
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

    arr = parse('[123,"foo",false,{"key": null}]')
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
    var ob = parse('{"k1": null, "k2": 123}')
    var expected = """{
    "k1": null,
    "k2": 123
}""".as_string_slice()
    assert_equal(expected, write_pretty(ob))

    ob = parse('{"key": 123, "k": [123, false, null]}')

    expected = """{
    "k": [
        123,
        false,
        null
    ],
    "key": 123
}""".as_string_slice()

    assert_equal(expected, write_pretty(ob))

    ob = parse('{"key": 123, "k": [123, false, [1, 2, 3]]}')
    expected = """{
    "k": [
        123,
        false,
        [
            1,
            2,
            3
        ]
    ],
    "key": 123
}""".as_string_slice()
    assert_equal(expected, write_pretty(ob))


def test_trailing_tokens():
    with assert_raises(
        contains="Invalid json, expected end of input, recieved: garbage tokens"
    ):
        _ = parse("[1, null, false] garbage tokens")

    with assert_raises(
        contains=(
            'Invalid json, expected end of input, recieved: "trailing string"'
        )
    ):
        _ = parse('{"key": null} "trailing string"')


def test_incomplete_data():
    with assert_raises():
        _ = parse("[1 null, false,")

    with assert_raises():
        _ = parse('{"key": 123')

    with assert_raises():
        _ = parse('["asdce]')

    with assert_raises():
        _ = parse('["no close')


def test_compile_time():
    alias data = r"""{
    "key": [
        1.234,
        352.329384920,
        123412512,
        -12234,
        true,
        false,
        null,
        "shortstr",
        "longer string that would trigger simd code usually but can't be invoked at ctime",
        "string that has unicode in it: \u00FC"
    ]
}"""
    alias j = try_parse(data)
    assert_true(j)

    ref arr = j.value().object()["key"].array()
    assert_equal(arr[0].float(), 1.234)
    assert_equal(arr[1].float(), 352.329384920)
    assert_equal(arr[2].uint(), 123412512)
    assert_equal(arr[3].int(), -12234)
    assert_equal(arr[4].bool(), True)
    assert_equal(arr[5].bool(), False)
    assert_true(arr[6].is_null())
    assert_equal(arr[7].string(), "shortstr")
    assert_equal(
        arr[8].string(),
        (
            "longer string that would trigger simd code usually but can't be"
            " invoked at ctime"
        ),
    )
    assert_equal(arr[9].string(), "string that has unicode in it: ü")


alias dir = String("./bench_data/data/jsonchecker/")


def expect_fail(datafile: String):
    @parameter
    if files_enabled():
        with open(String(dir, datafile, ".json"), "r") as f:
            with assert_raises():
                var v = parse(f.read())
                print(v)


def expect_pass(datafile: String):
    @parameter
    if files_enabled():
        with open(String(dir, datafile, ".json"), "r") as f:
            _ = parse(f.read())


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
    @parameter
    if files_enabled():
        var d = String("./bench_data/data/roundtrip/")
        with open(String(d, filename, ".json"), "r") as f:
            var src = f.read()
            var json = parse(src)
            assert_equal(String(json), src)


def test_minify_citm_catalog():
    @parameter
    if files_enabled():
        with open("./bench_data/data/citm_catalog.json", "r") as formatted:
            with open(
                "./bench_data/data/citm_catalog_minify.json", "r"
            ) as minified:
                assert_equal(minify(formatted.read()), minified.read())


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


def test_roundtrip27():
    round_trip_test("roundtrip27")


def test_roundtrip24():
    round_trip_test("roundtrip24")


def test_roundtrip25():
    round_trip_test("roundtrip25")


def test_roundtrip26():
    round_trip_test("roundtrip26")


def test_unicode_parsing():
    # Just check it doesn't trip up on any of these
    alias s = r"""{
  "user": {
    "id": 123456,
    "username": "maría_87",
    "email": "maria87@example.com",
    "bio": "Soy una persona que ama la música, los libros, y la tecnología. Siempre en busca de nuevas aventuras. \uD83C\uDFA7 \uD83D\uDCBB",
    "location": {
      "city": "Ciudad de México",
      "country": "México",
      "region": "CDMX",
      "coordinates": {
        "latitude": 19.4326,
        "longitude": -99.1332
      }
    },
    "language": "\u00A1Hola! Soy biling\u00FCe, hablo espa\u00F1ol y \u004E\u006F\u0062\u006C\u0065\u0073\u0065 (ingl\u00E9s).",
    "time_zone": "UTC-6",
    "favorites": {
      "color": "\u0042\u006C\u0075\u0065",
      "food": "\u00F1\u006F\u0067\u0068\u006F\u0072\u0065\u0061\u006B\u0069\u0074\u0061",
      "animal": "\uD83D\uDC3E"
    }
  },
  "posts": [
    {
      "post_id": 101,
      "date": "2025-01-10T08:00:00Z",
      "content": "El clima de esta mañana es fr\u00EDo y nublado, ideal para un caf\u00E9. \uD83C\uDF75",
      "likes": 142,
      "comments": [
        {
          "user": "juan_91",
          "comment": "Suena genial, \u00F3jala que el clima mejore pronto. \uD83C\uDF0D"
        },
        {
          "user": "ana_love",
          "comment": "Perfecto para leer un buen libro, \u00F3jala pueda descansar. \uD83D\uDCDA"
        }
      ]
    },
    {
      "post_id": 102,
      "date": "2025-01-15T12:00:00Z",
      "content": "Estaba en el parque y vi una \uD83D\uDC2F. Nunca imagin\u00E9 encontrar una tan cerca de la ciudad.",
      "likes": 98,
      "comments": [
        {
          "user": "carlos_88",
          "comment": "Eso es asombroso. Las \uD83D\uDC2F son muy raras en el centro urbano."
        },
        {
          "user": "luisita_23",
          "comment": "¡Es increíble! Nunca vi una tan cerca de mi casa. \uD83D\uDC36"
        }
      ]
    },
    {
      "post_id": 103,
      "date": "2025-01-20T09:30:00Z",
      "content": "¡Feliz de haber terminado un proyecto importante! \uD83D\uDE0D Ahora toca disfrutar del descanso. \uD83C\uDF77",
      "likes": 210,
      "comments": [
        {
          "user": "pedro_74",
          "comment": "¡Felicidades! \uD83D\uDC4F Ahora rel\u00E1jate y disfruta un poco. \uD83C\uDF89"
        },
        {
          "user": "marta_92",
          "comment": "¡Te lo mereces! Yo estoy en medio de un proyecto, espero terminar pronto. \uD83D\uDCDD"
        }
      ]
    }
  ],
  "notifications": [
    {
      "notification_id": 201,
      "date": "2025-01-16T10:45:00Z",
      "message": "Tu solicitud de amistad fue aceptada por \u00C1lvaro. \uD83D\uDC6B",
      "status": "unread"
    },
    {
      "notification_id": 202,
      "date": "2025-01-17T14:30:00Z",
      "message": "Tienes un nuevo comentario en tu publicaci\u00F3n sobre el clima. \uD83C\uDF0A",
      "status": "read"
    },
    {
      "notification_id": 203,
      "date": "2025-01-18T16:20:00Z",
      "message": "Te han mencionado en una conversaci\u00F3n sobre el caf\u00E9 de la ma\u00F1ana. \uD83C\uDF75",
      "status": "unread"
    }
  ],
  "settings": {
    "privacy": "public",
    "notifications": "enabled",
    "theme": "\u003C\u003E\u003C\u003E\u003C\u003E Dark \u003C\u003E\u003C\u003E\u003C\u003E"
  },
  "friends": [
    {
      "id": 201,
      "name": "Álvaro",
      "status": "active",
      "last_active": "2025-01-19T18:00:00Z"
    },
    {
      "id": 202,
      "name": "Carlos",
      "status": "inactive",
      "last_active": "2025-01-10T12:00:00Z"
    },
    {
      "id": 203,
      "name": "Lucía",
      "status": "active",
      "last_active": "2025-01-21T09:45:00Z"
    },
    {
      "id": 204,
      "name": "Marta",
      "status": "active",
      "last_active": "2025-01-18T10:10:00Z"
    }
  ],
  "favorite_books": [
    {
      "title": "Cien años de soledad",
      "author": "Gabriel García Márquez",
      "description": "Un gran clásico de la literatura latinoamericana. \u201CLa realidad y la fantasía se entrelazan de forma magistral\u201D.",
      "year": 1967
    },
    {
      "title": "La sombra del viento",
      "author": "Carlos Ruiz Zafón",
      "description": "Una novela gótica que recorre los secretos de Barcelona, con misterios, amor y literatura. \u201CUn viaje fascinante\u201D.",
      "year": 2001
    },
    {
      "title": "1984",
      "author": "George Orwell",
      "description": "Una reflexión sobre el totalitarismo y el control social. \u201CLa vigilancia constante es el peor enemigo de la libertad\u201D.",
      "year": 1949
    }
  ],
  "settings_updated": "\u003C\u003E\u003C\u003E\u003C\u003E La configuraci\u00F3n se ha actualizado correctamente \uD83D\uDCE5."
}
"""
    _ = parse(s)
    _ = parse[ParseOptions(ignore_unicode=True)](s)


def main():
    var s = TestSuite.discover_tests[__functions_in_module()]()
    print(s.generate_report())