# Changelog

All notable changes to EmberJson are documented here.

## Unreleased — the emberserde migration

EmberJson no longer owns a serialization trait system. Reflection-based
`serialize`/`deserialize` now ride **emberserde**, a format-agnostic
serialization framework, with EmberJson supplying the JSON *format* for it
(`emberjson/_serde/`).

The parser, the SIMD structural index, the Teju Jagua float writer and the
UTF-8 validator are untouched — the JSON text they produce and consume is
identical to before. What changed is the surface above them: the nine
JSON entry points that used to expose that machinery are now the four
described in the first breaking change below.

### Breaking changes

#### 1. The JSON entry points are unified into `from_json` / `to_json`

The JSON entry points are unified into `from_json`, `try_from_json`,
`to_json` and `to_json_pretty`. `parse`, `try_parse`, `parse_document`,
`try_parse_document`, `deserialize`, `try_deserialize`, `serialize`,
`to_string` and `write_pretty` are removed with no deprecation period.

| old | new |
| --- | --- |
| `parse(s)` | `from_json[Value](s)` |
| `try_parse(s)` | `try_from_json[Value](s)` |
| `parse_document(s)` | `from_json[Document](s)` |
| `try_parse_document(s)` | `try_from_json[Document](s)` |
| `deserialize[T](s)` | `from_json[T](s)` |
| `try_deserialize[T](s)` | `try_from_json[T](s)` |
| `to_string(v)` / `serialize(v)` | `to_json(v)` |
| `write_pretty(v)` | `to_json_pretty(v)` |

`parse_pointer` and `try_parse_pointer` are unchanged.

UTF-8 validation now applies uniformly. Reflection-based deserialization
previously skipped the check; it no longer does. Pass
`ParseOptions(validate_utf8=False)` to opt out.

`to_json[pretty=True]` on a `Document` is a compile-time error —
`Document` has no indented writer. Deserialize into a `Value` first.

#### 2. Unknown wire fields are skipped, not rejected

A JSON key matching no declared struct field used to raise
`"Unexpected field: <name>"`. It is now **skipped** — serde/Jackson
convention, and what makes forward-compatible schema evolution possible.

Skipping is not a parser bypass: the skipped value is still walked and
validated in full (`Parser.expect_value_bytes`), so malformed JSON inside
an unknown field is still an error.

To get the old behaviour back, conform the struct to
`emberserde.DenyUnknownFields`:

```mojo
from emberserde import DenyUnknownFields

@fieldwise_init
struct Strict(DenyUnknownFields, Defaultable, Movable):
    var x: Int

    def __init__(out self):
        self.x = 0

# raises DeserializationError(kind=UnknownField)
_ = from_json[Strict]('{"x": 1, "extra": 2}')
```

This is a **permissiveness** change on a security-relevant surface: a
caller who relied on EmberJson rejecting unexpected keys now gets no
error. Audit for that before upgrading.

#### 3. `Default` fills on an absent key only, never on an explicit `null`

`Default[T, d]` is now emberserde's `Field[T, default=d]`, and its
fallback fires when the key is **missing from the object**. An explicit
`null` is a *present* value and is parsed as `T` — which for a
non-`Optional` `T` is now an error where it previously produced the
default.

```mojo
from emberjson import from_json, Defaulted


@fieldwise_init
struct Rec(Defaultable, Movable):
    var a: Int
    var b: Defaulted[Int, 42]

    def __init__(out self):
        self.a = 0
        self.b = {}


@fieldwise_init
struct OptRec(Defaultable, Movable):
    var a: Int
    var b: Defaulted[Optional[Int], Optional[Int](42)]

    def __init__(out self):
        self.a = 0
        self.b = {}


def main() raises:
    # Key absent -> the default fills (unchanged).
    print(from_json[Rec]('{"a": 1}').b[])          # prints 42

    # Explicit null -> a PRESENT value, parsed as `Int`: now an error.
    try:
        _ = from_json[Rec]('{"a": 1, "b": null}')
        print("accepted")
    except e:
        print("raises:", e.kind)

    # Escape hatch: an `Optional` payload resolves both absence and null.
    print(from_json[OptRec]('{"a": 1, "b": null}').b[])  # prints None
    print(from_json[OptRec]('{"a": 1}').b[])             # prints 42
```

This one is silent at the call site: nothing about the spelling changes,
only the behaviour on `null`.

#### 4. `JsonSerializable` / `JsonDeserializable` removed

Implement emberserde's `Serializable` / `Deserializable` instead. They are
format-agnostic, so an implementation works for any emberserde format.

Before, a custom type declared `write_json` / `from_json`:

```mojo
def write_json(self, mut writer: Some[Serializer]):   # EmberJson's Serializer
    writer.write(self.value)

@staticmethod
def from_json(mut p: Parser) raises -> Self:
    return Self(p.expect_int())
```

Now it declares `serialize` / `deserialize` against emberserde's traits:

```mojo
from emberjson import from_json, to_json
from emberserde import (
    Deserializable,
    DeserializationError,
    Deserializer,
    Serializable,
    SerializationError,
    Serializer,
)


@fieldwise_init
struct Counter(Deserializable, Serializable):
    var value: Int64

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(self.value)

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(d.expect_number[DType.int64]())


def main() raises:
    print(to_json(Counter(7)))
    print(from_json[Counter]("7").value)
```

Removed along with them: EmberJson's own `Serializer` and
`PrettySerializer` types, and the `write_json`/`from_json` methods on
`Value`, `Object`, `Array`, `Null` and `Lazy`. The `Serializer` /
`Deserializer` names now refer to emberserde's traits.

