from emberjson import *
from benchmark import *


fn get_data(file: String) -> String:
    try:
        with open("./bench_data/data/" + file, "r") as f:
            return f.read()
    except:
        pass
    print("read failed")
    return "READ FAILED"


fn get_gbs_measure(input: String) raises -> ThroughputMeasure:
    return ThroughputMeasure(BenchMetric.bytes, input.byte_length())


fn run[
    func: fn (mut Bencher, String) raises capturing, name: String
](mut m: Bench, data: String) raises:
    m.bench_with_input[String, func](BenchId(name), data, get_gbs_measure(data))


fn run[
    func: fn (mut Bencher, JSON) raises capturing, name: String
](mut m: Bench, data: JSON) raises:
    m.bench_with_input[JSON, func](
        BenchId(name), data, get_gbs_measure(String(data))
    )


fn run[
    func: fn (mut Bencher, Value) raises capturing, name: String
](mut m: Bench, data: Value) raises:
    m.bench_with_input[Value, func](
        BenchId(name), data, get_gbs_measure(String(data))
    )


fn main() raises:
    var config = BenchConfig()
    config.verbose_timing = True
    config.flush_denormals = True
    config.show_progress = True
    var m = Bench(config)

    var canada = get_data("canada.json")
    var catalog = get_data("citm_catalog.json")
    var twitter = get_data("twitter.json")

    var data: String
    with open("./bench_data/users_1k.json", "r") as f:
        data = f.read()

    @parameter
    fn benchmark_ignore_unicode(mut b: Bencher, s: String) raises:
        @always_inline
        @parameter
        fn do() raises:
            p = Parser[options = ParseOptions(ignore_unicode=True)](s)
            _ = p.parse()

        b.iter[do]()

    @parameter
    fn benchmark_minify(mut b: Bencher, s: String) raises:
        @always_inline
        @parameter
        fn do() raises:
            _ = minify(s)

        b.iter[do]()

    run[benchmark_json_parse, "ParseTwitter"](m, twitter)
    run[benchmark_json_parse, "ParseCitmCatalog"](m, catalog)
    run[benchmark_json_parse, "ParseCanada"](m, canada)

    run[benchmark_json_parse, "ParseSmall"](m, small_data)
    run[benchmark_json_parse, "ParseMedium"](m, medium_array)
    run[benchmark_json_parse, "ParseLarge"](m, large_array)
    run[benchmark_json_parse, "ParseExtraLarge"](m, data)
    run[benchmark_json_parse, "ParseHeavyUnicode"](m, unicode)
    run[benchmark_ignore_unicode, "ParseHeavyIgnoreUnicode"](m, unicode)

    run[benchmark_value_parse, "ParseBool"](m, "false")
    run[benchmark_value_parse, "ParseNull"](m, "null")
    run[benchmark_value_parse, "ParseInt"](m, "12345")
    run[benchmark_value_parse, "ParseFloat"](m, "453.45643")
    run[benchmark_value_parse, "ParseFloatLongDec"](m, "453.456433232")
    run[benchmark_value_parse, "ParseFloatExp"](m, "4546.5E23")
    run[benchmark_value_parse, "ParseSlowFallback"](
        m, "3.1415926535897932384626433832795028841971693993751"
    )
    run[benchmark_json_parse, "ParseFloatCoordinate"](
        m, "[-57.94027699999998,54.923607000000004]"
    )
    run[benchmark_value_parse, "ParseString"](
        m, '"some example string of short length, not all that long really"'
    )

    run[benchmark_json_stringify, "StringifyLarge"](m, parse(large_array))
    run[benchmark_json_stringify, "StringifyCanada"](m, parse(canada))
    run[benchmark_json_stringify, "StringifyTwitter"](m, parse(twitter))
    run[benchmark_json_stringify, "StringifyCitmCatalog"](m, parse(catalog))

    run[benchmark_value_stringify, "StringifyBool"](m, False)
    run[benchmark_value_stringify, "StringifyNull"](m, Null())
    # These should be the same so its more of a sanity check here
    run[benchmark_value_stringify, "StringifyInt"](m, Int64(12345))
    run[benchmark_value_stringify, "StringifyUInt"](m, UInt64(12345))
    run[benchmark_value_stringify, "StringifyFloat"](m, Float64(456.345))
    run[benchmark_value_stringify, "StringifyString"](
        m, "some example string of short length, not all that long really"
    )

    run[benchmark_minify, "MinifyCitmCatalog"](m, catalog)
    run[benchmark_pretty_print, "WritePrettyCitmCatalog"](m, parse(catalog))
    run[benchmark_pretty_print, "WritePrettyTwitter"](m, parse(twitter))
    run[benchmark_pretty_print, "WritePrettyCanada"](m, parse(canada))

    m.dump_report()


