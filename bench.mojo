from emberjson import (
    parse,
    to_string,
    write_pretty,
    Value,
    Parser,
    minify,
    ParseOptions,
    Null,
    deserialize,
    serialize,
    read_lines,
)
from std.benchmark import (
    Bench,
    BenchId,
    ThroughputMeasure,
    Bencher,
    BenchMetric,
    BenchConfig,
    keep,
)
from python import Python, PythonObject
from std.sys import argv
from std.pathlib import Path

comptime BenchResults = Dict[String, Float64]


fn main() raises:
    var config = BenchConfig()
    config.verbose_timing = True
    config.flush_denormals = True
    config.show_progress = True
    var m = Bench(config^)
    run_benchchecks(m)


fn run_benchmarks(mut m: Bench) raises:
    var args = argv()
    var print_relative = False
    var overwrite = False

    for i in range(len(args)):
        if args[i] == "--print-relative":
            print_relative = True
        if args[i] == "--overwrite":
            overwrite = True

    var report_str: String
    if print_relative or overwrite:
        report_str = capture_report(m)
        print(report_str)
    else:
        m.dump_report()
        return

    var new_results = parse_report(report_str)

    if print_relative:
        var old_content: String = ""
        try:
            with open("bench_result.txt", "r") as f:
                old_content = f.read()
        except:
            print("Could not read bench_result.txt for comparison")
        var old_results = parse_report(old_content)
        print_relative_performance(old_results^, new_results^)

    if overwrite:
        write_report(report_str)


fn capture_report(mut m: Bench) raises -> String:
    var os = Python.import_module("os")
    var sys_py = Python.import_module("sys")
    var io = Python.import_module("io")

    # Create pipe
    var r_w = os.pipe()  # Returns (r, w) tuple
    var r = r_w[0]
    var w = r_w[1]

    var stdout_fd = sys_py.stdout.fileno()
    var saved_stdout = os.dup(stdout_fd)

    # Redirect stdout to pipe
    _ = os.dup2(w, stdout_fd)

    m.dump_report()

    # Flush and restore
    _ = sys_py.stdout.flush()
    _ = os.dup2(saved_stdout, stdout_fd)
    _ = os.close(w)

    # Read from pipe
    var file_obj = os.fdopen(r)
    var content = file_obj.read()

    return String(content)


fn parse_report(report: String) raises -> BenchResults:
    var lines = report.split("\n")
    var results = BenchResults()

    # Find header index
    var header_idx = -1
    var col_idx = -1
    for i in range(len(lines)):
        if "DataMovement (GB/s)" in lines[i]:
            header_idx = i
            var parts = lines[i].split("|")
            for j in range(len(parts)):
                if "DataMovement (GB/s)" in parts[j]:
                    col_idx = j
            break

    if header_idx == -1 or col_idx == -1:
        return results^

    for i in range(header_idx + 1, len(lines)):
        var line = lines[i]
        if not line or line.strip().startswith("-"):
            continue
        var parts = line.split("|")
        if len(parts) > col_idx:
            var name = parts[1].strip()
            var val_str = parts[col_idx].strip()
            try:
                # Try direct Float64 parsing from string
                var val_flt = Float64(val_str)
                results[String(name)] = val_flt
            except:
                pass

    return results^


fn print_relative_performance(
    var old_results: BenchResults,
    var new_results: BenchResults,
) raises:
    print("")
    print("Relative Performance (GB/s vs bench_result.txt)")
    print(
        "---------------------------------------------------------------------------------------------------------"
    )
    print(
        "| Benchmark Name                                | Old (GB/s) | New"
        " (GB/s) | Diff       | Speedup     |"
    )
    print(
        "|-----------------------------------------------|------------|------------|------------|-------------|"
    )

    for item in new_results.items():
        var name = item.key
        var new_val = item.value

        var name_pad = name
        while len(name_pad) < 45:
            name_pad = name_pad + " "

        if name in old_results:
            var old_val = old_results[name]
            var diff_pct = (new_val - old_val) / old_val * 100.0
            var speedup = new_val / old_val

            var sign = "+" if diff_pct >= 0 else ""
            var diff_str = String(sign + String(diff_pct)[0:5] + "%")
            var speedup_str = String(String(speedup)[0:4] + "x")
            var old_str = String(String(old_val)[0:6])
            var new_str = String(String(new_val)[0:6])

            # Pad output manually (inefficient but works without formatting lib)
            var pad_len = 10
            while len(old_str) < pad_len:
                old_str = old_str + " "
            while len(new_str) < pad_len:
                new_str = new_str + " "
            while len(diff_str) < pad_len:
                diff_str = diff_str + " "
            while len(speedup_str) < 11:
                speedup_str = speedup_str + " "

            print(
                "| "
                + name_pad
                + " | "
                + old_str
                + " | "
                + new_str
                + " | "
                + diff_str
                + " | "
                + speedup_str
                + " |"
            )
        else:
            print(
                "| "
                + name_pad
                + " | N/A        | "
                + String(new_val)[0:6]
                + "     | N/A        | N/A         |"
            )

    print(
        "---------------------------------------------------------------------------------------------------------"
    )
    print("")


