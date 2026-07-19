from emberjson import (
    parse,
    parse_document,
    parse_pointer,
    is_valid_utf8,
    to_string,
    write_pretty,
    Value,
    Parser,
    minify,
    ParseOptions,
    deserialize,
    serialize,
    read_lines,
    StrictOptions,
    Lazy,
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
from emberjson._index import structural_index
from emberjson.utils import PaddedBuffer
from std.python import Python, PythonObject
from std.sys import argv
from std.pathlib import Path

comptime BenchResults = Dict[String, Float64]


def main() raises:
    var config = BenchConfig()
    config.verbose_timing = True
    config.flush_denormals = True
    config.show_progress = True
    var m = Bench(config^)
    run_benchchecks(m)


def run_benchmarks(mut m: Bench) raises:
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


def capture_report(mut m: Bench) raises -> String:
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


def parse_report(report: String) raises -> BenchResults:
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


def print_relative_performance(
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
        while name_pad.byte_length() < 45:
            name_pad = name_pad + " "

        if name in old_results:
            var old_val = old_results[name]
            var diff_pct = (new_val - old_val) / old_val * 100.0
            var speedup = new_val / old_val

            var sign = "+" if diff_pct >= 0 else ""
            var diff_str = String(sign + String(diff_pct)[byte=0:5] + "%")
            var speedup_str = String(String(speedup)[byte=0:4] + "x")
            var old_str = String(String(old_val)[byte=0:6])
            var new_str = String(String(new_val)[byte=0:6])

            # Pad output manually (inefficient but works without formatting lib)
            var pad_len = 10
            while old_str.byte_length() < pad_len:
                old_str = old_str + " "
            while new_str.byte_length() < pad_len:
                new_str = new_str + " "
            while diff_str.byte_length() < pad_len:
                diff_str = diff_str + " "
            while speedup_str.byte_length() < 11:
                speedup_str = speedup_str + " "

            # Color the diff/speedup columns. Apply after padding so the visual
            # column widths stay aligned (ANSI escapes are zero-width).
            # Threshold: ±1% to avoid coloring obvious noise.
            comptime ANSI_GREEN = "\x1b[32m"
            comptime ANSI_RED = "\x1b[31m"
            comptime ANSI_RESET = "\x1b[0m"
            if diff_pct > 1.0:
                diff_str = ANSI_GREEN + diff_str + ANSI_RESET
                speedup_str = ANSI_GREEN + speedup_str + ANSI_RESET
            elif diff_pct < -1.0:
                diff_str = ANSI_RED + diff_str + ANSI_RESET
                speedup_str = ANSI_RED + speedup_str + ANSI_RESET

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
                + String(new_val)[byte=0:6]
                + "     | N/A        | N/A         |"
            )

    print(
        "---------------------------------------------------------------------------------------------------------"
    )
    print("")


def write_report(report: String) raises:
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

        if cpu_info.byte_length() == 0:
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


def get_data(file: String) -> String:
    try:
        with open("./bench_data/data/" + file, "r") as f:
            return f.read()
    except:
        pass
    print("read failed")
    return "READ FAILED"


def get_gbs_measure(input: String) raises -> ThroughputMeasure:
    return ThroughputMeasure(BenchMetric.bytes, input.byte_length())


def run[
    func: def(mut Bencher, String) raises capturing, name: String
](mut m: Bench, data: String) raises:
    m.bench_with_input[String, func](
        BenchId(name), data, [get_gbs_measure(data)]
    )


def run[
    func: def[strict: Bool = True](mut Bencher, String) raises capturing,
    name: String,
](mut m: Bench, data: String) raises:
    @parameter
    @always_inline
    def wrapper(mut b: Bencher, s: String) raises:
        func(b, s)

    m.bench_with_input[String, wrapper](
        BenchId(name), data, [get_gbs_measure(data)]
    )


def run[
    func: def(mut Bencher, Value) raises capturing, name: String
](mut m: Bench, data: Value) raises:
    m.bench_with_input[Value, func](
        BenchId(name), data, [get_gbs_measure(String(data))]
    )


def run[
    T: Movable,
    //,
    func: def[_T: Movable](mut Bencher, _T) raises capturing,
    name: String,
](mut m: Bench, data: T) raises:
    m.bench_with_input[T, func[T]](
        BenchId(name),
        data,
        [
            get_gbs_measure(serialize(data)),
        ],
    )


def run[
    func: def(mut Bencher, Path) raises capturing, name: String
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


def run_batch[
    func: def(mut Bencher, List[String]) raises capturing, name: String
](mut m: Bench, docs: List[String]) raises:
    var total = 0
    for doc in docs:
        total += doc.byte_length()
    m.bench_with_input[List[String], func](
        BenchId(name), docs, [ThroughputMeasure(BenchMetric.bytes, total)]
    )


def make_corpus(v: Value) raises -> List[String]:
    # Split a JSON array into one standalone document per element.
    var docs = List[String]()
    for item in v.array():
        docs.append(to_string(item))
    return docs^


def run_benchchecks(mut m: Bench) raises:
    var canada = get_data("canada.json")
    var catalog = get_data("citm_catalog.json")
    var catalog_minify = get_data("citm_catalog_minify.json")
    var twitter = get_data("twitter.json")

    var data: String
    with open("./bench_data/users_1k.json", "r") as f:
        data = f.read()

    run[benchmark_json_parse, "ParseTwitter"](m, twitter)
    run[benchmark_json_parse[strict=False], "ParseTwitterNoStrictMode"](
        m, twitter
    )
    run[benchmark_json_parse, "ParseCitmCatalog"](m, catalog)
    run[
        benchmark_deserialize_with_reflection[CatalogData],
        "ParseCitmCatalogWithReflection",
    ](m, catalog)

    run[
        benchmark_deserialize_with_reflection[
            LazyCatalogData[origin_of(catalog)]
        ],
        "ParseCitmCatalogWithReflectionLazy",
    ](m, catalog)

    run[benchmark_json_parse, "ParseCitmCatalogMinify"](m, catalog_minify)
    run[
        benchmark_deserialize_with_reflection[
            LazyCatalogData[origin_of(catalog_minify)]
        ],
        "ParseCitmCatalogWithReflectionLazyMinify",
    ](m, catalog_minify)

    run[benchmark_json_parse, "ParseCanada"](m, canada)
    run[
        benchmark_deserialize_with_reflection[Canada],
        "ParseCanadaWithReflection",
    ](m, canada)

    run[benchmark_document_parse, "ParseTwitterDoc"](m, twitter)
    run[benchmark_document_parse, "ParseCitmCatalogDoc"](m, catalog)
    run[benchmark_document_parse, "ParseCitmCatalogMinifyDoc"](
        m, catalog_minify
    )
    run[benchmark_document_parse, "ParseCanadaDoc"](m, canada)

    run[benchmark_stage1, "Stage1Twitter"](m, twitter)
    run[benchmark_stage1, "Stage1CitmCatalog"](m, catalog)
    run[benchmark_stage1, "Stage1CitmCatalogMinify"](m, catalog_minify)
    run[benchmark_stage1, "Stage1Canada"](m, canada)

    run[
        benchmark_parse_pointer["/statuses/99/user/screen_name"],
        "ParsePointerTwitter",
    ](m, twitter)
    run[benchmark_parse_pointer["/venueNames"], "ParsePointerCitmCatalog"](
        m, catalog
    )
    run[benchmark_parse_pointer["/type"], "ParsePointerCanada"](m, canada)

    run[benchmark_utf8_validate, "Utf8ValidateTwitter"](m, twitter)
    run[benchmark_utf8_validate, "Utf8ValidateCanada"](m, canada)

    run[benchmark_jsonl_parse, "ParseLargeJSONL"](
        m, "./bench_data/big_lines_complex.jsonl"
    )

    run[benchmark_json_parse, "ParseExtraLarge"](m, data)
    run[benchmark_document_parse, "ParseExtraLargeDoc"](m, data)
    run[benchmark_json_parse, "ParseHeavyUnicode"](m, unicode)
    run[benchmark_ignore_unicode, "ParseHeavyIgnoreUnicode"](m, unicode)

    # Web-server-style workloads: many independent small payloads, each
    # parsed from a fresh buffer. Batching keeps the aggregate measurement
    # at a stable ms scale while staying in the regime where per-parse
    # overhead (buffer setup, allocations) dominates.
    # Statuses: ~100 docs of ~4.7KB (rich API responses).
    # Users: ~1000 docs of ~310B (tiny microservice responses).
    var statuses = make_corpus(parse(twitter)["statuses"])
    var users = make_corpus(parse(data))
    run_batch[benchmark_batch_parse, "ParseStatusBatch"](m, statuses)
    run_batch[benchmark_batch_document_parse, "ParseStatusBatchDoc"](
        m, statuses
    )
    run_batch[benchmark_batch_parse, "ParseUserBatch"](m, users)
    run_batch[benchmark_batch_document_parse, "ParseUserBatchDoc"](m, users)
    run_batch[
        benchmark_batch_deserialize[User], "ParseUserBatchWithReflection"
    ](m, users)

    run[benchmark_value_stringify, "StringifyCanada"](m, parse(canada))
    run[benchmark_reflection_serialize, "StringifyCanadaWithReflection"](
        m, deserialize[Canada](canada)
    )
    run[benchmark_value_stringify, "StringifyTwitter"](m, parse(twitter))

    run[benchmark_reflection_serialize, "StringifyCitmCatalogWithReflection"](
        m, deserialize[CatalogData](catalog)
    )
    run[benchmark_value_stringify, "StringifyCitmCatalog"](m, parse(catalog))

    run[benchmark_minify, "MinifyCitmCatalog"](m, catalog)
    run[benchmark_pretty_print, "WritePrettyCitmCatalog"](m, parse(catalog))
    run[benchmark_pretty_print, "WritePrettyTwitter"](m, parse(twitter))
    run[benchmark_pretty_print, "WritePrettyCanada"](m, parse(canada))

    run_benchmarks(m)


@parameter
def benchmark_jsonl_parse(mut b: Bencher, p: Path) raises:
    @always_inline
    @parameter
    def do() raises:
        var lines = read_lines(p).collect()
        keep(lines)

    b.iter[do]()


@parameter
def benchmark_ignore_unicode(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        var p = Parser[options=ParseOptions(ignore_unicode=True)](s)
        var v = p.parse()
        keep(v)

    b.iter[do]()


@parameter
def benchmark_minify(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        var v = minify(s)
        keep(v)

    b.iter[do]()


@parameter
def benchmark_reflection_serialize[
    T: Movable, //
](mut b: Bencher, data: T) raises:
    @always_inline
    @parameter
    def do():
        var a = serialize(data)
        keep(a)

    b.iter[do]()


@parameter
def benchmark_pretty_print(mut b: Bencher, s: Value) raises:
    @always_inline
    @parameter
    def do():
        var a = write_pretty(s)
        keep(a)

    b.iter[do]()


@parameter
def benchmark_utf8_validate(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        keep(is_valid_utf8(StringSlice(s)))

    b.iter[do]()


@parameter
def benchmark_parse_pointer[
    path: StringLiteral
](mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        var v = parse_pointer(s, String(path))
        keep(v)

    b.iter[do]()


@parameter
def benchmark_stage1(mut b: Bencher, s: String) raises:
    # End-to-end stage-1 structural indexing: pad-copy + index, fresh
    # buffers per iteration (matching the Parse* rows' methodology).
    @always_inline
    @parameter
    def do() raises:
        var buf = PaddedBuffer(StringSlice(s).as_bytes())
        var span = buf.span()
        var positions = List[UInt32]()
        structural_index[True](span.unsafe_ptr(), len(span), positions)
        keep(positions)

    b.iter[do]()


@parameter
def benchmark_document_parse(mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        var d = parse_document(s)
        keep(d)

    b.iter[do]()


@parameter
def benchmark_batch_parse(mut b: Bencher, docs: List[String]) raises:
    @always_inline
    @parameter
    def do() raises:
        for doc in docs:
            var v = parse(doc)
            keep(v)

    b.iter[do]()


@parameter
def benchmark_batch_document_parse(mut b: Bencher, docs: List[String]) raises:
    @always_inline
    @parameter
    def do() raises:
        for doc in docs:
            var d = parse_document(doc)
            keep(d)

    b.iter[do]()


@parameter
def benchmark_batch_deserialize[
    T: Movable & ImplicitlyDeletable
](mut b: Bencher, docs: List[String]) raises:
    @always_inline
    @parameter
    def do() raises:
        for doc in docs:
            var parser = Parser(doc)
            var a = deserialize[T](parser^)
            keep(a)

    b.iter[do]()


@parameter
def benchmark_json_parse[strict: Bool = True](mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        var a = parse[
            ParseOptions(
                strict_mode=StrictOptions.STRICT if strict else StrictOptions.LENIENT
            )
        ](s)
        keep(a)

    b.iter[do]()


@parameter
def benchmark_value_stringify(mut b: Bencher, v: Value) raises:
    @always_inline
    @parameter
    def do():
        var a = to_string(v)
        keep(a)

    b.iter[do]()


comptime LazyCatalogData[origin: ImmutOrigin] = Lazy[CatalogData, origin]


struct CatalogData(Defaultable, Movable):
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

    def __init__(out self):
        self.areaNames = Dict[String, String]()
        self.audienceSubCategoryNames = Dict[String, String]()
        self.blockNames = Dict[String, String]()
        self.events = Dict[String, Event]()
        self.performances = List[Performance]()
        self.seatCategoryNames = Dict[String, String]()
        self.subTopicNames = Dict[String, String]()
        self.subjectNames = Dict[String, String]()
        self.topicNames = Dict[String, String]()
        self.topicSubTopics = Dict[String, List[Int]]()
        self.venueNames = Dict[String, String]()


struct Event(Copyable, Defaultable):
    var description: Optional[String]
    var id: Int
    var logo: Optional[String]
    var name: String
    var subTopicIds: List[Int]
    var subjectCode: Optional[Int]
    var subtitle: Optional[String]
    var topicIds: List[Int]

    def __init__(out self):
        self.description = None
        self.id = 0
        self.logo = None
        self.name = ""
        self.subTopicIds = List[Int]()
        self.subjectCode = None
        self.subtitle = None
        self.topicIds = List[Int]()


struct Performance(Copyable, Defaultable):
    var eventId: Int
    var id: Int
    var logo: Optional[String]
    var name: Optional[String]
    var prices: List[Price]
    var seatCategories: List[SeatCategory]
    var seatMapImage: Optional[String]
    var start: Int
    var venueCode: String

    def __init__(out self):
        self.eventId = 0
        self.id = 0
        self.logo = None
        self.name = None
        self.prices = List[Price]()
        self.seatCategories = List[SeatCategory]()
        self.seatMapImage = None
        self.start = 0
        self.venueCode = ""


struct SeatCategory(Copyable, Defaultable):
    var areas: List[Area]
    var seatCategoryId: Int

    def __init__(out self):
        self.areas = List[Area]()
        self.seatCategoryId = 0


struct Area(Copyable, Defaultable):
    var areaId: Int
    var blockIds: List[Int]

    def __init__(out self):
        self.areaId = 0
        self.blockIds = List[Int]()


struct Price(Copyable, Defaultable):
    var amount: Int
    var audienceSubCategoryId: Int
    var seatCategoryId: Int

    def __init__(out self):
        self.amount = 0
        self.audienceSubCategoryId = 0
        self.seatCategoryId = 0


struct Canada(Defaultable, Movable):
    var type: String
    var features: List[Feature]

    def __init__(out self):
        self.type = ""
        self.features = List[Feature]()


struct Feature(Copyable, Defaultable):
    var type: String
    var properties: Properties
    var geometry: Geometry

    def __init__(out self):
        self.type = ""
        self.properties = Properties()
        self.geometry = Geometry()


struct Geometry(Copyable, Defaultable):
    var type: String
    var coordinates: List[List[Tuple[Float64, Float64]]]

    def __init__(out self):
        self.type = ""
        self.coordinates = List[List[Tuple[Float64, Float64]]]()


struct Properties(Copyable, Defaultable):
    var name: String

    def __init__(out self):
        self.name = ""


struct User(Defaultable, Movable):
    var id: Int
    var name: String
    var city: String
    var age: Int
    var friends: List[Friend]

    def __init__(out self):
        self.id = 0
        self.name = ""
        self.city = ""
        self.age = 0
        self.friends = List[Friend]()


struct Friend(Copyable, Defaultable):
    var name: String
    var hobbies: List[String]

    def __init__(out self):
        self.name = ""
        self.hobbies = List[String]()


@parameter
def benchmark_deserialize_with_reflection[
    T: Movable & ImplicitlyDeletable
](mut b: Bencher, s: String) raises:
    @always_inline
    @parameter
    def do() raises:
        var parser = Parser(s)
        var a = deserialize[T](parser^)
        keep(a)

    b.iter[do]()


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
