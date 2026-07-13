from .value import Value, Null
from std.collections import Dict, List
from std.sys.intrinsics import unlikely, likely
from .traits import JsonValue, PrettyPrintable
from ._deserialize import Parser, ParseOptions
from ._serialize import Serializer
from .utils import write_escaped_string, PaddedBuffer, PAD_INPUT_THRESHOLD
from std.python import PythonObject, Python
from std.os import abort
from std.memory import UnsafePointer
from std.hashlib.hasher import Hasher
from std.hashlib import hash


@fieldwise_init
struct KeyValuePair(Copyable, Hashable):
    # `key_hash` is cached so duplicate-key checks and lookups can short-circuit
    # on a UInt64 compare before falling back to a String compare on collision.
    # This is what lets `Object` keep a single `List` allocation while still
    # making "no duplicate keys" a structural invariant.
    var key_hash: UInt64
    var key: String
    var value: Value

    @always_inline
    def __init__(out self, var key: String, var value: Value):
        self.key_hash = hash(key)
        self.key = key^
        self.value = value^


struct _ObjectIter[origin: Origin](Sized, TrivialRegisterPassable):
    var src: Pointer[Object, Self.origin]
    var idx: Int

    @always_inline
    def __init__(out self, src: Pointer[Object, Self.origin]):
        self.src = src
        self.idx = 0

    @always_inline
    def __iter__(self) -> Self:
        return self

    @always_inline
    def __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data] KeyValuePair:
        if self.idx >= len(self.src[]):
            raise StopIteration()
        self.idx += 1
        return self.src[]._data[self.idx - 1]

    @always_inline
    def __len__(self) -> Int:
        return len(self.src[]) - self.idx


struct _ObjectKeyIter[origin: Origin](Sized, TrivialRegisterPassable):
    var src: Pointer[Object, Self.origin]
    var idx: Int

    @always_inline
    def __init__(out self, src: Pointer[Object, Self.origin]):
        self.src = src
        self.idx = 0

    @always_inline
    def __iter__(self) -> Self:
        return self

    @always_inline
    def __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data[0].key] String:
        if self.idx >= len(self.src[]):
            raise StopIteration()
        self.idx += 1
        return self.src[]._data[self.idx - 1].key

    @always_inline
    def __len__(self) -> Int:
        return len(self.src[]) - self.idx


struct _ObjectValueIter[origin: Origin](Sized, TrivialRegisterPassable):
    var src: Pointer[Object, Self.origin]
    var idx: Int

    @always_inline
    def __init__(out self, src: Pointer[Object, Self.origin]):
        self.src = src
        self.idx = 0

    @always_inline
    def __iter__(self) -> Self:
        return self

    @always_inline
    def __next__(
        mut self,
    ) raises StopIteration -> ref[self.src[]._data[0].value] Value:
        if self.idx >= len(self.src[]):
            raise StopIteration()
        self.idx += 1
        return self.src[]._data[self.idx - 1].value

    @always_inline
    def __len__(self) -> Int:
        return len(self.src[]) - self.idx


comptime _INDEX_THRESHOLD = 12
"""Entry count above which the parser builds a transient hash index over an
object's keys.

Kept high enough that the many small objects typical of JSON documents
(2-4 keys) never pay the index allocation, while large objects get O(1)
duplicate detection/insert instead of a linear scan (O(n^2) object
construction)."""