fn write_report(report: String) raises:
    var header = String("Run on unknown system")
    try:
        var platform = Python.import_module("platform")
        var system = String(platform.system())

        var cpu_info = String("")
        if system == "Darwin":
            var subprocess = Python.import_module("subprocess")
            # Try to get MacOS CPU brand string
            try:
                var cmd = Python.evaluate(
                    "['sysctl', '-n', 'machdep.cpu.brand_string']"
                )
                var res = subprocess.check_output(cmd).decode("utf-8").strip()
                cpu_info = String(res)

                var cmd_cores = Python.evaluate(
                    "['sysctl', '-n', 'hw.physicalcpu']"
                )
                var cores = (
                    subprocess.check_output(cmd_cores).decode("utf-8").strip()
                )

                var cmd_mem = Python.evaluate("['sysctl', '-n', 'hw.memsize']")
                var mem_bytes = (
                    subprocess.check_output(cmd_mem).decode("utf-8").strip()
                )
                # Use Python to format bytes to GB
                var mem_gb_py = Python.evaluate(
                    "'{:.2f}'.format(" + String(mem_bytes) + "/(1024**3))"
                )
                var mem_gb = String(mem_gb_py)

                cpu_info = (
                    cpu_info
                    + "\nCores: "
                    + String(cores)
                    + "\nMemory: "
                    + mem_gb
                    + " GB"
                )
            except:
                pass

        if len(cpu_info) == 0:
            cpu_info = (
                String(platform.machine()) + " " + String(platform.processor())
            )

        header = (
            "Run on "
            + String(system)
            + " "
            + String(platform.release())
            + "\nCPU: "
            + cpu_info
        )
    except:
        pass

    var content = header + "\n\n" + report
    with open("bench_result.txt", "w") as f:
        f.write(content)
    print("Updated bench_result.txt")


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
    m.bench_with_input[String, func](
        BenchId(name), data, [get_gbs_measure(data)]
    )


fn run[
    func: fn (mut Bencher, Value) raises capturing, name: String
](mut m: Bench, data: Value) raises:
    m.bench_with_input[Value, func](
        BenchId(name), data, [get_gbs_measure(String(data))]
    )


fn run[
    T: Movable,
    //,
    func: fn[_T: Movable] (mut Bencher, _T) raises capturing,
    name: String,
](mut m: Bench, data: T) raises:
    m.bench_with_input[T, func[T]](
        BenchId(name),
        data,
        [
            get_gbs_measure(serialize(data)),
        ],
    )


fn run[
    func: fn (mut Bencher, Path) raises capturing, name: String
](mut m: Bench, path: Path) raises:
    var size: Int
    with open(path, "r") as f:
        var data = f.read()
        size = data.byte_length()

    m.bench_with_input[Path, benchmark_jsonl_parse](
        BenchId("ParseLargeJsonl"),
        path,
        [ThroughputMeasure(BenchMetric.bytes, size)],
    )


