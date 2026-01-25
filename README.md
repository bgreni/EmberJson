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

from emberjson import parse

struct ParseOptions:
    # ignore unicode for a small performance boost
    var ignore_unicode: Bool

...

var json = parse[ParseOptions(ignore_unicode=True)](r'["\uD83D\uDD25"]')
```

EmberJSON supports decoding escaped unicode characters.

```mojo
print(parse(r'["\uD83D\uDD25"]')) # prints '["🔥"]'
```

### Converting to String

Use the `to_string` function to convert a JSON struct to its string representation.
It accepts a parameter to control whether to pretty print the value.
The JSON struct also conforms to the `Stringable`, `Representable` and `Writable`
traits.

```mojo
from emberjson import parse, to_string

fn main() raises:
    var json = parse('{"key": 123}')
    
    print(to_string(json)) # prints {"key":123}
    print(to_string[pretty=True](json))
# prints:
#{
#   "key": 123
#}
```

### Working with JSON

`JSON` is the top level type for a document. It can contain either
an `Object` or `Array`.

`Value` is used to wrap the various possible primitives that an object or
array can contain, which are `Int`, `Float64`, `String`, `Bool`, `Object`,
`Array`, and `Null`.

```mojo
from emberjson import *

var json = parse('{"key": 123}')

# check inner type
print(json.is_object()) # prints True

# dict style access
print(json.object()["key"].int()) # prints 123

# array
var array = parse('[123, 4.5, "string", True, null]').array()

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

Using Mojo's reflection features, it is now possible to automatically serialize and deserialize JSON to and from Mojo structs without the need for propagating trait implementations for all
relevant types. As is the case with other frameworks like `serde`. Plain structs are treated as objects by default. Each trait is implemented on many of the basic stdlib types to support this
pattern as when a non-conforming type is passed to `serialize/deserialize`, the logic will recursively traverse it's fields until it finds conforming types.

If you desire to customize the behavior, you can implement the `JsonSerializable` and `JsonDeserializable` traits for a particular struct.

#### Deserialization

The target struct must implement the `Defaultable` and `Movable` traits.

```mojo
from emberjson import deserialize, try_deserialize

@fieldwise_init
struct User(Movable, Defaultable):
    var id: Int
    var name: String
    var is_active: Bool
    var scores: List[Float64]

fn main() raises:
    var json_str = '{"id": 1, "name": "Mojo", "is_active": true, "scores": [9.9, 8.5]}'

    var user_opt = try_deserialize[User](json_str)
    if user_opt:
        print(user_opt.value().name) # prints Mojo

    var user = deserialize[User](json_str)
```

#### Serialization

```mojo
from emberjson import *

@fieldwise_init
struct Point:
    var x: Int
    var y: Int


@fieldwise_init
struct Coordinate(JsonSerializable):
    var lat: Float64
    var lng: Float64

    @staticmethod
    fn serialize_as_array() -> Bool:
        return True


@fieldwise_init
struct MyInt(JsonSerializable):
    var value: Int

    fn write_json(self, mut writer: Some[Writer]):
        writer.write(self.value)


fn main():
    print(serialize(Point(1, 2)))  # prints {"x":1,"y":2}
    print(serialize(Coordinate(1.0, 2.0)))  # prints [1.0,2.0]
    print(serialize(MyInt(1)))  # prints 1
```