@parameter
fn benchmark_pretty_print(mut b: Bencher, s: JSON) raises:
    @always_inline
    @parameter
    fn do():
        _ = write_pretty(s)

    b.iter[do]()


@parameter
fn benchmark_value_parse(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    fn do() raises:
        _ = Value(parse_string=s)

    b.iter[do]()


@parameter
fn benchmark_json_parse(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    fn do() raises:
        _ = parse(s)

    b.iter[do]()


@parameter
fn benchmark_value_stringify(mut b: Bencher, v: Value) raises:
    @always_inline
    @parameter
    fn do():
        _ = String(v)

    b.iter[do]()


@parameter
fn benchmark_json_stringify(mut b: Bencher, json: JSON) raises:
    @always_inline
    @parameter
    fn do() raises:
        _ = String(json)

    b.iter[do]()


# source https://opensource.adobe.com/Spry/samples/data_region/JSONDataSetSample.html
var small_data = """{
	"id": "0001",
	"type": "donut",
	"name": "Cake",
	"ppu": 0.55,
	"batters":
		{
			"batter":
				[
					{ "id": "1001", "type": "Regular" },
					{ "id": "1002", "type": "Chocolate" },
					{ "id": "1003", "type": "Blueberry" },
					{ "id": "1004", "type": "Devil's Food" }
				]
		},
	"topping":
		[
			{ "id": "5001", "type": "None" },
			{ "id": "5002", "type": "Glazed" },
			{ "id": "5005", "type": "Sugar" },
			{ "id": "5007", "type": "Powdered Sugar" },
			{ "id": "5006", "type": "Chocolate with Sprinkles" },
			{ "id": "5003", "type": "Chocolate" },
			{ "id": "5004", "type": "Maple" }
		]
}"""

var medium_array = """
[
	{
		"id": "0001",
		"type": "donut",
		"name": "Cake",
		"ppu": 0.55,
		"batters":
			{
				"batter":
					[
						{ "id": "1001", "type": "Regular" },
						{ "id": "1002", "type": "Chocolate" },
						{ "id": "1003", "type": "Blueberry" },
						{ "id": "1004", "type": "Devil's Food" }
					]
			},
		"topping":
			[
				{ "id": "5001", "type": "None" },
				{ "id": "5002", "type": "Glazed" },
				{ "id": "5005", "type": "Sugar" },
				{ "id": "5007", "type": "Powdered Sugar" },
				{ "id": "5006", "type": "Chocolate with Sprinkles" },
				{ "id": "5003", "type": "Chocolate" },
				{ "id": "5004", "type": "Maple" }
			]
	},
	{
		"id": "0002",
		"type": "donut",
		"name": "Raised",
		"ppu": 0.55,
		"batters":
			{
				"batter":
					[
						{ "id": "1001", "type": "Regular" }
					]
			},
		"topping":
			[
				{ "id": "5001", "type": "None" },
				{ "id": "5002", "type": "Glazed" },
				{ "id": "5005", "type": "Sugar" },
				{ "id": "5003", "type": "Chocolate" },
				{ "id": "5004", "type": "Maple" }
			]
	},
	{
		"id": "0003",
		"type": "donut",
		"name": "Old Fashioned",
		"ppu": 0.55,
		"batters":
			{
				"batter":
					[
						{ "id": "1001", "type": "Regular" },
						{ "id": "1002", "type": "Chocolate" }
					]
			},
		"topping":
			[
				{ "id": "5001", "type": "None" },
				{ "id": "5002", "type": "Glazed" },
				{ "id": "5003", "type": "Chocolate" },
				{ "id": "5004", "type": "Maple" }
			]
	}
]
"""

var large_array = """
[{"id":0,"name":"Elijah","city":"Austin","age":78,"friends":[{"name":"Michelle","hobbies":["Watching Sports","Reading","Skiing & Snowboarding"]},{"name":"Robert","hobbies":["Traveling","Video Games"]}]},{"id":1,"name":"Noah","city":"Boston","age":97,"friends":[{"name":"Oliver","hobbies":["Watching Sports","Skiing & Snowboarding","Collecting"]},{"name":"Olivia","hobbies":["Running","Music","Woodworking"]},{"name":"Robert","hobbies":["Woodworking","Calligraphy","Genealogy"]},{"name":"Ava","hobbies":["Walking","Church Activities"]},{"name":"Michael","hobbies":["Music","Church Activities"]},{"name":"Michael","hobbies":["Martial Arts","Painting","Jewelry Making"]}]},{"id":2,"name":"Evy","city":"San Diego","age":48,"friends":[{"name":"Joe","hobbies":["Reading","Volunteer Work"]},{"name":"Joe","hobbies":["Genealogy","Golf"]},{"name":"Oliver","hobbies":["Collecting","Writing","Bicycling"]},{"name":"Liam","hobbies":["Church Activities","Jewelry Making"]},{"name":"Amelia","hobbies":["Calligraphy","Dancing"]}]},{"id":3,"name":"Oliver","city":"St. Louis","age":39,"friends":[{"name":"Mateo","hobbies":["Watching Sports","Gardening"]},{"name":"Nora","hobbies":["Traveling","Team Sports"]},{"name":"Ava","hobbies":["Church Activities","Running"]},{"name":"Amelia","hobbies":["Gardening","Board Games","Watching Sports"]},{"name":"Leo","hobbies":["Martial Arts","Video Games","Reading"]}]},{"id":4,"name":"Michael","city":"St. Louis","age":95,"friends":[{"name":"Mateo","hobbies":["Movie Watching","Collecting"]},{"name":"Chris","hobbies":["Housework","Bicycling","Collecting"]}]},{"id":5,"name":"Michael","city":"Portland","age":19,"friends":[{"name":"Jack","hobbies":["Painting","Television"]},{"name":"Oliver","hobbies":["Walking","Watching Sports","Movie Watching"]},{"name":"Charlotte","hobbies":["Podcasts","Jewelry Making"]},{"name":"Elijah","hobbies":["Eating Out","Painting"]}]},{"id":6,"name":"Lucas","city":"Austin","age":76,"friends":[{"name":"John","hobbies":["Genealogy","Cooking"]},{"name":"John","hobbies":["Socializing","Yoga"]}]},{"id":7,"name":"Michelle","city":"San Antonio","age":25,"friends":[{"name":"Jack","hobbies":["Music","Golf"]},{"name":"Daniel","hobbies":["Socializing","Housework","Walking"]},{"name":"Robert","hobbies":["Collecting","Walking"]},{"name":"Nora","hobbies":["Painting","Church Activities"]},{"name":"Mia","hobbies":["Running","Painting"]}]},{"id":8,"name":"Emily","city":"Austin","age":61,"friends":[{"name":"Nora","hobbies":["Bicycling","Skiing & Snowboarding","Watching Sports"]},{"name":"Ava","hobbies":["Writing","Reading","Collecting"]},{"name":"Amelia","hobbies":["Eating Out","Watching Sports"]},{"name":"Daniel","hobbies":["Skiing & Snowboarding","Martial Arts","Writing"]},{"name":"Zoey","hobbies":["Board Games","Tennis"]}]},{"id":9,"name":"Liam","city":"New Orleans","age":33,"friends":[{"name":"Chloe","hobbies":["Traveling","Bicycling","Shopping"]},{"name":"Evy","hobbies":["Eating Out","Watching Sports"]},{"name":"Grace","hobbies":["Jewelry Making","Yoga","Podcasts"]}]}]"""

alias unicode = r"""{
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
