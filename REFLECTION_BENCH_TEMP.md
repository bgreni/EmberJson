# TEMPORARY: reflection-parse comparison, EmberJson vs simdjson

Delete this file when you're done (it is untracked).

This reproduces the 2026-09-24 comparison of EmberJson's reflection
deserializer against simdjson's C++26 static reflection (On Demand +
`get<T>()`), on the three rows the work targeted:

| Row | Input | Target type |
|---|---|---|
| `ParseCitmCatalogWithReflection` | `bench_data/data/citm_catalog.json` (1.7 MB) | `CatalogData` |
| `ParseCanadaWithReflection` | `bench_data/data/canada.json` (2.2 MB, ~111k floats) | `Canada` |
| `ParseUserBatchWithReflection` | `bench_data/users_1k.json`, split into 1000 minified docs | `User`, one parse per doc |

The C++ structs below mirror `bench.mojo`'s types field for field.

## 1. Prerequisites on the x86 machine

- `pixi` and `git`.
- **GCC 16 or newer**, for `-std=c++26 -freflection`. Clang doesn't
  implement P2996 reflection. Options:
  - Homebrew (works on Linux too): `brew install gcc` gives `g++-16`.
    This is what was used on the Mac (Homebrew GCC 16.2.0).
  - Your distro's GCC 16 package, if it has one.
  - Docker: `docker run --rm -it -v "$PWD":/w -w /w gcc:16` (if that
    tag exists yet).
  - The bench fails to compile with `static reflection not enabled` if
    the compiler can't do reflection.

## 2. Copy the work over (both repos, unstaged)

Nothing is committed. The changes are unstaged edits in **both**
`EmberJson` and its sibling `emberserde`, which EmberJson uses through
the temporary path dependency `../emberserde`. Keep the sibling layout.
On the Mac:

```bash
cd ~/Coding
tar --exclude='.pixi' --exclude='*.mojoc' -czf reflection-work.tgz EmberJson emberserde
```

Unpack it into one directory on the x86 machine. `.git` travels with
the tarball, so `git status` and `git diff` still show the work.

## 3. Build and verify correctness first

```bash
cd EmberJson
pixi install
pixi reinstall emberserde      # required whenever ../emberserde changes

pixi run test                  # expect 521 tests, all passing
pixi run mojo -D ASSERT=all -I . test/emberjson/serde/test_indexed_differential.mojo
pixi run fuzz
(cd ../emberserde && pixi run test)   # expect 26 test files passed
```

Run these before measuring anything. The new stage-1 backslash-offset
output and the indexed deserializer have only run on ARM (NEON). On x86,
stage 1 takes the AVX2 path (`emberjson/simd.mojo`,
`emberjson/_index/simd_ops.mojo`). The differential test checks the
indexed engine against the byte-walk engine over about 30k mutated
documents, so it covers that path.

## 4. EmberJson numbers

```bash
pixi run bench 2>&1 | grep -E "Parse(CitmCatalog|Canada|UserBatch)WithReflection |Stage1(CitmCatalog|Canada) "
```

- `pixi run bench` builds `bench.mojo` for the host CPU and runs the
  whole suite, which takes a few minutes. Read the `met (ms)` column.
  Don't pass `--target-cpu generic` anywhere, or stage 1 falls back to
  the portable path.
- Ignore `bench_compare` here. `bench_result.txt` was recorded on the
  M3, so the relative column means nothing on another machine.
- The `Stage1*` rows time stage 1 alone (the structural index), for
  context.

## 5. simdjson numbers

```bash
git clone https://github.com/simdjson/simdjson.git sj-master
git -C sj-master checkout 82d0b8ef5068557221639cbc6494de4a9b9cf700   # master as of 2026-09-23
# save the source below as sj_reflection_bench.cpp, then:
g++-16 -O3 -DNDEBUG -std=c++26 -freflection -Isj-master/include -Isj-master/src \
    sj_reflection_bench.cpp sj-master/src/simdjson.cpp -o sj_bench
./sj_bench /path/to/EmberJson/bench_data
```

- simdjson picks its kernel at runtime, and the bench prints the
  choice: expect `haswell` (AVX2) or `icelake` (AVX-512). No `-march`
  flag is needed.
- Each row runs 20 warmup iterations, then times for at least 1 s and
  at least 100 iterations. It prints mean, median and min in ms.
