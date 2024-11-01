# EmberJson

![license_badge](https://badgen.net/badge/License/MIT/blue)
![ci_badge](https://github.com/bgreni/EmberJson/actions/workflows/CI.yml/badge.svg)

A lightweight JSON parsing library for Mojo.

## Usage

### Parsing from a string

```mojo
from ember_json import *

fn main() raises:
    # parse string
    var s = '{"key": 123}'
    var json = JSON.from_string(s)

    print(json.is_object()) # prints true

    # fetch inner value
    var ob = json.object()
    print(ob["key"].int()) # prints 123
    # implicitly access json object
    print(json["key"].int()) # prints 123

    # json array
    s = '[123, 456]'
    json = JSON.from_string(s)
    var arr = json.array()
    print(arr[0].int()) # prints 123
    # implicitly access array
    print(json[1].int()) # prints 456

    # `Value` type is formattable to allow for direct printing
    print(json[0]) # prints 123
```

### Stringify

```mojo
# convert to string
var json = JSON.from_string('{"key": 123}')
print(str(json)) # prints '{"key":123}'

# JSON is Writable so you can also just print it directly, or 
# even write you own stringify implementation!
print(json)

# pretty printing
from ember_json import write_pretty
print(write_pretty(json)) 
"""
{
    "key": 123
}
"""
```