struct _ObjectParseIndex(Movable):
    """Transient open-addressing hash index over an `Object`'s `_data`, used
    only while the parser builds an object. Slots hold entry index + 1
    (0 = empty slot), probed linearly on the cached `key_hash`.

    This deliberately lives outside `Object`: an index field on `Object`
    itself would grow the `Value` variant (sized by its largest member) and
    tax every parsed value. Empty `slots` means "no index" — small objects
    never allocate one.
    """

    var slots: List[UInt32]

    @always_inline
    def __init__(out self):
        self.slots = List[UInt32]()

    def find(self, data: List[KeyValuePair], h: UInt64, key: String) -> Int:
        """Probes for `key`. Returns the entry's position in `data`, or -1
        if absent. Requires non-empty `slots`.
        """
        var mask = UInt64(len(self.slots) - 1)
        var slot = Int(h & mask)
        while True:
            var stored = self.slots[slot]
            if stored == 0:
                return -1
            var entry = Int(stored - 1)
            if data[entry].key_hash == h and data[entry].key == key:
                return entry
            slot = Int((UInt64(slot) + 1) & mask)

    def insert_slot(mut self, h: UInt64, entry: UInt32):
        """Records `entry` (a position in the object's `_data`). The entry's
        key must not already be present in the index.
        """
        var mask = UInt64(len(self.slots) - 1)
        var slot = Int(h & mask)
        while self.slots[slot] != 0:
            slot = Int((UInt64(slot) + 1) & mask)
        self.slots[slot] = entry + 1

    def rebuild(mut self, data: List[KeyValuePair]):
        """(Re)builds the index sized for the current entry count, using the
        cached key hashes (no re-hashing of key strings).
        """
        var cap = 32
        while cap < 2 * (len(data) + 1):
            cap *= 2
        self.slots = List[UInt32](length=cap, fill=0)
        for i in range(len(data)):
            self.insert_slot(data[i].key_hash, UInt32(i))

    @always_inline
    def note_append(mut self, data: List[KeyValuePair], h: UInt64):
        """Maintains the index after an append at `len(data) - 1`: builds it
        once the threshold is crossed, grows it past 50% load, otherwise
        records the new entry.
        """
        if len(self.slots) == 0:
            if len(data) >= _INDEX_THRESHOLD:
                self.rebuild(data)
        elif unlikely(2 * len(data) >= len(self.slots)):
            self.rebuild(data)
        else:
            self.insert_slot(h, UInt32(len(data) - 1))


