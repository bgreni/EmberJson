from emberjson import Value, Array, Object, PointerIndex
from emberjson._pointer import resolve_pointer, PointerToken, parse_int

comptime Add = "add"
comptime Remove = "remove"
comptime Replace = "replace"
comptime Copy = "copy"
comptime Move = "move"
comptime Test = "test"


@always_inline
def check_key(command: Object, key: String) raises:
    if key not in command:
        raise Error('invalid patch operation expect "', key, '" key')


@always_inline
def _string_member(command: Object, key: String) raises -> String:
    """Returns the `key` member of a patch operation, which RFC 6902 §4
    requires to be a string. `Value.string()` is an unchecked variant read,
    so the arm must be tested first; a non-string member is an error, never
    a reinterpretation."""
    if key not in command:
        raise Error('invalid patch operation expect "', key, '" key')
    ref member = command[key]
    if not member.is_string():
        raise Error('invalid patch operation: "', key, '" must be a string')
    return String(member.string())


def parse_patches(s: String) raises -> Array:
    return Array(parse_string=s)


def patch(mut v: Value, s: String) raises:
    patch(v, parse_patches(s))


def patch(mut v: Value, commands: Array) raises:
    var cpy = v.copy()

    for command in commands:
        if not command.is_object():
            raise Error("Expected patch operation to be object")
        _apply_op(cpy, command.object())

    v = cpy^


def _apply_op(mut v: Value, command: Object) raises:
    var op_str = _string_member(command, "op")

    if op_str == Add:
        _apply_add(v, command)
    elif op_str == Remove:
        _apply_remove(v, command)
    elif op_str == Replace:
        _apply_replace(v, command)
    elif op_str == Move:
        _apply_move(v, command)
    elif op_str == Copy:
        _apply_copy(v, command)
    elif op_str == Test:
        _apply_test(v, command)
    else:
        raise Error("Unknown patch operation: " + op_str)


def _apply_add(mut v: Value, command: Object) raises:
    check_key(command, "value")

    ref value = command["value"]
    var path_str = _string_member(command, "path")

    if path_str == "":
        v = value.copy()
        return

    var path = PointerIndex(path_str)

    ref parent_ref = _resolve_parent_ptr(v, path)
    var last_token = path.tokens[len(path.tokens) - 1]

    if parent_ref.is_object():
        var key = _token_to_key(last_token)
        parent_ref.object()[key] = value.copy()
    elif parent_ref.is_array():
        var idx_str = _token_to_key(last_token)
        if idx_str == "-":
            parent_ref.array().append(value.copy())
        else:
            var idx = _parse_array_index(idx_str, len(parent_ref.array()) + 1)
            parent_ref.array().insert(idx, value.copy())
    else:
        raise Error("Cannot add to non-container parent")


def _apply_remove(mut v: Value, command: Object) raises:
    var path_str = _string_member(command, "path")

    if path_str == "":
        raise Error("Cannot remove root")

    var path = PointerIndex(path_str)
    ref parent_ref = _resolve_parent_ptr(v, path)
    var last_token = path.tokens[len(path.tokens) - 1]

    if parent_ref.is_object():
        var key = _token_to_key(last_token)
        parent_ref.object().pop(key)
    elif parent_ref.is_array():
        var idx = _parse_array_index(
            _token_to_key(last_token), len(parent_ref.array())
        )
        _ = parent_ref.array().pop(idx)
    else:
        raise Error("Cannot remove from non-container")


def _apply_replace(mut v: Value, command: Object) raises:
    check_key(command, "value")

    var path_str = _string_member(command, "path")
    ref value = command["value"]

    if path_str == "":
        v = value.copy()
        return

    var path = PointerIndex(path_str)
    ref parent_ref = _resolve_parent_ptr(v, path)
    var last_token = path.tokens[len(path.tokens) - 1]

    if parent_ref.is_object():
        var key = _token_to_key(last_token)
        if key not in parent_ref.object():
            raise Error("Key not found: " + key)

        parent_ref.object()[key] = value.copy()

    elif parent_ref.is_array():
        var idx = _parse_array_index(
            _token_to_key(last_token), len(parent_ref.array())
        )
        _ = parent_ref.array().pop(idx)
        parent_ref.array().insert(idx, value.copy())
    else:
        raise Error("Cannot replace in non-container parent")


