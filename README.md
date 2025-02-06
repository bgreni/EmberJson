# EmberJson

<!-- ![emberlogo](./image/ember_logo.jpeg) -->
<image src='./image/ember_logo.jpeg' width='300'/>

![license_badge](https://badgen.net/badge/License/MIT/blue)
![ci_badge](https://github.com/bgreni/EmberJson/actions/workflows/CI.yml/badge.svg)

A lightweight JSON parsing library for Mojo.

## Usage

### Parsing JSON

Use the `parse` function to parse a JSON value from a string. It accepts a
`ParseOptions` struct as a parameter to alter parsing behaviour.

```mojo

from emberjson import parse

struct ParseOptions:
    # Always use the fast past during float point value parsing.
    # Use this only if you are comfortable with potentially reduced accuracy.
    var fast_float_parsing: Bool

...

var json = parse[ParseOptions(fast_float_parsing=True)]('{"key": 123}')
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
from emberjson import to_string

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
