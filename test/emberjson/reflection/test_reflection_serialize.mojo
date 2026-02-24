from testing import TestSuite, assert_equal
from emberjson._serialize import serialize, JsonSerializable, PrettySerializer
from emberjson.lazy import LazyFloat
from std.collections import Set
from std.memory import ArcPointer, OwnedPointer


@fieldwise_init
struct Bar(Copyable):
    var b: Int


@fieldwise_init
struct Foo[I: IntLiteral, F: FloatLiteral]:
    var f: Int
    var s: String
    var o: Optional[Int]
    var bar: Bar
    var i: Int32
    var vec: SIMD[DType.float64, 2]
    var l: List[Int]
    var arr: InlineArray[Bool, 3]
    var dic: Dict[String, Int]
    var il: type_of(Self.I)
    var fl: type_of(Self.F)
    var tup: Tuple[Int, Int, Int]
    var set: Set[Int]
    var arc_ptr: ArcPointer[Int]
    var owned_ptr: OwnedPointer[Int]


@fieldwise_init
struct Baz(JsonSerializable):
    var a: Bool
    var b: Int
    var c: String

    @staticmethod
    fn serialize_as_array() -> Bool:
        return True


def test_serialize():
    var f = Foo[45, 7.43](
        1,
        "something",
        10,
        Bar(20),
        23,
        [2.32, 5.345],
        [32, 42, 353],
        [False, True, True],
        {"a key": 1234},
        {},
        {},
        (1, 2, 3),
        {1, 2, 3},
        ArcPointer(1234),
        OwnedPointer(4321),
    )

    assert_equal(
        serialize(f),
        (
            '{"f":1,"s":"something","o":10,"bar":{"b":20},"i":23,"vec":[2.32,5.345],"l":[32,42,353],"arr":[false,true,true],"dic":{"a'
            ' key":1234},"il":45,"fl":7.43,"tup":[1,2,3],"set":[1,2,3],"arc_ptr":1234,"owned_ptr":4321}'
        ),
    )


def test_ctime_serialize():
    comptime f = Foo[45, 7.43](
        1,
        "something",
        10,
        Bar(20),
        23,
        [2.32, 5.345],
        [32, 42, 353],
        [False, True, True],
        {"a key": 1234},
        {},
        {},
        (1, 2, 3),
        {1, 2, 3},
        ArcPointer(1234),
        OwnedPointer(4321),
    )

    comptime serialized = serialize(f)

    assert_equal(
        serialized,
        (
            '{"f":1,"s":"something","o":10,"bar":{"b":20},"i":23,"vec":[2.32,5.345],"l":[32,42,353],"arr":[false,true,true],"dic":{"a'
            ' key":1234},"il":45,"fl":7.43,"tup":[1'
            ',2,3],"set":[1,2,3],"arc_ptr":1234,"owned_ptr":4321}'
        ),
    )


@fieldwise_init
struct Address(Copyable):
    var street: String
    var city: String
    var zip: Int


@fieldwise_init
struct Person(Copyable):
    var name: String
    var age: Int
    var address: Address
    var tags: List[String]


@fieldwise_init
struct Department(Copyable):
    var name: String
    var manager: Person
    var employees: List[Person]


@fieldwise_init
struct Company(JsonSerializable):
    var name: String
    var hq: Address
    var departments: Dict[String, Department]
    var founded_year: Int

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


@fieldwise_init
struct IntWrapper(JsonSerializable):
    var value: Int
    var description: String

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


@fieldwise_init
struct AddressWrapper(JsonSerializable):
    var value: Address
    var description: String

    @staticmethod
    fn serialize_as_array() -> Bool:
        return False


@fieldwise_init
struct MaybeFields(Copyable):
    var f1: Optional[Int]
    var f2: Optional[String]
    var f3: Optional[Address]


@fieldwise_init
struct DeepNode(Copyable):
    var val: Int
    var children: List[DeepNode]

    fn __init__(out self, *, copy: Self):
        self.val = copy.val
        self.children = List[DeepNode](capacity=len(copy.children))
        for i in range(len(copy.children)):
            self.children.append(copy.children[i].copy())


