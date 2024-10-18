from .reader import Reader, bytes_to_string
from .value import Value, Null
from collections import Dict
from .constants import *
from sys.intrinsics import unlikely, likely


@value
struct Object(EqualityComparableCollectionElement, Sized, Formattable, Stringable, Representable):
    alias Type = Dict[String, Value]
    var _data: Self.Type

    fn __init__(inout self):
        self._data = Self.Type()

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

    fn format_to(self, inout writer: Formatter):
        writer.write("{")
        var done = 0
        for k in self._data:
            try:
                writer.write('"', k[], '"', ":", self._data[k[]])
                if done < len(self._data) - 1:
                    writer.write(",")
                done += 1
            except:
                # Can't happen
                pass

        writer.write("}")

    @always_inline
    fn __str__(self) -> String:
        return String.format_sequence(self)

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
    fn from_string(owned s: String) raises -> Object:
        var r = Reader(s^)
        return Self._from_reader(r)
