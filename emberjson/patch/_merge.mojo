from emberjson import Value, Object, Array, Null


fn merge_patch(mut target: Value, patch: String) raises:
    merge_patch(target, Value(parse_string=patch))


fn merge_patch(mut target: Value, patch: Value) raises:
    """Applies a JSON Merge Patch (RFC 7386) to the target value.
    The target is modified in-place.
    """
    if patch.is_object():
        if not target.is_object():
            target = Value(Object())

        ref patch_obj = patch.object()
        var keys = List[String]()
        for key in patch_obj.keys():
            keys.append(key)

        for i in range(len(keys)):
            ref key = keys[i]
            if key not in patch_obj:
                continue  # Should not happen

            ref patch_val = patch_obj[key]

            if patch_val.is_null():
                if key in target.object():
                    target.object().pop(key)
            else:
                # Add or update
                if key not in target.object():
                    target[key] = patch_val.copy()
                else:
                    # Recursive merge
                    # We need to get a mutable reference to the target child
                    merge_patch(target[key], patch_val)
    else:
        # If the patch is not an object, it replaces the target.
        target = patch.copy()
