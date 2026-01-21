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

### Automatic Serilization

Through the power of Mojo's reflection capabilities, it is possible to automatically serialize structs to JSON strings. Users can optionally implement the `JsonSerializable` trait to customize the serialization process, and plain structs will be serialized as objects.

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