- `Stage1Only*` is simdjson's structural index plus UTF-8 validation,
  with no value extraction. Use it for context against EmberJson's
  `Stage1*` rows.

<details><summary><code>sj_reflection_bench.cpp</code></summary>

```cpp
// simdjson C++26-reflection counterparts of EmberJson's reflection bench rows.
// Usage: ./sj_bench <path/to/EmberJson/bench_data>
#include "simdjson.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#if !SIMDJSON_STATIC_REFLECTION
#error "static reflection not enabled (need GCC 16+ with -std=c++26 -freflection)"
#endif

using namespace simdjson;
template <typename V> using Dict = std::unordered_map<std::string, V>;

// Same shapes as bench.mojo's CatalogData / Canada / User.
struct Price { int64_t amount; int64_t audienceSubCategoryId; int64_t seatCategoryId; };
struct Area { int64_t areaId; std::vector<int64_t> blockIds; };
struct SeatCategory { std::vector<Area> areas; int64_t seatCategoryId; };
struct Performance {
  int64_t eventId; int64_t id; std::optional<std::string> logo;
  std::optional<std::string> name; std::vector<Price> prices;
  std::vector<SeatCategory> seatCategories; std::optional<std::string> seatMapImage;
  int64_t start; std::string venueCode;
};
struct Event {
  std::optional<std::string> description; int64_t id; std::optional<std::string> logo;
  std::string name; std::vector<int64_t> subTopicIds; std::optional<int64_t> subjectCode;
  std::optional<std::string> subtitle; std::vector<int64_t> topicIds;
};
struct CatalogData {
  Dict<std::string> areaNames; Dict<std::string> audienceSubCategoryNames;
  Dict<std::string> blockNames; Dict<Event> events; std::vector<Performance> performances;
  Dict<std::string> seatCategoryNames; Dict<std::string> subTopicNames;
  Dict<std::string> subjectNames; Dict<std::string> topicNames;
  Dict<std::vector<int64_t>> topicSubTopics; Dict<std::string> venueNames;
};

// EmberJson uses Tuple[Float64, Float64]; simdjson has no tuple support, so a
// two-element array needs a minimal custom tag_invoke.
struct Point { double x, y; };
struct Geometry { std::string type; std::vector<std::vector<Point>> coordinates; };
struct Properties { std::string name; };
struct Feature { std::string type; Properties properties; Geometry geometry; };
struct Canada { std::string type; std::vector<Feature> features; };

struct Friend { std::string name; std::vector<std::string> hobbies; };
struct User { int64_t id; std::string name; std::string city; int64_t age; std::vector<Friend> friends; };

namespace simdjson {
template <typename simdjson_value>
error_code tag_invoke(deserialize_tag, simdjson_value &val, Point &p) noexcept {
  ondemand::array arr;
  SIMDJSON_TRY(val.get_array().get(arr));
  size_t i = 0;
  for (auto v : arr) {
    double d;
    SIMDJSON_TRY(v.get_double().get(d));
    if (i == 0) { p.x = d; } else if (i == 1) { p.y = d; } else { return INCORRECT_TYPE; }
    ++i;
  }
  return i == 2 ? SUCCESS : INCORRECT_TYPE;
}
} // namespace simdjson

template <typename T> static inline void keep(T const &v) { asm volatile("" : : "r"(&v) : "memory"); }

// Time `f` for >= 1s and >= 100 iterations after 20 warmup runs.
template <typename F> static void run(const char *name, size_t bytes, F &&f) {
  using clk = std::chrono::steady_clock;
  for (int i = 0; i < 20; i++) { f(); }
  std::vector<double> t;
  auto start = clk::now();
  while (t.size() < 100 || clk::now() - start < std::chrono::seconds(1)) {
    auto a = clk::now();
    f();
    t.push_back(std::chrono::duration<double, std::milli>(clk::now() - a).count());
  }
  std::sort(t.begin(), t.end());
  double mean = 0;
  for (double x : t) { mean += x; }
  mean /= t.size();
  double med = t[t.size() / 2];
  printf("| %-32s | %9.4f | %9.4f | %9.4f | %7.3f |\n", name, mean, med, t.front(), bytes / (med * 1e6));
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <EmberJson/bench_data>\n", argv[0]); return 1; }
  const std::string dir = std::string(argv[1]) + "/";
  padded_string citm = padded_string::load(dir + "data/citm_catalog.json");
  padded_string canada = padded_string::load(dir + "data/canada.json");
  padded_string users_json = padded_string::load(dir + "users_1k.json");

  // Same corpus as bench.mojo's make_corpus: one minified doc per element.
  std::vector<padded_string> users;
  size_t users_bytes = 0;
  {
    dom::parser dp;
    for (dom::element e : dp.parse(users_json).get_array()) {
      users.emplace_back(minify(e));
      users_bytes += users.back().size();
    }
  }

  ondemand::parser parser;
  {
    CatalogData c = parser.iterate(citm).get<CatalogData>();
    Canada k = parser.iterate(canada).get<Canada>();
    printf("sanity: citm %zu events, %zu performances; canada %zu features; users %zu docs\n",
           c.events.size(), c.performances.size(), k.features.size(), users.size());
    printf("implementation: %s\n\n", get_active_implementation()->name().c_str());
  }

  printf("| %-32s | %9s | %9s | %9s | %7s |\n", "name", "mean ms", "med ms", "min ms", "GB/s");
  printf("|%s|-----------|-----------|-----------|---------|\n", std::string(34, '-').c_str());
  run("ParseCitmCatalogWithReflection", citm.size(), [&] {
    CatalogData c = parser.iterate(citm).get<CatalogData>(); keep(c);
  });
  run("ParseCanadaWithReflection", canada.size(), [&] {
    Canada c = parser.iterate(canada).get<Canada>(); keep(c);
  });
  run("ParseUserBatchWithReflection", users_bytes, [&] {
    for (auto &d : users) { User u = parser.iterate(d).get<User>(); keep(u); }
  });
  // Context: stage 1 (structural index + UTF-8 validation) alone.
  run("Stage1OnlyCitm", citm.size(), [&] { auto d = parser.iterate(citm); keep(d); });
  run("Stage1OnlyCanada", canada.size(), [&] { auto d = parser.iterate(canada); keep(d); });
}
```

