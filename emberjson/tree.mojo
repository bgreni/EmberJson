from .value import Value
from memory import UnsafePointer
from os import abort


@value
struct TreeNode:
    var data: Value
    var key: String
    var left: UnsafePointer[Self]
    var right: UnsafePointer[Self]
    var parent: UnsafePointer[Self]

    fn __init__(out self, owned key: String, owned data: Value):
        self.data = data^
        self.key = key^
        self.left = UnsafePointer[Self]()
        self.right = UnsafePointer[Self]()
        self.parent = UnsafePointer[Self]()

    @always_inline
    fn __eq__(self, other: Self) -> Bool:
        return self.key == other.key

    @always_inline
    fn __lt__(self, other: Self) -> Bool:
        return self.key < other.key

    @always_inline
    fn __gt__(self, other: Self) -> Bool:
        return self.key > other.key

    @always_inline
    fn __str__(self) -> String:
        return String.write(self)

    fn __repr__(self) -> String:
        var out = String()
        out.write("TreeNode(", self.key, ", ", self.data, ")")
        return out

    @always_inline
    fn write_to[W: Writer](self, mut writer: W):
        writer.write('"', self.key, '"', ":", self.data)

    @staticmethod
    fn make_ptr(owned key: String, owned data: Value, out p: UnsafePointer[Self]):
        p = UnsafePointer[Self].alloc(1)
        p.init_pointee_move(TreeNode(key^, data^))


@value
struct _TreeIter:
    var curr: UnsafePointer[TreeNode]
    var seen: Int
    var total: Int

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(mut self, out p: UnsafePointer[TreeNode, mut=False]):
        self.seen += 1
        p = self.curr
        self.curr = _get_next(self.curr)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.seen < self.total

    @always_inline
    fn __len__(self) -> Int:
        return self.total


@value
struct _TreeKeyIter:
    var curr: UnsafePointer[TreeNode]
    var seen: Int
    var total: Int

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(mut self, out p: UnsafePointer[String, mut=False]):
        self.seen += 1
        p = UnsafePointer.address_of(self.curr[].key)
        self.curr = _get_next(self.curr)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.seen < self.total

    @always_inline
    fn __len__(self) -> Int:
        return self.total


@value
struct _TreeValueIter:
    var curr: UnsafePointer[TreeNode]
    var seen: Int
    var total: Int

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(mut self, out p: UnsafePointer[Value, mut=False]):
        self.seen += 1
        p = UnsafePointer.address_of(self.curr[].data)
        self.curr = _get_next(self.curr)

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.seen < self.total

    @always_inline
    fn __len__(self) -> Int:
        return self.total


struct Tree(CollectionElement, Sized, ExplicitlyCopyable):
    alias NodePtr = UnsafePointer[TreeNode]
    var root: Self.NodePtr
    var size: UInt

    fn __init__(out self):
        self.root = Self.NodePtr()
        self.size = 0

    fn __copyinit__(out self, other: Self):
        self = self.__init__()
        for node in other:
            self.insert(TreeNode.make_ptr(node[].key, node[].data))

    fn copy(self) -> Self:
        return self

    fn __moveinit__(out self, owned other: Self):
        self.root = other.root
        self.size = other.size
        other.root = Self.NodePtr()
        other.size = 0

    @always_inline
    fn __iter__(self) -> _TreeIter:
        return _TreeIter(self.get_first(), 0, self.size)

    @always_inline
    fn keys(self) -> _TreeKeyIter:
        return _TreeKeyIter(self.get_first(), 0, self.size)

    @always_inline
    fn items(self) -> _TreeIter:
        return _TreeIter(self.get_first(), 0, self.size)

    @always_inline
    fn values(self) -> _TreeValueIter:
        return _TreeValueIter(self.get_first(), 0, self.size)

    @always_inline
    fn __len__(self) -> Int:
        return self.size

    fn __del__(owned self):
        fn do_del(node: Self.NodePtr):
            if node:
                node.destroy_pointee()
                node.free()

        for_each[do_del](self.root)

    fn get_first(self) -> Self.NodePtr:
        if not self.root:
            return self.root

        return _get_left_most(self.root)

    fn insert(mut self, node: Self.NodePtr):
        self.size += 1
        if not self.root:
            self.root = node
            return

        var parent = Self.NodePtr()
        var curr = self.root

        while curr:
            parent = curr
            if curr[] > node[]:
                curr = curr[].left
            elif curr[] < node[]:
                curr = curr[].right
            else:
                # we didn't actually insert a new element
                self.size -= 1
                curr[].data = node[].data
                return

        if parent[] > node[]:
            node[].parent = parent
            parent[].left = node
        else:
            node[].parent = parent
            parent[].right = node

    @always_inline
    fn insert(mut self, owned key: String, owned data: Value):
        self.insert(TreeNode.make_ptr(key^, data^))

    fn write_to[W: Writer](self, mut writer: W):
        writer.write("{")
        var written = 0
        self.write_nodes(writer, self.root, written)
        writer.write("}")

    @always_inline
    fn find(self, key: String) -> Self.NodePtr:
        return _find(self.root, key)

    fn __getitem__(ref self, key: String) raises -> ref [self] Value:
        var node = self.find(key)
        if not node:
            raise Error("Key error")
        return node[].data

    @always_inline
    fn __setitem__(mut self, owned key: String, owned data: Value):
        self.insert(key^, data^)

    @always_inline
    fn __contains__(self, key: String) -> Bool:
        return Bool(self.find(key))

    fn write_nodes[W: Writer](self, mut writer: W, node: Self.NodePtr, mut written: Int):
        if not node:
            return

        self.write_nodes(writer, node[].left, written)

        writer.write(node[])
        if written < self.size - 1:
            writer.write(",")
        written += 1

        self.write_nodes(writer, node[].right, written)

    @always_inline
    fn __str__(self) -> String:
        return String.write(self)


########################################################################
# Utilities
########################################################################


fn for_each[visit: fn (UnsafePointer[TreeNode])](node: UnsafePointer[TreeNode]):
    if not node:
        return
    for_each[visit](node[].left)
    visit(node)
    for_each[visit](node[].right)


fn _find(node: UnsafePointer[TreeNode], key: String) -> __type_of(node):
    if not node or node[].key == key:
        return node

    if node[].key < key:
        return _find(node[].right, key)
    return _find(node[].left, key)


fn _get_left_most(owned node: UnsafePointer[TreeNode]) -> __type_of(node):
    while node[].left:
        node = node[].left
    return node


fn _get_next(owned node: UnsafePointer[TreeNode]) -> __type_of(node):
    if node[].right:
        return _get_left_most(node[].right)
    while node[].parent and node == node[].parent[].right:
        node = node[].parent
    return node[].parent
