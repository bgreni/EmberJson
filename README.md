# EmberJson

A lightweight JSON parsing library for Mojo.

## Usage

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
