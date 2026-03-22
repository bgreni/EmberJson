# EmberJson

<!-- ![emberlogo](./image/ember_logo.jpeg) -->
<image src='./image/ember_logo.jpeg' width='300'/>

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
![ci_badge](https://github.com/bgreni/EmberJson/actions/workflows/CI.yml/badge.svg)
![CodeQL](https://github.com/bgreni/EmberJson/workflows/CodeQL/badge.svg)


A lightweight JSON parsing library for Mojo.

## Usage

### Parsing JSON

Use the `parse` function to parse a JSON value from a string. It accepts a
`ParseOptions` struct as a parameter to alter parsing behaviour.

```mojo
from emberjson import parse, ParseOptions

# Use custom options
var json = parse[ParseOptions(ignore_unicode=True)](r'["\uD83D\uDD25"]')
```

EmberJSON supports decoding escaped unicode characters.

```mojo
print(parse(r'["\uD83D\uDD25"]')) # prints '["🔥"]'
```

Use `try_parse` for a non-raising variant that returns an `Optional[Value]`:

```mojo
from emberjson import try_parse

var result = try_parse('{"key": 123}')
if result:
    print(result.value())  # prints {"key":123}
```

### Converting to String

Use the `to_string` function to convert a JSON struct to its string representation.
It accepts a parameter to control whether to pretty print the value.
The JSON struct also conforms to the `Writable` trait.

```mojo
from emberjson import parse, to_string

def main() raises:
    var json = parse('{"key": 123}')
    
    print(to_string(json)) # prints {"key":123}
    print(to_string[pretty=True](json))
# prints:
#{
#   "key": 123
#}
```

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

var json = parse('{"key": 123}')

# check inner type
print(json.is_object()) # prints True

# dict style access
print(json.object()["key"].int()) # prints 123

# array
var value = parse('[123, 4.5, "string", true, null]')
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

Using Mojo's reflection features, EmberJson can automatically serialize and deserialize JSON to and from Mojo structs without propagating trait implementations for all
relevant types. Plain structs are treated as JSON objects by default. The logic recursively traverses struct fields until it finds conforming types, so nested structs work out of the box.

Supported field types include: `Int`, `Float64`, `String`, `Bool`, `Optional[T]`, `List[T]`, `Dict[String, V]`, `Tuple[...]`, `Set[T]`, `InlineArray[T, N]`, `SIMD[dtype, size]`, `ArcPointer[T]`, `OwnedPointer[T]`, and nested structs.

To customize behavior, implement the `JsonSerializable` and/or `JsonDeserializable` traits.

#### Deserialization

The target struct must implement the `Movable` trait.
As well as the `Defaultable` trait if any of its fields
have non-trivial destructors.

```mojo
from emberjson import deserialize, try_deserialize

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

    # Raises on invalid JSON
    var user = deserialize[User](json_str)

    # Returns Optional[User] instead of raising
    var user_opt = try_deserialize[User](json_str)
    if user_opt:
        print(user_opt.value().name) # prints Mojo
```

Nested structs and `Optional` fields are handled automatically. Missing JSON keys for `Optional` fields default to `None`:

```mojo
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
    var person = deserialize[Person](json_str)
    print(person.name)              # prints Mojo
    print(person.address.city)      # prints SF
    print(person.address.zip)       # prints None (missing field)
```

#### Array-Based Deserialization

Implement `JsonDeserializable` to deserialize from a JSON array instead of an object:

```mojo
@fieldwise_init
struct Point(JsonDeserializable):
    var x: Int
    var y: Int

    @staticmethod
    def deserialize_as_array() -> Bool:
        return True

def main() raises:
    var p = deserialize[Point]("[1, 2]")
    print(p.x)  # prints 1
    print(p.y)  # prints 2
```

#### Serialization

```mojo
from emberjson import *

@fieldwise_init
struct Point:
    var x: Int
    var y: Int

def main():
    print(serialize(Point(1, 2)))                # prints {"x":1,"y":2}
    print(serialize[pretty=True](Point(1, 2)))   # pretty printed
```

#### Custom Serialization

Implement `JsonSerializable` to control how a struct is serialized:

```mojo
# Serialize as a JSON array instead of an object
@fieldwise_init
struct Coordinate(JsonSerializable):
    var lat: Float64
    var lng: Float64

    @staticmethod
    def serialize_as_array() -> Bool:
        return True

# Fully custom serialization via write_json
@fieldwise_init
struct MyInt(JsonSerializable):
    var value: Int

    def write_json(self, mut writer: Some[Serializer]):
        writer.write(self.value)

def main():
    print(serialize(Coordinate(1.0, 2.0)))  # prints [1.0,2.0]
    print(serialize(MyInt(1)))              # prints 1
```

### Schema Validation

EmberJson provides compile-time schema validation types that enforce constraints during both construction and deserialization. Validators wrap a value and raise on constraint violations. All validators integrate with `serialize`/`deserialize` and can be used as struct field types.

Access the validated value with `[]`:

```mojo
from emberjson import *

var port = Range[Int, 1, 65535](8080)
print(port[])  # prints 8080

var port2 = deserialize[Range[Int, 1, 65535]]("443")
print(port2[])  # prints 443
```

#### Validators

| Validator | Description | Example |
| ----------- | ------------- | ------- |
| `Range[T, min, max]` | Inclusive range (`min <= value <= max`) | `Range[Int, 0, 100]` |
| `ExclusiveRange[T, min, max]` | Exclusive range (`min < value < max`) | `ExclusiveRange[Float64, 0.0, 1.0]` |
| `Size[T, min, max]` | Length/size constraint | `Size[String, 1, 255]` |
| `NonEmpty[T]` | Non-empty check | `NonEmpty[List[Int]]` |
| `StartsWith[prefix]` | String prefix check | `StartsWith["https://"]` |
| `EndsWith[suffix]` | String suffix check | `EndsWith[".json"]` |
| `Eq[value]` | Equality check | `Eq[42]` |
| `Ne[value]` | Inequality check | `Ne["forbidden"]` |
| `MultipleOf[base]` | Divisibility check | `MultipleOf[Int64(10)]` |
| `Unique[T]` | All elements unique | `Unique[List[Int]]` |
| `Enum[T, *values]` | Set membership | `Enum[String, "red", "green", "blue"]` |

```mojo
from emberjson import *

# Validate on deserialization
var name = deserialize[NonEmpty[String]]('"Alice"')

# Validate on construction
var score = Range[Float64, 0.0, 100.0](95.5)

# Enum-style validation
comptime Color = Enum[String, "red", "green", "blue"]
var c = deserialize[Color]('"red"')
print(c[])  # prints red
```

#### Composing Validators

Combine validators for complex constraints:

```mojo
from emberjson import *

# AllOf: ALL validators must pass
var v = deserialize[
    AllOf[String, Size[String, 3, 7], StartsWith["a"]]
]('"astring"')

# OneOf: EXACTLY one validator must pass
var o = deserialize[
    OneOf[String, Eq["red"], Eq["green"], Eq["blue"]]
]('"red"')

# AnyOf: AT LEAST one validator must pass
var a = deserialize[
    AnyOf[Int, Eq[1], Eq[2], Range[Int, 10, 20]]
]("15")

# NoneOf: NO validators must pass
var n = deserialize[
    NoneOf[Int, Range[Int, 0, 5], Eq[100]]
]("7")

# Not: invert any validator
var x = deserialize[Not[Int, Range[Int, 0, 10]]]("15")
```

#### Data Transformers

Transformers modify values during deserialization or serialization:

```mojo
from emberjson import *

# Default: use a fallback value when the field is missing or null
var d = deserialize[Default[Int, 42]]("null")
print(d[])  # prints 42

# Secret: deserializes normally, serializes as "********"
var pw = deserialize[Secret[String]]('"my_password"')
print(pw[])           # prints my_password
print(serialize(pw))  # prints "********"

# Clamp: constrains value to a range instead of rejecting
var c = deserialize[Clamp[Int, 0, 100]]("150")
print(c[])  # prints 100 (clamped to max)

# CoerceInt/CoerceFloat/CoerceString: type coercion from JSON
var i = deserialize[CoerceInt]('"123"')
print(i[])  # prints 123 (coerced from string)

# Transform: apply a function during deserialization
def date_to_epoch(s: String) -> Int:
    if s == "2024-01-01":
        return 1704067200
    return 0

var epoch = deserialize[Transform[String, Int, date_to_epoch]]('"2024-01-01"')
print(epoch[])  # prints 1704067200
```

#### Using Validators in Structs

Validators work as struct field types, enforcing constraints during deserialization:

```mojo
from emberjson import *

@fieldwise_init
struct Config(Defaultable, Movable):
    var name: NonEmpty[String]
    var port: Range[Int, 1, 65535]
    var timeout: Default[Int, 30]
    var password: Secret[String]

    def __init__(out self):
        self.name = "default"
        self.port = 80
        self.timeout = Default[Int, 30]()
        self.password = ""

def main() raises:
    var cfg = deserialize[Config](
        '{"name": "myapp", "port": 8080, "password": "s3cret"}'
    )
    print(cfg.name[])      # prints myapp
    print(cfg.port[])      # prints 8080
    print(cfg.timeout[])   # prints 30 (default, since missing from JSON)
    print(serialize(cfg))  # password serialized as "********"
```

#### Cross-Field Validation

Validate relationships between fields of a struct:

```mojo
from emberjson import *
from emberjson.schema import CrossFieldValidator

@fieldwise_init
struct DateRange(Defaultable, Movable):
    var start: Int
    var end: Int

    def __init__(out self):
        self.start = 0
        self.end = 0

def validate_order(start: Int, end: Int) raises:
    if start >= end:
        raise Error("start must be before end")

def main() raises:
    var dr = deserialize[
        CrossFieldValidator[DateRange, "start", "end", validate_order]
    ]('{"start": 1, "end": 10}')
    print(dr[].start)  # prints 1
    print(dr[].end)    # prints 10
```

### JSON Pointer

EmberJSON supports [RFC 6901](https://tools.ietf.org/html/rfc6901) JSON Pointer for traversing documents with a string path.

The `get()` method works on `Value` types and returns a reference
to the nested value. It also supports syntactic sugar via backticks.

```mojo
var j = Value(parse_string='{"foo": ["bar", "baz"]}')

# Access nested values
print(j.get("/foo/1").string())  # prints "baz"

# Syntactic sugar via backticks
print(j.`/foo/1`.string())

# Modify values
j.get("/foo/1") = "modified"
# or
j.`/foo/1` = "modified"

# RFC 6901 Escaping (~1 for /, ~0 for ~) covers special characters
var j2 = Value(parse_string='{"a/b": 1, "m~n": 2}')
print(j2.get("/a~1b").int()) # prints 1
print(j2.get("/m~0n").int()) # prints 2
```

#### Syntactic Sugar

You can also use Python-style dot access for object keys, or backtick-identifiers for full paths:

```mojo
# Dot access for standard identifiers
print(j.foo)  # Equivalent to j.pointer("/foo")

# Backtick syntax for full pointer paths
print(j.`/foo/1`.string())  # Equivalent to j.pointer("/foo/1")

# In-place modification via backticks
j.`/foo/1` = "updated"
print(j.`/foo/1`.string())  # prints "updated"

# Chained access for nest objects
j = {"foo": {"bar": [1, 2, 3]}}
print(j.foo.bar[1])  # prints "2"
```

### JSON Patch

EmberJson supports [RFC 6902](https://tools.ietf.org/html/rfc6902) JSON Patch for applying a sequence of operations to a JSON document, and [RFC 7386](https://tools.ietf.org/html/rfc7386) JSON Merge Patch for recursive merging.

```mojo
from emberjson import parse, Value, Object
from emberjson.patch import patch, merge_patch

def main() raises:
    # RFC 6902: apply a sequence of operations
    var doc = parse('{"foo": "bar", "items": [1, 2]}')
    patch(doc, """[
        {"op": "replace", "path": "/foo", "value": "baz"},
        {"op": "add", "path": "/items/-", "value": 3},
        {"op": "remove", "path": "/items/0"}
    ]""")
    # doc is now {"foo": "baz", "items": [2, 3]}

    # Supported operations: add, remove, replace, move, copy, test
    # "test" asserts a value matches — raises if it doesn't
    patch(doc, '[{"op": "test", "path": "/foo", "value": "baz"}]')

    # RFC 7386: recursive merge patch
    var target = parse('{"a": "b", "c": {"d": "e", "f": "g"}}')
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
