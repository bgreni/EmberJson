from emberjson import parse, try_parse, ParseOptions
from testing import assert_true, assert_equal, assert_raises, TestSuite


def test_compile_time():
    comptime data = r"""{
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
    comptime j = try_parse(data)
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


def test_unicode_parsing():
    # Just check it doesn't trip up on any of these
    comptime s = r"""{
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


def test_lone_surrogate_error():
    # Lone low surrogate (invalid)
    with assert_raises():
        _ = parse('"\\uDC00"')

    # Lone high surrogate (invalid)
    with assert_raises():
        _ = parse('"\\uD800"')

    # Valid surrogate pair (should pass)
    var j = parse('"\\uD83D\\uDD25"')  # Pair for 🔥
    assert_equal(j.string(), "🔥")


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
