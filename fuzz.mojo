from python import Python
from random.random import random_ui64, random_si64, random_float64, seed
from emberjson import parse, Array, Object, Value, Null, JSON
from utils.numerics import isinf
from time import monotonic
from testing import assert_equal


def gen_collection_len() -> Int:
    return Int(random_ui64(0, 200))


def gen_int() -> Int64:
    return random_si64(Int64.MIN, Int64.MAX)


def gen_uint() -> UInt64:
    return random_ui64(UInt64.MIN, UInt64.MAX)


def gen_float() -> Float64:
    # TODO: This doesn't work very well
    return random_float64(-100.123214, 1000.123154)


def gen_string() -> String:
    var faker = Python.import_module("faker").Faker()
    return String(faker.lexify("?" * (gen_collection_len() + 1)))


def gen_array(out arr: Array):
    arr = Array()

    var l = gen_collection_len()
    arr.reserve(l)

    for _ in range(l):
        arr.append(gen_value())


def gen_object(out ob: Object):
    ob = Object()

    for _ in range(gen_collection_len()):
        ob[gen_string()] = gen_value()


def gen_value() -> Value:
    var a = random_ui64(0, 5)

    if a == 0:
        return Null()
    elif a == 1:
        return gen_int()
    elif a == 2:
        return gen_uint()
    elif a == 3:
        return gen_string()
    elif a == 4:
        return coin_flip()
    elif a == 5:
        return gen_float()
    elif a == 6:
        return gen_array()
    else:
        return gen_object()


def gen_json(out j: JSON):
    if coin_flip():
        return gen_array()
    return gen_object()


def gen_object_string() -> String:
    var s = String("{")

    var l = gen_collection_len()
    for i in range(l):
        s += String('"', gen_string(), '"', ":", gen_value())
        if i < l - 1:
            s += ","

    s += "}"

    return s


def gen_array_string() -> String:
    var s: String = "["
    var l = gen_collection_len()

    for i in range(l):
        s += String(gen_value())
        if i < l - 1:
            s += ","

    s += "]"
    return s


def gen_json_string() -> String:
    return gen_array_string() if coin_flip() else gen_object_string()


def coin_flip() -> Bool:
    return random_ui64(0, 1) == 1


def main():
    print("Running fuzzy tests...")
    seed()
    var start = monotonic()
    var i = 0
    while monotonic() - start < 5000000000:
        var j = gen_json_string()
        try:
            if i % 5 == 0:
                # Randomly slice the input to check for UB in the parser
                # since we have debug_assert enabled
                j = j[: Int(random_ui64(0, len(j) - 1))]
                try:
                    _ = parse(j)
                except e:
                    pass
            else:
                _ = parse(j)
            i += 1
        except:
            raise Error("CASE FAILED: " + j)