def test_nested_structs():
    var addr = Address("123 Main St", "Springfield", 62704)
    var tags = List[String]()
    tags.append("safety")
    tags.append("inspector")
    var p = Person("Homer", 39, addr^, tags^)

    assert_equal(
        serialize(p^),
        (
            '{"name":"Homer","age":39,"address":{"street":"123 Main'
            ' St","city":"Springfield","zip":62704},"tags":["safety","inspector"]}'
        ),
    )


def test_deep_hierarchy():
    var hq = Address("1 Infinite Loop", "Cupertino", 95014)
    var manager_addr = Address("Test St", "Test City", 12345)
    var manager_tags = List[String]()
    manager_tags.append("mgr")
    var manager = Person("Alice", 30, manager_addr^, manager_tags^)

    var emp_addr = Address("Emp St", "Emp City", 54321)
    var emp_tags = List[String]()
    emp_tags.append("dev")
    var emp1 = Person("Bob", 25, emp_addr^, emp_tags^)

    var employees = List[Person]()
    employees.append(emp1^)

    var dept = Department("Engineering", manager^, employees^)
    var depts = Dict[String, Department]()
    depts["Engineering"] = dept^

    var company = Company("Tech Corp", hq^, depts^, 1990)

    var expected = '{"name":"Tech Corp","hq":{"street":"1 Infinite Loop","city":"Cupertino","zip":95014},"departments":{"Engineering":{"name":"Engineering","manager":{"name":"Alice","age":30,"address":{"street":"Test St","city":"Test City","zip":12345},"tags":["mgr"]},"employees":[{"name":"Bob","age":25,"address":{"street":"Emp St","city":"Emp City","zip":54321},"tags":["dev"]}]}},"founded_year":1990}'
    assert_equal(serialize(company^), expected)


def test_wrappers():
    var w_int = IntWrapper(123, "an integer")
    assert_equal(serialize(w_int^), '{"value":123,"description":"an integer"}')

    var addr = Address("Row", "London", 123)
    var w_addr = AddressWrapper(addr^, "an address")
    assert_equal(
        serialize(w_addr^),
        (
            '{"value":{"street":"Row","city":"London","zip":123},"description":"an'
            ' address"}'
        ),
    )


def test_optional_fields():
    var m1 = MaybeFields(10, String("foo"), Address("A", "B", 1))
    assert_equal(
        serialize(m1^),
        '{"f1":10,"f2":"foo","f3":{"street":"A","city":"B","zip":1}}',
    )

    var m2 = MaybeFields(None, None, None)
    assert_equal(serialize(m2^), '{"f1":null,"f2":null,"f3":null}')


def test_deep_recursion():
    # Create 1 -> 2 -> 3
    var n3 = DeepNode(3, List[DeepNode]())
    var c2 = List[DeepNode]()
    c2.append(n3^)
    var n2 = DeepNode(2, c2^)
    var c1 = List[DeepNode]()
    c1.append(n2^)
    var n1 = DeepNode(1, c1^)

    assert_equal(
        serialize(n1^),
        '{"val":1,"children":[{"val":2,"children":[{"val":3,"children":[]}]}]}',
    )


def test_pretty_serialize():
    var f = Foo[45, 7.43](
        1,
        "something",
        10,
        Bar(20),
        23,
        [2.32, 5.345],
        [32, 42, 353],
        [False, True, True],
        {"a key": 1234},
        {},
        {},
        (1, 2, 3),
        {1, 2, 3},
        ArcPointer(1234),
        OwnedPointer(4321),
    )

    var writer = PrettySerializer()
    serialize(f, writer)
    var serialized = writer._data

    var expected = '{\n    "f": 1,\n    "s": "something",\n    "o": 10,\n    "bar": {\n        "b": 20\n    },\n    "i": 23,\n    "vec": [\n        2.32,\n        5.345\n    ],\n    "l": [\n        32,\n        42,\n        353\n    ],\n    "arr": [\n        false,\n        true,\n        true\n    ],\n    "dic": {\n        "a key": 1234\n    },\n    "il": 45,\n    "fl": 7.43,\n    "tup": [\n        1,\n        2,\n        3\n    ],\n    "set": [\n        1,\n        2,\n        3\n    ],\n    "arc_ptr": 1234,\n    "owned_ptr": 4321\n}'

    assert_equal(serialized, expected)


def test_lazy():
    var s = "123.42"
    var l = LazyFloat[origin_of(s)](s.as_bytes())


def main():
    TestSuite.discover_tests[__functions_in_module()]().run()
