from emberjson import Value, Array, Object, PointerIndex
from emberjson._pointer import resolve_pointer, PointerToken, parse_int

comptime Add = "add"
comptime Remove = "remove"
comptime Replace = "replace"
comptime Copy = "copy"
comptime Move = "move"
comptime Test = "test"


@always_inline
fn check_key(command: Object, key: String) raises:
    if key not in command:
        raise Error('invalid patch operation expect "', key, '" key')


fn parse_patches(s: String) raises -> Array:
    return Array(parse_string=s)


fn patch(mut v: Value, s: String) raises:
    patch(v, parse_patches(s))


fn patch(mut v: Value, commands: Array) raises:
    var cpy = v.copy()

    for command in commands:
        if not command.is_object():
            raise Error("Expected patch operation to be object")
        _apply_op(cpy, command.object())

    v = cpy^


fn _apply_op(mut v: Value, command: Object) raises:
    check_key(command, "op")

    ref op = command["op"]
    ref op_str = op.string()

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


fn _apply_add(mut v: Value, command: Object) raises:
    check_key(command, "path")
    check_key(command, "value")

    ref value = command["value"]
    ref path_str = command["path"].string()

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


fn _apply_remove(mut v: Value, command: Object) raises:
    check_key(command, "path")

    ref path_str = command["path"].string()
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


fn _apply_replace(mut v: Value, command: Object) raises:
    check_key(command, "path")
    check_key(command, "value")

    var path_str = command["path"].string()
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


fn _apply_move(mut v: Value, command: Object) raises:
    check_key(command, "from")
    check_key(command, "path")

    ref from_path = command["from"].string()
    ref to_path = command["path"].string()

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


fn _apply_copy(mut v: Value, command: Object) raises:
    check_key(command, "from")
    check_key(command, "path")

    ref from_path = command["from"].string()
    ref to_path = command["path"].string()

    var val_to_copy = resolve_pointer(v, PointerIndex(from_path)).copy()

    var add_cmd = Object()
    add_cmd["op"] = Value("add")
    add_cmd["path"] = Value(to_path)
    add_cmd["value"] = val_to_copy^
    _apply_add(v, add_cmd)


fn _apply_test(mut v: Value, command: Object) raises:
    check_key(command, "path")
    check_key(command, "value")

    ref path = command["path"].string()
    ref expected = command["value"]

    ref actual = resolve_pointer(v, PointerIndex(path))

    if actual != expected:
        raise Error("Test failed: values differ at " + path)


# --- Helpers ---


fn _resolve_parent_ptr(
    mut root: Value, ptr: PointerIndex
) raises -> ref[root] Value:
    if len(ptr.tokens) == 0:
        raise Error("Cannot resolve parent of root")

    var parent_tokens = List[PointerToken]()
    for i in range(len(ptr.tokens) - 1):
        parent_tokens.append(ptr.tokens[i])

    var parent_ptr_idx = PointerIndex(parent_tokens^)
    return resolve_pointer(root, parent_ptr_idx)


fn _token_to_key(token: PointerToken) -> String:
    if token.isa[String]():
        return token[String]
    else:
        return String(token[Int])


fn _parse_array_index(s: String, arr_len: Int) raises -> Int:
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
