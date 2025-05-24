import max._mojo.mojo_importer
import os
import sys

sys.path.insert(0, "")
os.environ["MOJO_PYTHON_LIBRARY"] = ""

from emberjson_python import parse

s = r"""{
    "key": [
        1.234,
        352.329384920,
        123412512,
        -12234,
        true,
        false,
        null,
        "shortstr",
        "longer string that would trigger simd code usually but can't be invoked at ctime",
        "string that has unicode in it: \u00FC"
    ]
}"""

res = parse(s)

print("Result:", res)