</details>

## 6. Measuring fairly

- Quiet machine. On the Mac, one background build or Steam at 100% of
  a core wrecked the medians. Check `top` first.
- Pin both benches to the same core, e.g. `taskset -c 2 ./sj_bench ...`.
  For EmberJson, build once and pin the binary:
  `pixi run mojo build bench.mojo && taskset -c 2 ./bench`.
- On Linux, set the governor to `performance`
  (`sudo cpupower frequency-set -g performance`). Consider disabling
  turbo for stable numbers.
- Alternate the two benches for about 3 rounds and compare medians and
  minimums. Code layout alone moves EmberJson rows by about ±2% between
  builds.

## 7. Caveats to keep in mind

- **UTF-8 check:** simdjson validates UTF-8 inside stage 1. The
  EmberJson bench rows call `emberjson._serde.from_json`, which
  doesn't. The public `emberjson.from_json[T]` does, as a separate
  pass. On the M3 that pass cost about 0.017 ms on citm and nothing
  measurable on canada (the ASCII fast path runs at about 100 GB/s).
  Worth re-checking on x86.
- **Users batch** is 1000 small documents, so it mostly measures
  per-document setup (index allocation, parser construction), not
  throughput.
- **x86 stage 1** runs AVX2 at width 32. AVX-512 isn't specialized for,
  and CPUs without AVX2 take the portable path. PCLMUL is used only when
  the target has `+pclmul`.
- **Canada** needs a small custom `tag_invoke` on the simdjson side for
  `Point`, since simdjson has no tuple support. EmberJson reads
  `Tuple[Float64, Float64]` natively.

## 8. Reference: Apple M3 Pro, 2026-09-24 (interleaved, 3 rounds, median ms)

| Row | EmberJson | simdjson (arm64) |
|---|---|---|
| citm | 0.477 | 0.508 |
| canada | 1.61 | 1.73 |
| users batch | 0.634 | 0.908 |
| stage 1 alone, citm | 0.20 | 0.19 (incl. UTF-8) |
| stage 1 alone, canada | 0.31 | 0.33 (incl. UTF-8) |

The EmberJson figures above came from a scratch harness that times
`from_json_indexed` directly. `pixi run bench` measured 0.487 / 1.64 /
0.653 ms in the same session.