See the README's *Custom serialization and deserialization* section for a
complete working example.

#### 5. `serialize_as_array` / `deserialize_as_array` removed, with no counterpart

A struct could opt into riding the wire as a JSON array (`[1, 2]` instead
of `{"x":1,"y":2}`). emberserde has no equivalent: a struct is always an
object.

Workarounds: use a `Tuple` field (emberserde encodes tuples as arrays), or
hand-write a `Serializable`/`Deserializable` pair driving
`begin_seq`/`begin_tuple` directly.

#### 6. The `Parser`-taking `deserialize` / `try_deserialize` overloads are gone

```mojo
# before
var parser = Parser[options](doc)
var v = deserialize[T](parser^)

# now — `ParseOptions` is a parameter on the function itself
# (and, per breaking change 1 above, the function itself is `from_json`)
var v = from_json[T, options](doc)
```

The overload existed mainly to let callers choose `ParseOptions`. That
channel is now a parameter on `from_json`, `try_from_json` and the
format-layer `emberjson._serde.from_json`, all defaulting to
`ParseOptions()`. The public `from_json` additionally honours
`options.validate_utf8` uniformly, whatever `T` is.

#### 7. `serialize` and `to_string` now raise

(These names were themselves renamed to `to_json` in breaking change 1
above; the raising behaviour described here carries over to `to_json`.)

Both are `raises SerializationError`. A `Serializable` implementation is
free to fail (`Lazy.serialize` surfaces a failing `get()` this way), so
the signature admits it. Callers in non-`raises` closures need updating.

Relatedly, `from_json` and friends raise typed errors —
`DeserializationError` (with `.message`, `.kind`, and `.path`, the wire
path to a nested failure) and `SerializationError` — rather than a bare
`Error`. Both are re-exported from `emberjson`. Code that catches
`except e:` and reads `String(e)` keeps working.

#### 8. `emberjson._serde`'s `from_json` / `to_json` are not public

*(Superseded by breaking change 1 above: `from_json` and `to_json` are now
the public top-level names too, dispatching to `Value`, `Document`, or
reflection depending on `T`. This item describes the private format-layer
functions the public ones are built on.)*

`emberjson._serde.from_json` / `.to_json` are the format layer, not the
public entry points. Unlike the public `from_json`, the format layer's
version does **not** validate UTF-8 on its own -- the public `from_json`
runs that check once, before dispatch, so every strategy (`Value`,
`Document`, reflection) sees it uniformly.

### Fixed during the migration

**`SIMD[DType.bool, N]` briefly stopped round-tripping as a JSON boolean.**
The deleted reflection walker had a non-numeric-dtype branch calling
`expect_bool`; emberserde's `SIMD` impl had no such branch and always went
through `expect_number`, so `true` was rejected and `1` silently accepted —
and on the serialize side a boolean-dtype scalar rendered as `True`, which is
not valid JSON.

Fixed upstream in emberserde by mirroring the deleted branch on both sides
(`emberserde/deserialize/impls.mojo`, `emberserde/serialize/impls.mojo`):

```mojo
comptime if Self.dtype == DType.bool:
    ...expect_bool() / serialize_bool()...
else:
    ...expect_number() / serialize_number()...
```

`SIMD[DType.bool, N]` now behaves as it did before the migration, and the
serialize side is corrected too — it previously emitted `True` rather than
`true`, which no format with a lowercase boolean literal could parse back.
Plain `Bool` was never affected.

Covered by `test_simd_bool_reads_a_json_boolean` and
`test_simd_bool_round_trips_through_json`
(`test/emberjson/reflection/test_reflection_deserialize.mojo`), plus
`test_simd_bool_reads_a_boolean` / `test_simd_bool_rejects_a_number` /
`test_simd_bool_writes_a_boolean` in emberserde's own suite.

### Performance

Measured against the committed `bench_result.txt` baseline; the project's
noise band is ±7%.

- **Reflection-based parsing is 10–30% slower.**
  `ParseCitmCatalogWithReflection` +20.2%, `ParseUserBatchWithReflection`
  +20.0%, `ParseCanadaWithReflection` +12.7%. Cause: emberserde's
  `StructDerState.expect_field_name` returns an `Optional[String]`, so a
  heap-allocated `String` is built for every field of every record. The
  deleted walker matched field names as raw byte spans and never
  allocated. Reflection still beats a full DOM parse, but by a narrower
  margin than before (CitmCatalog: 30.8% faster → 19.4% faster). The fix
  lives in emberserde.

- **`StringifyCitmCatalogWithReflection` is ~+143%.** The other stringify
  rows regressed too (up to +476%) and were brought back within noise by
  restoring write-buffering on the serialize path; this one fixture — ~427
  nested small structs — did not fully recover, and is attributed to
  per-field generic-dispatch overhead in emberserde's struct driver, the
  same pattern as the parse-side finding above.

- **Everything else is within noise**, including all `parse*` DOM/document
  rows, `minify`, `write_pretty`, UTF-8 validation, stage-1 indexing and
  `parse_pointer`.

### Added

- `deserialize` / `try_deserialize` (renamed `from_json` / `try_from_json`
  per breaking change 1 above) / `emberjson._serde.from_json` take
  `options: ParseOptions`.
- `Field[T, ...]` wire metadata on struct fields — `rename`,
  `extra_names`, `default`, `skip` — with `Defaulted`, `Rename` and `Skip`
  aliases. Re-exported from `emberjson`; read the payload with `[]`.
- `DeserializationError.path`, the wire path to a nested failure
  (e.g. `.middle.inner`).
- `Serializer.serialize_bytes` honours `pretty` like every other
  container.
