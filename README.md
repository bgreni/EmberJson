# EmberJson

<!-- ![emberlogo](./image/ember_logo.jpeg) -->
<image src='./image/ember_logo.jpeg' width='300'/>

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
![ci_badge](https://github.com/bgreni/EmberJson/actions/workflows/CI.yml/badge.svg)


A lightweight JSON parsing library for Mojo.

## Usage

The entire JSON surface is four functions:

| | |
| --- | --- |
| `from_json[T](s)` | JSON text -> `T`. `T` may be `Value`, `Document`, or any reflected type. |
| `try_from_json[T](s)` | the same, returning `Optional[T]` instead of raising. |
| `to_json(v)` | any value -> JSON text. |
| `to_json_pretty(v)` | the same, indented. |

### Parsing JSON

Use `from_json[Value]` to parse a JSON value from a string. It accepts a
`ParseOptions` struct as a second parameter to alter parsing behaviour.

```mojo
from emberjson import from_json, Value, ParseOptions

# Use custom options
var json = from_json[Value, ParseOptions(ignore_unicode=True)](r'["\uD83D\uDD25"]')
```

EmberJSON supports decoding escaped unicode characters.

```mojo
from emberjson import from_json, Value

print(from_json[Value](r'["\uD83D\uDD25"]')) # prints '["🔥"]'
```

Use `try_from_json` for a non-raising variant that returns an `Optional[Value]`:

```mojo
from emberjson import try_from_json, Value

var result = try_from_json[Value]('{"key": 123}')
if result:
    print(result.value())  # prints {"key":123}
```

### Fast immutable documents

`from_json[Document]` parses onto an immutable, self-contained tape
`Document` (simdjson-style).

```mojo
from emberjson import from_json, to_json, Document

def main() raises:
    var d = from_json[Document]('{"name": "ember", "versions": [1, 2.5]}')

    print(d.root()["name"].string())        # ember
    print(d.root()["versions"][1].float())  # 2.5
    print(len(d.root()["versions"]))        # 2

    for entry in d.root().object():         # zero-copy keys and values
        print(entry.key)

    print(to_json(d))                       # serialize straight off the tape

    # Materialize an owned, mutable Value tree when you need to modify
    # the data or keep it beyond the Document's lifetime:
    var v = d.to_value()
    v["name"] = "modified"
```

`try_from_json[Document]` is the non-raising variant returning an
`Optional[Document]`.

### Partial access with JSON Pointer

When you need one value out of a large document, `parse_pointer` navigates
the raw text to an RFC 6901 target using a SIMD structural index and
parses only that subtree — sibling values are skipped with bracket hops,
never visiting their contents. Sparse queries run 2-5x faster than even
`from_json[Document]` on the bench corpus (4.5-16x faster than
`from_json[Value]`).

```mojo
from emberjson import parse_pointer

var name = parse_pointer(big_doc, "/statuses/99/user/screen_name")
print(name.string())
```

The trade-off: the target (and everything actually traversed) is fully
validated, but skipped bytes are only checked for string boundaries; an
unterminated enclosing container or trailing content is not detected
(`parse_pointer('{"a":1', "/a")` returns `1`), and duplicate keys on the
traversed path resolve to the first match.
`parse_pointer('{"bad": nope, "good": 1}', "/good")` succeeds. Use
`from_json[Value]` when whole-document validation matters.
`try_parse_pointer` is the non-raising variant.

### UTF-8 validation

JSON text is required to be UTF-8 (RFC 8259), and every `from_json` entry
point validates that by default -- uniformly, whether `T` is `Value`,
`Document`, or a reflected struct: input containing overlongs, surrogates,
truncated sequences, or code points above U+10FFFF is rejected before
parsing. The check is a SIMD validator running at ~19-30 GB/s (with an
ASCII fast path), so it typically costs 2-4% of a parse. For trusted
input you can opt out:

```mojo
from emberjson import from_json, Value, is_valid_utf8, ParseOptions

var v = from_json[Value](untrusted_bytes)  # raises on invalid UTF-8

comptime trusted = ParseOptions(validate_utf8=False)
var w = from_json[Value, trusted](my_own_bytes)  # skips the check

# Also available standalone:
if is_valid_utf8(some_bytes):
    ...
```

### Converting to String

Use `to_json` to convert a JSON struct to its string representation. It
accepts a parameter to control whether to pretty print the value, or use
`to_json_pretty` directly. The JSON struct also conforms to the
`Writable` trait.

```mojo
from emberjson import from_json, to_json, to_json_pretty, Value

def main() raises:
    var json = from_json[Value]('{"key": 123}')

    print(to_json(json)) # prints {"key":123}
    print(to_json_pretty(json))
# prints:
#{
#    "key": 123
#}
```

> `to_json[pretty=True]` on a `Document` is a **compile-time error** --
> `Document` writes straight off its tape and has no indented writer.
> Deserialize into a `Value` first if you need indented output from
> tape input.

Use `minify` to strip whitespace from a JSON string without parsing:

```mojo
from emberjson import minify

var compact = minify('{ "key" :  123 }')
print(compact)  # prints {"key":123}
```

### Working with JSON

`Value` is the unified type for any JSON value. It can represent
an `Object`, `Array`, `String`, `Int`, `Float64`, `Bool`, or `Null`.

```mojo
from emberjson import *
from std.testing import assert_equal

var json = from_json[Value]('{"key": 123}')

# check inner type
print(json.is_object()) # prints True

# dict style access
print(json.object()["key"].int()) # prints 123

# array
var value = from_json[Value]('[123, 4.5, "string", true, null]')
ref array = value.array()

# array style access
print(array[3].bool()) # prints True

# equality checks
print(array[4] == Null()) # prints True

# None converts implicitly to Null
assert_equal(array[4], Value(None))

# Implicit ctors for Value
var v: Value = "some string"

# Convert Array and Dict back to stdlib types
# These are consuming actions so the original Array/Object will be moved
var arr = Array(123, False)
var l = arr.to_list()

var ob = Object()
var d = ob.to_dict()
```

### Reflection

Using Mojo's reflection features, EmberJson can automatically serialize and
deserialize JSON to and from Mojo structs without propagating trait
implementations for all relevant types. Plain structs are treated as JSON
objects; the logic recursively traverses struct fields until it finds
conforming types, so nested structs work out of the box.

The framework doing that traversal is **emberserde**, a format-agnostic
serialization library. EmberJson supplies the JSON *format* for it, which
means two things: the traits you implement to customize behaviour are
emberserde's `Serializable` and `Deserializable`, and any type emberserde
already knows how to encode works here for free.

Supported field types include `Int`, `Float64`, `String`, `Bool`,
`Optional[T]`, `List[T]`, `Dict[String, V]`, `Tuple[...]`, `Set[T]`,
`Array[T, N]`, `SIMD[dtype, length]`, `ArcPointer[T]`, `OwnedPointer[T]`,
EmberJson's own `Value`/`Object`/`Array`/`Null`, and nested structs.
emberserde ships impls for more besides (`Deque`, `LinkedList`, `Counter`,
`Variant`, `Codepoint`, …), and all of them are reachable from here.

> **Coming from EmberJson 0.3.x?** `JsonSerializable`, `JsonDeserializable`,
> `write_json`, `Serializer` (EmberJson's own), `serialize_as_array` and
> `deserialize_as_array` no longer exist, and unknown-field and `Default`
> handling changed. [CHANGELOG.md](CHANGELOG.md) lists every break and its
> replacement.

#### Deserialization

The target struct must implement `Movable`, and `Defaultable` as well if any
of its fields have non-trivial destructors (`String`, `List`, a nested
struct holding either, …).

```mojo
from emberjson import from_json, try_from_json


@fieldwise_init
struct User(Defaultable, Movable):
    var id: Int
    var name: String
    var is_active: Bool
    var scores: List[Float64]

    def __init__(out self):
        self.id = 0
        self.name = ""
        self.is_active = False
        self.scores = List[Float64]()


def main() raises:
    var json_str = '{"id": 1, "name": "Mojo", "is_active": true, "scores": [9.9, 8.5]}'

    # Raises `DeserializationError` on invalid JSON
    var user = from_json[User](json_str)
    print(user.name)  # prints Mojo

    # Returns `Optional[User]` instead of raising
    var user_opt = try_from_json[User](json_str)
    if user_opt:
        print(user_opt.value().name)  # prints Mojo
```

`from_json` and `try_from_json` take the same `ParseOptions` as any other call:

```mojo
from emberjson import from_json, try_from_json, ParseOptions

@fieldwise_init
struct Doc(Defaultable, Movable):
    var text: String

    def __init__(out self):
        self.text = ""


def main() raises:
    comptime fast = ParseOptions(ignore_unicode=True, validate_utf8=False)
    var d = from_json[Doc, fast]('{"text": "\\u0041"}')
    print(d.text)  # prints \u0041 -- the escape is left undecoded

    var maybe = try_from_json[Doc, fast]('{"text": "hi"}')
    print(maybe.value().text)  # prints hi
```

Nested structs and `Optional` fields are handled automatically. A missing
JSON key for an `Optional` field reads as `None`:

```mojo
from emberjson import from_json


@fieldwise_init
struct Address(Defaultable, Movable):
    var city: String
    var zip: Optional[String]

    def __init__(out self):
        self.city = ""
        self.zip = None


@fieldwise_init
struct Person(Defaultable, Movable):
    var name: String
    var address: Address

    def __init__(out self):
        self.name = ""
        self.address = Address()


def main() raises:
    var json_str = '{"name": "Mojo", "address": {"city": "SF"}}'
    var person = from_json[Person](json_str)
    print(person.name)              # prints Mojo
    print(person.address.city)      # prints SF
    print(person.address.zip)       # prints None (missing field)
```

#### Unknown fields

A wire field matching no declared struct field is **skipped** by default. It
is still fully validated on the way past — skipping is a real parse, not a
blind hop — but it no longer fails the deserialization. Annotate the struct
with `DenyUnknownFields()` to reject it instead:

```mojo
from emberjson import from_json
from emberserde import DenyUnknownFields


@fieldwise_init
struct Loose(Defaultable, Movable):
    var x: Int

    def __init__(out self):
        self.x = 0


@__annotation(DenyUnknownFields())
@fieldwise_init
struct Strict(Defaultable, Movable):
    var x: Int

    def __init__(out self):
        self.x = 0


def main() raises:
    # Unknown wire fields are SKIPPED by default (they are still fully
    # validated on the way past, not blindly hopped over).
    print(from_json[Loose]('{"x": 1, "extra": [1, 2]}').x)  # prints 1

    # Opt back in to rejecting them per type.
    try:
        _ = from_json[Strict]('{"x": 1, "extra": 2}')
    except e:
        print(e.kind)  # prints UnknownField
```

#### Serialization

```mojo
from emberjson import to_json


@fieldwise_init
struct Point:
    var x: Int
    var y: Int


def main() raises:
    print(to_json(Point(1, 2)))               # prints {"x":1,"y":2}
    print(to_json[pretty=True](Point(1, 2)))  # pretty printed
```

#### Typed errors

The public entry points raise typed errors rather than a bare `Error`.
`DeserializationError` carries `.message`, `.kind` (a `DerErrorKind`) and
`.path`, the wire path to a nested failure; `SerializationError` carries
`.message` and `.kind`. Both are re-exported from `emberjson`.

```mojo
from emberjson import from_json, DeserializationError, DerErrorKind


@fieldwise_init
struct Inner(Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


@fieldwise_init
struct Outer(Defaultable, Movable):
    var label: String
    var inner: Inner

    def __init__(out self):
        self.label = ""
        self.inner = Inner()


def main() raises:
    try:
        _ = from_json[Outer]('{"label": "a", "inner": {"x": 1}}')
    except e:
        print(e.message)  # missing field: y
        print(e.kind)     # MissingField
        print(e.path)     # .inner
```

`try_from_json` and `try_parse_pointer` swallow these and hand back an
`Optional` instead.

#### Custom serialization and deserialization

Implement emberserde's `Serializable` and/or `Deserializable` to take over
how a type rides the wire. `serialize` receives the active `Serializer`;
`deserialize` is a `@staticmethod` receiving the active `Deserializer`.
These are the trait methods -- unrelated to the top-level `to_json`/
`from_json` functions, which call them under the hood.

```mojo
from emberjson import from_json, to_json
from emberserde import (
    DerErrorKind,
    Deserializable,
    DeserializationError,
    Deserializer,
    Serializable,
    SerializationError,
    Serializer,
)


@fieldwise_init
struct Celsius(Deserializable, Serializable):
    var degrees: Float64

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        # Ride the wire as "21.5C" instead of a bare number.
        s.serialize_string(String(self.degrees) + "C")

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var raw = d.expect_string()
        try:
            return Self(atof(raw.removesuffix("C")))
        except:
            # `atof` raises an untyped `Error`; the trait's contract is a
            # typed `DeserializationError`, so convert at the boundary.
            raise DeserializationError(
                String("not a temperature: ") + raw,
                DerErrorKind.InvalidValue,
            )


def main() raises:
    print(to_json(Celsius(21.5)))                 # prints "21.5C"
    print(from_json[Celsius]('"21.5C"').degrees)  # prints 21.5
```

Those surfaces are format-agnostic — `serialize_bool`, `serialize_number`,
`serialize_string`, `serialize_none`, `begin_seq`/`begin_map`/`begin_struct`
/`begin_tuple` on the way out, and `expect_bool`, `expect_number`,
`expect_string`, `expect_optional` and the matching `begin_*` on the way in
— so an implementation written against them works for any emberserde
format, not only JSON.

> A struct always rides the wire as a JSON **object**. The old
> `serialize_as_array`/`deserialize_as_array` opt-in was removed with
> EmberJson's own trait system and emberserde has no counterpart. Use a
> `Tuple` field, or a hand-written `Serializable`/`Deserializable` pair
> driving `begin_seq`, when you need array-shaped output.

#### Wire-level field control

emberserde's field annotations attach wire metadata to a single field with
`@__annotation(...)`: a different wire name (`Rename`), an extra accepted name
(`Alias`, repeat for more), a fallback for an absent key (`Default`), exclusion
from the wire entirely (`Skip`), or a `def(T) -> Bool` check run after the read
(`Validate`, failure raises `InvalidValue`). The field keeps its own type, so
there is nothing to unwrap.

```mojo
from emberjson import from_json, to_json, Default, Rename, Skip


# `Defaultable` because the fields have non-trivial destructors: the
# framework only claims an unwritten struct in place when every field is
# trivially destructible, otherwise it wants a real default to fill in.
@fieldwise_init
struct Config(Defaultable, Movable):
    @__annotation(Rename("hostname"))
    var host: String

    @__annotation(Default(8080))
    var port: Int

    @__annotation(Skip())
    var cache: String

    def __init__(out self):
        self.host = {}
        self.port = 0
        self.cache = {}


def main() raises:
    var c = from_json[Config]('{"hostname": "localhost"}')
    print(c.host)            # prints localhost
    print(c.port)            # prints 8080 -- the key was absent
    print(to_json(c))        # prints {"hostname":"localhost","port":8080}
```

> `Default` fires on an **absent key** only. An explicit `null` is a present
> value and is parsed as `T`. Make the field `Optional` —
> `@__annotation(Default(Optional[Int](42))) var n: Optional[Int]` — when
> `null` should be tolerated too. The default's type must match the field's
> exactly (`Default(Int64(3))` on an `Int64`).

### Mixing eager and lazy fields

Any deserialized struct can defer expensive subtrees by declaring fields
as `Lazy` wrappers (`LazyValue`, `LazyString`, `LazyInt`, `LazyFloat`,
or `Lazy[YourType, origin]`): during `from_json` those fields only
record their byte span (grammar-validated, so re-serialization is safe),
and materialize when you call `.get()`. The struct is parameterized on
the input's origin, which lets the compiler guarantee the spans cannot
outlive the source string.

```mojo
from emberjson import from_json, LazyValue, LazyString

struct Event[origin: ImmOrigin](Movable):
    var id: Int64                      # parsed eagerly
    var payload: LazyValue[Self.origin]  # span captured, parsed on demand
    var note: LazyString[Self.origin]

var e = from_json[Event[origin_of(data)]](data)
print(e.id)                  # already materialized
print(e.payload.get())       # parses just this subtree, now
```

### Schema Validation

Field validation comes from emberserde's annotations, re-exported by
`emberjson`. Checks run on struct fields during `from_json`. A failure raises
`DeserializationError` with kind `InvalidValue`, the check's message, and the
field's path. Fields keep their own types.

```mojo
from emberjson import *


# A check on the struct itself relates fields; it runs once every field is
# read.
@__annotation(
    Validate(
        lambda (c: Cfg) -> Bool: c.env != "prod" or c.level != 0,
        "prod needs a level",
    )
)
@fieldwise_init
struct Cfg(Defaultable, Movable):
    @__annotation(Range(1, 65535, msg="bad port"))
    var port: Int

    @__annotation(NonEmpty(), Size(1, 64))
    var host: String

    @__annotation(Enum["dev", "prod"]())
    var env: String

    @__annotation(AnyOf(Eq(0), Range(10, 20)))
    var level: Int

    def __init__(out self):
        self.port = 0
        self.host = String()
        self.env = String()
        self.level = 0


def main() raises:
    var cfg = from_json[Cfg]('{"port": 8080, "host": "localhost", "env": "prod", "level": 15}')
    print(cfg.port)  # prints 8080
    try:
        _ = from_json[Cfg]('{"port": 0, "host": "h", "env": "dev", "level": 0}')
    except e:
        print(e)  # prints at .port: bad port (InvalidValue)
```

| Check | Passes when | Default message |
| --- | --- | --- |
| `Validate(f)` | `f(value)` is `True` | Validation failed |
| `Range(min, max)` | `min <= value <= max` | Value out of range |
| `Eq(value)` | equal to `value` | Value is not equal |
| `Enum[a, b, ...]()` | equal to one of the listed values | Value not in options |
| `Size(min, max)` | length within bounds (`String` counts bytes) | Value out of size range |
| `NonEmpty()` | length above zero | Value must not be empty |
| `Unique()` | no two elements equal | Values are not unique |
| `Not(check)` | `check` fails | Expected validator to fail |
| `AnyOf(c1, c2, ...)` | at least one check passes | Value not in options |
| `OneOf(c1, c2, ...)` | exactly one check passes | Value must match exactly one option |
| `NoneOf(c1, c2, ...)` | no check passes | Value matched a rejected validator |

Every check takes an optional trailing `msg`, as in
`Range(1, 65535, msg="bad port")` or `Validate(f, "must be even")`. Several
checks on one field must all pass, and run in order. A check carrying a value
(`Validate`, `Range`, `Eq`, `Enum`) must match the field's type exactly:
`Range(Int64(0), Int64(10))` on an `Int64`. A value filled in by `Default` for
a missing key is not checked. `Unique` compares every pair, so it is O(n²);
on untrusted input bound the length first, as in
`@__annotation(Size(0, 1000), Unique())` (checks run in order). To write your
own check, conform to `FieldCheck` (see emberserde's README).

> Checks only run on struct fields while deserializing. Top-level values,
> collection elements and values you build yourself are not checked. A check
> on an `Optional` field fails to compile; write a `Validate` over the
> `Optional` instead.

#### Data Transformers

`Transform(f)` reads the wire value as `f`'s argument type and stores
`f(value)` in the field. It runs on read only: the field is written back as
its own type. `coerce_int`, `coerce_uint`, `coerce_float` and `coerce_string`
pair with it to accept a number, a numeric string and so on; they take a
`Value`, so your own `def(Value) raises -> T` works the same way.
`Transform(clamp[lo, hi])` pulls an out-of-range value into range instead of
rejecting it. `SerializeWith(f)` is the write-side twin: the field is read as
sent and written as `f(value)`, which is how to redact a secret.

```mojo
from emberjson import *


def date_to_epoch(s: String) -> Int:
    if s == "2024-01-01":
        return 1704067200
    return 0


def redact(s: String) -> String:
    return "********"


@fieldwise_init
struct Event(Defaultable, Movable):
    @__annotation(Transform(date_to_epoch))
    var epoch: Int

    @__annotation(Transform(coerce_int))  # 5, 5.0 and "5" all bind 5
    var retries: Int64

    @__annotation(SerializeWith(redact))  # read as sent, written as "********"
    var password: String

    @__annotation(Transform(clamp[0, 100]))  # clamped instead of rejected
    var volume: Int

    def __init__(out self):
        self.epoch = 0
        self.retries = 0
        self.password = String()
        self.volume = 0


def main() raises:
    var e = from_json[Event]('{"epoch": "2024-01-01", "retries": "3", "password": "hunter2", "volume": 150}')
    print(e.epoch)       # prints 1704067200
    print(e.retries)     # prints 3
    print(e.password)    # prints hunter2
    print(e.volume)      # prints 100
    print(to_json(e))
    # prints {"epoch":1704067200,"retries":3,"password":"********","volume":100}
```

> **Coming from the wrapper validators?** `Range[Int, 0, 10]` fields become
> `@__annotation(Range(0, 10))` on a plain `Int`, and `field[]` becomes
> `field`. `AllOf` becomes several annotations on one field; `Ne(x)` becomes
> `Not(Eq(x))`; `ExclusiveRange`, `StartsWith`, `EndsWith` and `MultipleOf`
> become `Validate(f, msg)`; `CoerceInt` becomes `Transform(coerce_int)`;
> `Clamp[T, lo, hi]` becomes `Transform(clamp[lo, hi])`; `Secret[T]` becomes
> `SerializeWith(f)` with a redacting `f`; `CrossFieldValidator` becomes a
> `Validate` annotation on the struct itself.

### JSON Pointer

EmberJSON supports [RFC 6901](https://tools.ietf.org/html/rfc6901) JSON Pointer for traversing documents with a string path.

The `get()` method works on `Value` types and returns a reference
to the nested value. It also supports syntactic sugar via backticks.

```mojo
from emberjson import from_json, Value

var j = from_json[Value]('{"foo": ["bar", "baz"]}')

# Access nested values
print(j.get("/foo/1").string())  # prints baz

# Syntactic sugar via backticks
print(j.`/foo/1`.string())

# Modify values
j.get("/foo/1") = "modified"
# or
j.`/foo/1` = "modified"

# RFC 6901 Escaping (~1 for /, ~0 for ~) covers special characters
var j2 = from_json[Value]('{"a/b": 1, "m~n": 2}')
print(j2.get("/a~1b").int()) # prints 1
print(j2.get("/m~0n").int()) # prints 2
```

#### Syntactic Sugar

You can also use Python-style dot access for object keys, or backtick-identifiers for full paths:

```mojo
# Dot access for standard identifiers
print(j.foo)  # Equivalent to j.get("/foo")

# Backtick syntax for full pointer paths
print(j.`/foo/1`.string())  # Equivalent to j.get("/foo/1")

# In-place modification via backticks
j.`/foo/1` = "updated"
print(j.`/foo/1`.string())  # prints "updated"

# Chained access for nest objects
j = {"foo": {"bar": [1, 2, 3]}}
print(j.foo.bar[1])  # prints 2
```

### JSON Patch

EmberJson supports [RFC 6902](https://tools.ietf.org/html/rfc6902) JSON Patch for applying a sequence of operations to a JSON document, and [RFC 7396](https://tools.ietf.org/html/rfc7396) JSON Merge Patch for recursive merging.

```mojo
from emberjson import from_json, Value, Object
from emberjson.patch import patch, merge_patch

def main() raises:
    # RFC 6902: apply a sequence of operations
    var doc = from_json[Value]('{"foo": "bar", "items": [1, 2]}')
    patch(doc, """[
        {"op": "replace", "path": "/foo", "value": "baz"},
        {"op": "add", "path": "/items/-", "value": 3},
        {"op": "remove", "path": "/items/0"}
    ]""")
    # doc is now {"foo": "baz", "items": [2, 3]}

    # Supported operations: add, remove, replace, move, copy, test
    # "test" asserts a value matches — raises if it doesn't
    patch(doc, '[{"op": "test", "path": "/foo", "value": "baz"}]')

    # RFC 7396: recursive merge patch
    var target = from_json[Value]('{"a": "b", "c": {"d": "e", "f": "g"}}')
    merge_patch(target, '{"a": "z", "c": {"f": null}}')
    # target is now {"a": "z", "c": {"d": "e"}}
    # null values remove keys
```

### JSON Lines

Read and write [JSON Lines](https://jsonlines.org/) files (one JSON value per line):

```mojo
from emberjson import read_lines, write_lines, Value, Array
from std.pathlib import Path

def main() raises:
    # Read: iterate over lines lazily
    for value in read_lines("data.jsonl"):
        print(value)

    # Read: collect all lines into a list
    var all_values = read_lines("data.jsonl").collect()

    # Write: save a list of values as JSONL
    var lines: List[Value] = [Value(1), Value(2), Value(3)]
    write_lines(Path("output.jsonl"), lines)
```

## Acknowledgments

EmberJson uses the [Teju Jagua](https://github.com/cassioneri/teju_jagua) algorithm for efficient floating-point formatting, developed by Cassio Neri and licensed under the Apache License, Version 2.0.
