# Changelog

All notable changes to EmberJson are documented here.

## Unreleased — the emberserde migration

EmberJson no longer owns a serialization trait system. Reflection-based
`serialize`/`deserialize` now ride **emberserde**, a format-agnostic
serialization framework, with EmberJson supplying the JSON *format* for it
(`emberjson/_serde/`).

The parser, the SIMD structural index, the Teju Jagua float writer and the
UTF-8 validator are untouched — `parse`, `try_parse`, `parse_document`,
`parse_pointer`, `minify` and `is_valid_utf8` behave exactly as before.
Everything below is confined to the reflection/trait surface.

### Breaking changes

#### 1. Unknown wire fields are skipped, not rejected

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
_ = deserialize[Strict]('{"x": 1, "extra": 2}')
```

This is a **permissiveness** change on a security-relevant surface: a
caller who relied on EmberJson rejecting unexpected keys now gets no
error. Audit for that before upgrading.

#### 2. `Default` fills on an absent key only, never on an explicit `null`

`Default[T, d]` is now emberserde's `Field[T, default=d]`, and its
fallback fires when the key is **missing from the object**. An explicit
`null` is a *present* value and is parsed as `T` — which for a
non-`Optional` `T` is now an error where it previously produced the
default.

```mojo
from emberjson import deserialize, Defaulted


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
    print(deserialize[Rec]('{"a": 1}').b[])          # prints 42

    # Explicit null -> a PRESENT value, parsed as `Int`: now an error.
    try:
        _ = deserialize[Rec]('{"a": 1, "b": null}')
        print("accepted")
    except e:
        print("raises:", e.kind)

    # Escape hatch: an `Optional` payload resolves both absence and null.
    print(deserialize[OptRec]('{"a": 1, "b": null}').b[])  # prints None
    print(deserialize[OptRec]('{"a": 1}').b[])             # prints 42
```

This one is silent at the call site: nothing about the spelling changes,
only the behaviour on `null`.

#### 3. `JsonSerializable` / `JsonDeserializable` removed

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
from emberjson import deserialize, serialize
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
    print(serialize(Counter(7)))
    print(deserialize[Counter]("7").value)
```

Removed along with them: EmberJson's own `Serializer` and
`PrettySerializer` types, and the `write_json`/`from_json` methods on
`Value`, `Object`, `Array`, `Null` and `Lazy`. The `Serializer` /
`Deserializer` names now refer to emberserde's traits.

See the README's *Custom serialization and deserialization* section for a
complete working example.

#### 4. `serialize_as_array` / `deserialize_as_array` removed, with no counterpart

A struct could opt into riding the wire as a JSON array (`[1, 2]` instead
of `{"x":1,"y":2}`). emberserde has no equivalent: a struct is always an
object.

Workarounds: use a `Tuple` field (emberserde encodes tuples as arrays), or
hand-write a `Serializable`/`Deserializable` pair driving
`begin_seq`/`begin_tuple` directly.

#### 5. The `Parser`-taking `deserialize` / `try_deserialize` overloads are gone

```mojo
# before
var parser = Parser[options](doc)
var v = deserialize[T](parser^)

# now — `ParseOptions` is a parameter on the function itself
var v = deserialize[T, options](doc)
```

The overload existed mainly to let callers choose `ParseOptions`. That
channel is now a parameter on `deserialize`, `try_deserialize` and the
format-layer `emberjson._serde.from_json_string`, all defaulting to
`ParseOptions()`. `deserialize` additionally honours
`options.validate_utf8`, matching `parse`.

#### 6. `serialize` and `to_string` now raise

Both are `raises SerializationError`. A `Serializable` implementation is
free to fail (`Lazy.serialize` surfaces a failing `get()` this way), so
the signature admits it. Callers in non-`raises` closures need updating.

Relatedly, `parse`, `deserialize` and friends raise typed errors —
`DeserializationError` (with `.message`, `.kind`, and `.path`, the wire
path to a nested failure) and `SerializationError` — rather than a bare
`Error`. Both are re-exported from `emberjson`. Code that catches
`except e:` and reads `String(e)` keeps working.

#### 7. `from_json_string` / `to_json_string` are not public

They are the format layer (`emberjson._serde`) and, unlike `deserialize`,
`from_json_string` does **not** validate UTF-8. They are no longer
re-exported from `emberjson`; import them from `emberjson._serde`
explicitly if you want the unvalidated entry point.

### Known regression

**`SIMD[DType.bool, N]` no longer deserializes from a JSON boolean.** The
behaviour is cleanly inverted:

| input | before | now |
|---|---|---|
| `deserialize[SIMD[DType.bool, 1]]("true")` | `True` | raises |
| `deserialize[SIMD[DType.bool, 1]]("1")` | raises | `True` |
| `deserialize[SIMD[DType.bool, 2]]("[true,false]")` | `[True, False]` | raises |
| `deserialize[SIMD[DType.bool, 2]]("[1,0]")` | raises | `[True, False]` |

Plain `Bool` is unaffected — `deserialize[Bool]("true")` still works.

The deleted reflection walker had a non-numeric-dtype branch that called
`expect_bool`; emberserde's `SIMD` impl always calls `expect_number`. **The
fix belongs upstream**, at `emberserde/deserialize/impls.mojo:32` — one
`comptime if Self.dtype is DType.bool: return d.expect_bool()` mirrors the
deleted branch.

Pinned by `test_simd_bool_reads_a_number_not_a_json_boolean`
(`test/emberjson/reflection/test_reflection_deserialize.mojo:337`), which
fails loudly in either direction so the gap cannot close silently.

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

- `deserialize` / `try_deserialize` / `emberjson._serde.from_json_string`
  take `options: ParseOptions`.
- `Field[T, ...]` wire metadata on struct fields — `rename`,
  `extra_names`, `default`, `skip` — with `Defaulted`, `Rename` and `Skip`
  aliases. Re-exported from `emberjson`; read the payload with `[]`.
- `DeserializationError.path`, the wire path to a nested failure
  (e.g. `.middle.inner`).
- `Serializer.serialize_bytes` honours `pretty` like every other
  container.
