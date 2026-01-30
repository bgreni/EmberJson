from .value import Value
from .utils import write
from std.collections import List
from std.utils import Variant
from .object import Object
from .array import Array
from memory import UnsafePointer
from sys.intrinsics import unlikely


fn parse_int(s: String) raises -> Int:
    # Simple integer parser
    var res = 0
    if s == "":
        raise Error("Empty string is not an integer")
    var bytes = s.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b < 48 or b > 57:
            raise Error("Invalid integer: " + s)
        res = res * 10 + Int(b - 48)
    return res


fn unescape(token: StringSlice) -> String:
    # RFC 6901 Escaping:
    # ~1 -> /
    # ~0 -> ~
    if "~" not in token:
        return String(token)

    var out = String()
    var i = 0
    var bytes = token.as_bytes()
    while i < len(bytes):
        if bytes[i] == 126:  # ~
            if i + 1 < len(bytes):
                var next = bytes[i + 1]
                if next == 49:  # 1
                    out.write("/")
                    i += 2
                    continue
                elif next == 48:  # 0
                    out.write("~")
                    i += 2
                    continue
            out.write("~")
            i += 1
        else:
            out.write(Codepoint(bytes[i]))
            i += 1
    return out


comptime PointerToken = Variant[String, Int]


struct PointerIndex(Copyable, Movable):
    var tokens: List[PointerToken]

    @implicit
    fn __init__(out self, path: String) raises:
        self.tokens = List[PointerToken]()
        if path == "":
            return

        if not path.startswith("/"):
            raise Error("JSON Pointer must start with /")

        var raw_tokens = path.split("/")
        # Skip first empty element (before first /)
        for i in range(1, len(raw_tokens)):
            var raw = unescape(raw_tokens[i])

            # Try parse int
            try:
                var idx = parse_int(raw)
                # Validation rules RFC 6901
                if unlikely(idx < 0):
                    # Negative shouldn't happen from parse_int unless overflow logic wrapped?
                    # parse_int logic I wrote doesn't handle - sign, so it's always positive.
                    pass

                # Leading zero check
                if raw != "0" and raw.startswith("0"):
                    # Treat as String key, because it's invalid as Array index but valid Object key
                    self.tokens.append(PointerToken(raw))
                else:
                    self.tokens.append(PointerToken(idx))
            except:
                # Not a valid int, treat as String
                self.tokens.append(PointerToken(raw))

    @staticmethod
    fn try_from_string(path: String) -> Optional[Self]:
        try:
            return PointerIndex(path)
        except:
            return None


fn resolve_pointer(
    ref root: Value, ptr: PointerIndex
) raises -> ref [root] Value:
    if len(ptr.tokens) == 0:
        return root
    return _resolve_ref(root, ptr.tokens, 0)


fn resolve_pointer(
    ref root: Object, ptr: PointerIndex
) raises -> ref [root] Value:
    if unlikely(len(ptr.tokens) == 0):
        # Cannot return reference to Object as Value, because Object is not Value.
        raise Error("Cannot return reference to root Object as Value")
    return _resolve_ref(root, ptr.tokens, 0)


fn resolve_pointer(
    ref root: Array, ptr: PointerIndex
) raises -> ref [root] Value:
    if unlikely(len(ptr.tokens) == 0):
        # Cannot return reference to Array as Value.
        raise Error("Cannot return reference to root Array as Value")
    return _resolve_ref(root, ptr.tokens, 0)


fn _resolve_ref(
    ref val: Value, tokens: List[PointerToken], idx: Int
) raises -> ref [val] Value:
    if idx >= len(tokens):
        return val

    if val.is_object():
        var ptr = UnsafePointer[Object](to=val.object()).unsafe_origin_cast[
            origin_of(val)
        ]()
        return _resolve_ref(ptr[], tokens, idx)
    elif val.is_array():
        var ptr = UnsafePointer[Array](to=val.array()).unsafe_origin_cast[
            origin_of(val)
        ]()
        return _resolve_ref(ptr[], tokens, idx)
    else:
        var token = tokens[idx]
        if token.isa[String]():
            raise Error(
                "Primitive value cannot be traversed with key: " + token[String]
            )
        else:
            raise Error(
                "Primitive value cannot be traversed with index: "
                + String(token[Int])
            )


fn _resolve_ref(
    ref obj: Object, tokens: List[PointerToken], idx: Int
) raises -> ref [obj] Value:
    if unlikely(idx >= len(tokens)):
        # Unreachable from resolve_pointer(Object) because of empty check,
        # but prevents returning a non-existent Value ref.
        raise Error("Cannot resolve reference to Object root")

    var token = tokens[idx]
    var key: String

    if token.isa[String]():
        key = token[String]
    elif token.isa[Int]():
        key = String(token[Int])
    else:
        raise Error("Unknown token type")

    if key in obj:
        # obj[key] returns ref [obj._data] Value
        # We need ref [obj] Value.
        # Since obj owns _data, the lifetime of _data is at least as long as obj.
        var ptr = UnsafePointer(to=obj[key]).unsafe_origin_cast[
            origin_of(obj)
        ]()
        return _resolve_ref(ptr[], tokens, idx + 1)

    raise Error("Key not found: " + key)


fn _resolve_ref(
    ref arr: Array, tokens: List[PointerToken], idx: Int
) raises -> ref [arr] Value:
    if unlikely(idx >= len(tokens)):
        raise Error("Cannot resolve reference to Array root")

    var token = tokens[idx]
    var i: Int
    if token.isa[Int]():
        i = token[Int]
    else:
        raise Error("Invalid array index: " + token[String])

    var arr_len = len(arr)
    if unlikely(i >= arr_len):
        raise Error("Index out of bounds")

    var ptr = UnsafePointer(to=arr[i]).unsafe_origin_cast[origin_of(arr)]()
    return _resolve_ref(ptr[], tokens, idx + 1)
