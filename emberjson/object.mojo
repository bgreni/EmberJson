from .value import Value, Null
from collections import Dict
from .constants import *
from .utils import *
from sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from .parser import Parser


@value
struct Object(Sized, JsonValue, PrettyPrintable):
    alias Type = Dict[String, Value]
    var _data: Self.Type

    fn __init__(out self):
        # TODO: Maybe a good candidate for autotuning in the future?
        self._data = Self.Type(power_of_two_initial_capacity=32)

    fn min_size_for_string(self) -> Int:
        var n = 2 + len(self)  # include ':' for each pairing
        for k in self._data:
            try:
                n += 3 + len(k[]) + self._data[k[]].min_size_for_string()
            except:
                pass
        n -= 1
        return n

    @always_inline
    fn __setitem__(mut self, owned key: String, owned item: Value):
        self._data[key^] = item^

    @always_inline
    fn __getitem__(ref [_]self, key: String) raises -> ref [self._data._entries[0].value().value] Value:
        return self._data._find_ref(key)

    @always_inline
    fn __contains__(self, key: String) -> Bool:
        return key in self._data

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    fn __eq__(self, other: Self) -> Bool:
        if len(self) != len(other):
            return False

        for k in self._data:
            if k[] not in other:
                return False
            try:
                if self[k[]] != other[k[]]:
                    return False
            except:
                return False
        return True

    @always_inline
    fn __ne__(self, other: Self) -> Bool:
        return not self == other

    fn write_to[W: Writer](self, mut writer: W):
        ("{").write_to(writer)
        var done = 0
        for k in self._data:
            try:
                ('"').write_to(writer)
                k[].write_to(writer)
                ('"').write_to(writer)
                (":").write_to(writer)
                self._data[k[]].write_to(writer)
                if done < len(self._data) - 1:
                    (",").write_to(writer)
                done += 1
            except:
                # Can't happen
                pass

        ("}").write_to(writer)

    fn pretty_to[W: Writer](self, mut writer: W, indent: String):
        writer.write("{\n")
        self._pretty_write_items(writer, indent)
        writer.write("}")

    fn _pretty_write_items[W: Writer](self, mut writer: W, indent: String):
        try:
            var done = 0
            for k in self._data:
                writer.write(indent, '"', k[], '"', ": ")
                self[k[]]._pretty_to_as_element(writer, indent)
                if done < len(self._data) - 1:
                    writer.write(",")
                writer.write("\n")
                done += 1
        except:
            pass

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @staticmethod
    @always_inline
    fn from_string(out o: Object, s: String) raises:
        var p = Parser(s)
        o = p.parse_object()
