from .reader import Reader
from .value import Value, Null
from collections import Dict
from .constants import *
from .utils import *
from sys.intrinsics import unlikely, likely
from .traits import JsonValue


@value
struct Object(Sized, JsonValue):
    alias Type = Dict[String, Value]
    var _data: Self.Type

    fn __init__(inout self):
        self._data = Self.Type()

    fn bytes_for_string(self) -> Int:
        var n = 2 + len(self)  # include ':' for each pairing
        for k in self._data:
            try:
                n += 3 + len(k[]) + self._data[k[]].bytes_for_string()
            except:
                pass
        n -= 1
        return n

    @always_inline
    fn __setitem__(inout self, owned key: String, owned item: Value):
        self._data[key^] = item^

    fn __getitem__(ref [_]self, key: String) raises -> ref [self._data._entries[0].value().value] Value:
        return self._data._find_ref(key)

    @always_inline
    fn __contains__(self, key: String) -> Bool:
        return key in self._data

    @always_inline
    fn __len__(self) -> Int:
        return len(self._data)

    @always_inline
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

    fn write_to[W: Writer](self, inout writer: W):
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

    @always_inline
    fn __str__(self) -> String:
        return write(self)

    @always_inline
    fn __repr__(self) -> String:
        return self.__str__()

    @staticmethod
    fn _from_reader(inout reader: Reader) raises -> Object:
        reader.inc()
        var out = Self()
        reader.skip_whitespace()
        while likely(reader.peek() != RCURLY):
            if unlikely(reader.peek() != QUOTE):
                raise Error("Invalid identifier")
            reader.inc()
            var ident = reader.read_string()
            reader.inc()
            reader.skip_whitespace()
            if unlikely(reader.peek() != COLON):
                raise Error("Invalid identifier")
            reader.inc()
            var val = Value._from_reader(reader)
            var has_comma = False
            if reader.peek() == COMMA:
                has_comma = True
                reader.inc()
            reader.skip_whitespace()
            if unlikely(reader.peek() == RCURLY and has_comma):
                raise Error("Illegal trailing comma")
            out[bytes_to_string(ident^)] = val^
        reader.inc()
        return out^

    @staticmethod
    fn from_string(s: String) raises -> Object:
        var r = Reader(s.as_string_slice())
        return Self._from_reader(r)