struct Object(JsonValue, Sized):
    """Represents a key-value pair object.
    All keys are String and all values are of type `Value` which is
    a variant type of any valid JSON type.
    """

    comptime Type = List[KeyValuePair]
    var _data: Self.Type

    @always_inline
    def __init__(out self):
        self._data = Self.Type()

    @always_inline
    def __init__(out self, *, capacity: Int):
        self._data = Self.Type(capacity=capacity)

    @always_inline
    @implicit
    def __init__(out self, var d: Self.Type):
        self._data = d^

    @always_inline
    @implicit
    def __init__(out self, var d: Dict[String, Value]):
        # A `Dict` already enforces unique keys, so we can append directly
        # without going through `_upsert`.
        self._data = Self.Type(capacity=len(d))
        for item in d.items():
            self._data.append(KeyValuePair(item.key, item.value.copy()))

    def __init__(
        out self,
        var keys: List[String],
        var values: List[Value],
        __dict_literal__: NoneType,
    ):
        assert len(keys) == len(
            values
        ), "Keys and values must have the same length"
        self._data = Self.Type(capacity=len(keys))
        for i in range(len(keys)):
            self._upsert(keys[i], values[i].copy())

    @always_inline
    def __init__(out self, *, parse_string: String) raises:
        # See `emberjson.parse`: pad-and-copy enables unchecked hot loops;
        # tiny inputs skip the copy since it would cost more than the parse.
        if parse_string.byte_length() < PAD_INPUT_THRESHOLD:
            var p = Parser(parse_string)
            self = p.parse_object()
        else:
            var buf = PaddedBuffer(StringSlice(parse_string).as_bytes())
            var p = Parser[options=ParseOptions()._padded()](buf.span())
            self = p.parse_object()

    @always_inline
    def _find_entry(self, h: UInt64, key: String) -> Int:
        """Returns the position of `key` in `_data` (or -1) via a linear scan
        that short-circuits on the cached hashes.
        """
        for i in range(len(self._data)):
            if self._data[i].key_hash == h and self._data[i].key == key:
                return i
        return -1

    def _upsert(mut self, var key: String, var item: Value):
        """Single insertion path: replace the value if `key` already exists,
        otherwise append. This is the only way values enter `_data`, so the
        "no duplicate keys" invariant is structural for any `Object` mutation
        path that goes through public methods or the parser.
        """
        var h = hash(key)
        var entry = self._find_entry(h, key)
        if entry >= 0:
            self._data[entry].value = item^
            return
        self._data.append(KeyValuePair(h, key^, item^))

    def _append_for_parse[
        allow_duplicates: Bool
    ](
        mut self,
        var key: String,
        var item: Value,
        mut index: _ObjectParseIndex,
    ) raises:
        """Parser-only insertion: hashes the key and searches once, combining
        the duplicate-key check with the insert. In strict mode
        (`allow_duplicates=False`) a duplicate raises; in lenient mode it
        collapses with last-write-wins, preserving the first key's position —
        identical semantics to the previous `__contains__` + `_upsert` pair.

        `index` is the transient per-object hash index maintained by
        `parse_object`; it keeps duplicate detection O(1) for large objects
        without growing `Object` itself.
        """
        var h = hash(key)
        var entry: Int
        if len(index.slots) != 0:
            entry = index.find(self._data, h, key)
        else:
            entry = self._find_entry(h, key)
        if entry >= 0:
            comptime if allow_duplicates:
                self._data[entry].value = item^
                return
            else:
                raise Error("Duplicate key: ", key)
        self._data.append(KeyValuePair(h, key^, item^))
        index.note_append(self._data, h)

    @always_inline
    def __setitem__(mut self, var key: String, var item: Value):
        """Sets a key-value pair.
        If the key already exists, its value is updated.
        """
        self._upsert(key^, item^)

    def pop(mut self, key: String) raises:
        var entry = self._find_entry(hash(key), key)
        if entry < 0:
            raise Error("KeyError: " + key)
        _ = self._data.pop(entry)

    def __getitem__(
        ref self, key: String
    ) raises -> ref[self._data[0].value] Value:
        var entry = self._find_entry(hash(key), key)
        if entry < 0:
            raise Error("KeyError: " + key)
        return self._data[entry].value

    @always_inline
    def __contains__(self, key: String) -> Bool:
        return self._find_entry(hash(key), key) >= 0

    @always_inline
    def __len__(self) -> Int:
        return len(self._data)

    def __eq__(self, other: Self) -> Bool:
        # Both sides have unique keys (enforced by `_upsert`), so equal length
        # plus every key of `self` matched in `other` is sufficient — no need
        # for a reverse pass.
        if len(self) != len(other):
            return False
        for i in range(len(self._data)):
            ref entry = self._data[i]
            var found = False
            for j in range(len(other._data)):
                ref oe = other._data[j]
                if entry.key_hash == oe.key_hash and entry.key == oe.key:
                    if entry.value != oe.value:
                        return False
                    found = True
                    break
            if not found:
                return False
        return True

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return not self == other

    @always_inline
    def __bool__(self) -> Bool:
        return len(self) != 0

    @always_inline
    def keys(ref self) -> _ObjectKeyIter[origin_of(self)]:
        return _ObjectKeyIter(Pointer(to=self))

    @always_inline
    def values(ref self) -> _ObjectValueIter[origin_of(self)]:
        return _ObjectValueIter(Pointer(to=self))

    @always_inline
    def __iter__(ref self) -> _ObjectKeyIter[origin_of(self)]:
        return self.keys()

    @always_inline
    def items(ref self) -> _ObjectIter[origin_of(self)]:
        return _ObjectIter(Pointer(to=self))

    @always_inline
    def write_json(self, mut writer: Some[Serializer]):
        writer.write(self)

    def pretty_to(
        self, mut writer: Some[Writer], indent: String, *, curr_depth: UInt = 0
    ):
        writer.write("{\n")
        self._pretty_write_items(writer, indent, curr_depth + 1)
        writer.write("}")

    def _pretty_write_items(
        self, mut writer: Some[Writer], indent: String, curr_depth: UInt
    ):
        var done = 0
        for item in self._data:
            for _ in range(curr_depth):
                writer.write(indent)
            write_escaped_string(item.key, writer)
            writer.write(": ")
            item.value._pretty_to_as_element(writer, indent, curr_depth)
            if done < len(self._data) - 1:
                writer.write(",")
            writer.write("\n")
            done += 1

    def write_to(self, mut writer: Some[Writer]):
        writer.write("{")
        for i in range(len(self._data)):
            write_escaped_string(self._data[i].key, writer)
            writer.write(":")
            writer.write(self._data[i].value)
            if i < len(self._data) - 1:
                writer.write(",")
        writer.write("}")

    def write_repr_to(self, mut writer: Some[Writer]):
        writer.write("Object{")
        for i in range(len(self._data)):
            write_escaped_string(self._data[i].key, writer)
            writer.write(":")
            self._data[i].value.write_repr_to(writer)
            if i < len(self._data) - 1:
                writer.write(",")
        writer.write("}")

    @always_inline
    def to_dict(self, out d: Dict[String, Value]):
        d = Dict[String, Value]()
        for item in self.items():
            d[item.key] = item.value.copy()

    def to_python_object(self) raises -> PythonObject:
        var d = Python.dict()
        for item in self.items():
            d[PythonObject(item.key)] = item.value.to_python_object()
        return d

    @staticmethod
    def from_json[
        origin: ImmutOrigin, options: ParseOptions, //
    ](mut p: Parser[origin, options], out s: Self) raises:
        s = p.parse_object()