fn run_benchchecks(mut m: Bench) raises:
    var canada = get_data("canada.json")
    var catalog = get_data("citm_catalog.json")
    var twitter = get_data("twitter.json")

    var data: String
    with open("./bench_data/users_1k.json", "r") as f:
        data = f.read()

    run[benchmark_json_parse, "ParseTwitter"](m, twitter)
    run[benchmark_json_parse, "ParseCitmCatalog"](m, catalog)
    run[
        benchmark_deserialize_catalog_with_reflection,
        "ParseCitmCatalogWithReflection",
    ](m, catalog)

    run[benchmark_json_parse, "ParseCanada"](m, canada)
    run[
        benchmark_deserialize_canada_with_reflection,
        "ParseCanadaWithReflection",
    ](m, canada)

    run[benchmark_jsonl_parse, "ParseLargeJSONL"](
        m, "./bench_data/big_lines_complex.jsonl"
    )

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

    run[benchmark_value_stringify, "StringifyLarge"](m, parse(large_array))
    run[benchmark_value_stringify, "StringifyCanada"](m, parse(canada))
    run[benchmark_reflection_serialize, "StringifyCanadaWithReflection"](
        m, deserialize[Canada](canada)
    )
    run[benchmark_value_stringify, "StringifyTwitter"](m, parse(twitter))

    run[benchmark_reflection_serialize, "StringifyCitmCatalogWithReflection"](
        m, deserialize[CatalogData](catalog)
    )
    run[benchmark_value_stringify, "StringifyCitmCatalog"](m, parse(catalog))

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

    run_benchmarks(m)


@parameter
fn benchmark_jsonl_parse(mut b: Bencher, p: Path) raises:
    @always_inline
    @parameter
    fn do() raises:
        var lines = read_lines(p).collect()
        keep(lines)

    b.iter[do]()