def _apply_move(mut v: Value, command: Object) raises:
    var from_path = _string_member(command, "from")
    var to_path = _string_member(command, "path")

    if to_path.startswith(from_path + "/"):
        raise Error("Cannot move to child of from location")

    if from_path == to_path:
        return

    var val_to_move = resolve_pointer(v, PointerIndex(from_path)).copy()

    var rm_cmd = Object()
    rm_cmd["op"] = Value("remove")
    rm_cmd["path"] = Value(from_path)
    _apply_remove(v, rm_cmd)

    var add_cmd = Object()
    add_cmd["op"] = Value("add")
    add_cmd["path"] = Value(to_path)
    add_cmd["value"] = val_to_move^
    _apply_add(v, add_cmd)


def _apply_copy(mut v: Value, command: Object) raises:
    var from_path = _string_member(command, "from")
    var to_path = _string_member(command, "path")

    var val_to_copy = resolve_pointer(v, PointerIndex(from_path)).copy()

    var add_cmd = Object()
    add_cmd["op"] = Value("add")
    add_cmd["path"] = Value(to_path)
    add_cmd["value"] = val_to_copy^
    _apply_add(v, add_cmd)


def _apply_test(mut v: Value, command: Object) raises:
    check_key(command, "value")

    var path = _string_member(command, "path")
    ref expected = command["value"]

    ref actual = resolve_pointer(v, PointerIndex(path))

    if not _json_equal(actual, expected):
        raise Error("Test failed: values differ at " + path)


# --- Helpers ---


def _as_float(v: Value) -> Float64:
    if v.is_float():
        return v.float()
    if v.is_int():
        return Float64(v.int())
    return Float64(v.uint())


def _json_equal(a: Value, b: Value) raises -> Bool:
    """RFC 6902 §4.6 equality. Numbers compare by value whichever arm holds
    them (integers beyond 2^53 are compared through Float64, the documented
    interop limit); arrays element-wise; objects by member set regardless of
    order; everything else defers to `Value.__eq__`."""
    var a_num = a.is_int() or a.is_uint() or a.is_float()
    var b_num = b.is_int() or b.is_uint() or b.is_float()
    if a_num and b_num:
        if a.is_float() or b.is_float():
            return _as_float(a) == _as_float(b)
        return a == b
    if a.is_array() and b.is_array():
        ref x = a.array()
        ref y = b.array()
        if len(x) != len(y):
            return False
        for i in range(len(x)):
            if not _json_equal(x[i], y[i]):
                return False
        return True
    if a.is_object() and b.is_object():
        ref x = a.object()
        ref y = b.object()
        if len(x) != len(y):
            return False
        for key in x.keys():
            if key not in y:
                return False
            if not _json_equal(x[key], y[key]):
                return False
        return True
    return a == b


def _resolve_parent_ptr(
    mut root: Value, ptr: PointerIndex
) raises -> ref[root] Value:
    if len(ptr.tokens) == 0:
        raise Error("Cannot resolve parent of root")

    var parent_tokens = List[PointerToken]()
    for i in range(len(ptr.tokens) - 1):
        parent_tokens.append(ptr.tokens[i])

    var parent_ptr_idx = PointerIndex(parent_tokens^)
    return resolve_pointer(root, parent_ptr_idx)


def _token_to_key(token: PointerToken) -> String:
    if token.isa[String]():
        return token[String]
    else:
        return String(token[Int])


def _parse_array_index(s: String, arr_len: Int) raises -> Int:
    if s == "0":
        return 0
    if s.startswith("0"):
        raise Error("Leading zeros not allowed in array index")

    try:
        var i = parse_int(s)
        if i < 0 or i >= arr_len:
            raise Error("Index out of bounds")
        return i
    except:
        raise Error("Invalid array index")