@parameter
fn benchmark_ignore_unicode(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    fn do() raises:
        var p = Parser[options = ParseOptions(ignore_unicode=True)](s)
        var v = p.parse()
        keep(v)

    b.iter[do]()


@parameter
fn benchmark_minify(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    fn do() raises:
        var v = minify(s)
        keep(v)

    b.iter[do]()


@parameter
fn benchmark_reflection_serialize[
    T: Movable, //
](mut b: Bencher, data: T) raises:
    @always_inline
    @parameter
    fn do():
        var a = serialize(data)
        keep(a)

    b.iter[do]()


@parameter
fn benchmark_pretty_print(mut b: Bencher, s: Value) raises:
    @always_inline
    @parameter
    fn do():
        var a = write_pretty(s)
        keep(a)

    b.iter[do]()


@parameter
fn benchmark_value_parse(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    fn do() raises:
        var a = Value(parse_string=s)
        keep(a)

    b.iter[do]()


@parameter
fn benchmark_json_parse(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    fn do() raises:
        var a = parse(s)
        keep(a)

    b.iter[do]()


@parameter
fn benchmark_value_stringify(mut b: Bencher, v: Value) raises:
    @always_inline
    @parameter
    fn do():
        var a = String(v)
        keep(a)

    b.iter[do]()


struct CatalogData(Movable):
    var areaNames: Dict[String, String]
    var audienceSubCategoryNames: Dict[String, String]
    var blockNames: Dict[String, String]
    var events: Dict[String, Event]
    var performances: List[Performance]
    var seatCategoryNames: Dict[String, String]
    var subTopicNames: Dict[String, String]
    var subjectNames: Dict[String, String]
    var topicNames: Dict[String, String]
    var topicSubTopics: Dict[String, List[Int]]
    var venueNames: Dict[String, String]


struct Event(Copyable):
    var description: Optional[String]
    var id: Int
    var logo: Optional[String]
    var name: String
    var subTopicIds: List[Int]
    var subjectCode: Optional[Int]
    var subtitle: Optional[String]
    var topicIds: List[Int]


struct Performance(Copyable):
    var eventId: Int
    var id: Int
    var logo: Optional[String]
    var name: Optional[String]
    var prices: List[Price]
    var seatCategories: List[SeatCategory]
    var seatMapImage: Optional[String]
    var start: Int
    var venueCode: String


struct SeatCategory(Copyable):
    var areas: List[Area]
    var seatCategoryId: Int


struct Area(Copyable):
    var areaId: Int
    var blockIds: List[Int]


struct Price(Copyable):
    var amount: Int
    var audienceSubCategoryId: Int
    var seatCategoryId: Int


@parameter
fn benchmark_deserialize_catalog_with_reflection(
    mut b: Bencher, s: String
) raises:
    @always_inline
    @parameter
    fn do() raises:
        var parser = Parser(s)
        var a = deserialize[CatalogData](parser^)
        keep(a)

    b.iter[do]()


struct Canada(Movable):
    var type: String
    var features: List[Feature]


struct Feature(Copyable):
    var type: String
    var properties: Properties
    var geometry: Geometry


struct Geometry(Copyable):
    var type: String
    var coordinates: List[List[Tuple[Float64, Float64]]]


struct Properties(Copyable):
    var name: String


@parameter
fn benchmark_deserialize_canada_with_reflection(
    mut b: Bencher, s: String
) raises:
    @always_inline
    @parameter
    fn do() raises:
        var parser = Parser(s)
        var a = deserialize[Canada](parser^)
        keep(a)

    b.iter[do]()


# source https://opensource.adobe.com/Spry/samples/data_region/JSONDataSetSample.html
comptime small_data = """{
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

comptime medium_array = """
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

comptime large_array = """
[{"id":0,"name":"Elijah","city":"Austin","age":78,"friends":[{"name":"Michelle","hobbies":["Watching Sports","Reading","Skiing & Snowboarding"]},{"name":"Robert","hobbies":["Traveling","Video Games"]}]},{"id":1,"name":"Noah","city":"Boston","age":97,"friends":[{"name":"Oliver","hobbies":["Watching Sports","Skiing & Snowboarding","Collecting"]},{"name":"Olivia","hobbies":["Running","Music","Woodworking"]},{"name":"Robert","hobbies":["Woodworking","Calligraphy","Genealogy"]},{"name":"Ava","hobbies":["Walking","Church Activities"]},{"name":"Michael","hobbies":["Music","Church Activities"]},{"name":"Michael","hobbies":["Martial Arts","Painting","Jewelry Making"]}]},{"id":2,"name":"Evy","city":"San Diego","age":48,"friends":[{"name":"Joe","hobbies":["Reading","Volunteer Work"]},{"name":"Joe","hobbies":["Genealogy","Golf"]},{"name":"Oliver","hobbies":["Collecting","Writing","Bicycling"]},{"name":"Liam","hobbies":["Church Activities","Jewelry Making"]},{"name":"Amelia","hobbies":["Calligraphy","Dancing"]}]},{"id":3,"name":"Oliver","city":"St. Louis","age":39,"friends":[{"name":"Mateo","hobbies":["Watching Sports","Gardening"]},{"name":"Nora","hobbies":["Traveling","Team Sports"]},{"name":"Ava","hobbies":["Church Activities","Running"]},{"name":"Amelia","hobbies":["Gardening","Board Games","Watching Sports"]},{"name":"Leo","hobbies":["Martial Arts","Video Games","Reading"]}]},{"id":4,"name":"Michael","city":"St. Louis","age":95,"friends":[{"name":"Mateo","hobbies":["Movie Watching","Collecting"]},{"name":"Chris","hobbies":["Housework","Bicycling","Collecting"]}]},{"id":5,"name":"Michael","city":"Portland","age":19,"friends":[{"name":"Jack","hobbies":["Painting","Television"]},{"name":"Oliver","hobbies":["Walking","Watching Sports","Movie Watching"]},{"name":"Charlotte","hobbies":["Podcasts","Jewelry Making"]},{"name":"Elijah","hobbies":["Eating Out","Painting"]}]},{"id":6,"name":"Lucas","city":"Austin","age":76,"friends":[{"name":"John","hobbies":["Genealogy","Cooking"]},{"name":"John","hobbies":["Socializing","Yoga"]}]},{"id":7,"name":"Michelle","city":"San Antonio","age":25,"friends":[{"name":"Jack","hobbies":["Music","Golf"]},{"name":"Daniel","hobbies":["Socializing","Housework","Walking"]},{"name":"Robert","hobbies":["Collecting","Walking"]},{"name":"Nora","hobbies":["Painting","Church Activities"]},{"name":"Mia","hobbies":["Running","Painting"]}]},{"id":8,"name":"Emily","city":"Austin","age":61,"friends":[{"name":"Nora","hobbies":["Bicycling","Skiing & Snowboarding","Watching Sports"]},{"name":"Ava","hobbies":["Writing","Reading","Collecting"]},{"name":"Amelia","hobbies":["Eating Out","Watching Sports"]},{"name":"Daniel","hobbies":["Skiing & Snowboarding","Martial Arts","Writing"]},{"name":"Zoey","hobbies":["Board Games","Tennis"]}]},{"id":9,"name":"Liam","city":"New Orleans","age":33,"friends":[{"name":"Chloe","hobbies":["Traveling","Bicycling","Shopping"]},{"name":"Evy","hobbies":["Eating Out","Watching Sports"]},{"name":"Grace","hobbies":["Jewelry Making","Yoga","Podcasts"]}]}]"""

comptime unicode = r"""{
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
