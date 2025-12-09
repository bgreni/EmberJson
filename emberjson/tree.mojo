from .value import Value
from memory import UnsafePointer
from os import abort


comptime TreeNodePtr = UnsafePointer[TreeNode, MutAnyOrigin]


struct TreeNode(Copyable, Movable, Representable, Stringable, Writable):
    var data: Value
    var key: String
    var left: UnsafePointer[Self, MutAnyOrigin]
    var right: UnsafePointer[Self, MutAnyOrigin]
    var parent: UnsafePointer[Self, MutAnyOrigin]

    fn __init__(out self, var key: String, var data: Value):
        self.data = data^
        self.key = key^
        self.left = UnsafePointer[Self, MutAnyOrigin]()
        self.right = UnsafePointer[Self, MutAnyOrigin]()
        self.parent = UnsafePointer[Self, MutAnyOrigin]()

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
        return String(self)

    fn __repr__(self) -> String:
        var out = String()
        out.write("TreeNode(", self.key, ", ", self.data, ")")
        return out

    @always_inline
    fn write_to(self, mut writer: Some[Writer]):
        writer.write('"', self.key, '"', ":", self.data)

    @staticmethod
    fn make_ptr(
        var key: String,
        var data: Value,
        out p: UnsafePointer[Self, MutAnyOrigin],
    ):
        p = alloc[Self](1)
        p.init_pointee_move(TreeNode(key^, data^))

    fn steal_data(mut self, mut other: Self):
        self.data = other.data^
        other.data = Value()


@fieldwise_init
@register_passable("trivial")
struct _TreeIter(Copyable, Movable, Sized):
    var curr: TreeNodePtr
    var seen: Int
    var total: Int

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(mut self) -> ref [self.curr[]] TreeNode:
        self.seen += 1
        ref p = self.curr[]
        self.curr = _get_next(self.curr)
        return p

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.seen < self.total

    @always_inline
    fn __len__(self) -> Int:
        return self.total


@fieldwise_init
@register_passable("trivial")
struct _TreeKeyIter(Copyable, Movable, Sized):
    var curr: TreeNodePtr
    var seen: Int
    var total: Int

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(mut self) -> ref [self.curr[].key] String:
        self.seen += 1
        ref p = self.curr[].key
        self.curr = _get_next(self.curr)
        return p

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.seen < self.total

    @always_inline
    fn __len__(self) -> Int:
        return self.total


@fieldwise_init
@register_passable("trivial")
struct _TreeValueIter(Copyable, Movable, Sized):
    var curr: TreeNodePtr
    var seen: Int
    var total: Int

    @always_inline
    fn __iter__(self) -> Self:
        return self

    @always_inline
    fn __next__(mut self) -> ref [self.curr[].data] Value:
        self.seen += 1
        ref p = self.curr[].data
        self.curr = _get_next(self.curr)
        return p

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.seen < self.total

    @always_inline
    fn __len__(self) -> Int:
        return self.total


struct Tree(Copyable, Movable, Sized, Stringable, Writable):
    comptime NodePtr = TreeNodePtr
    var root: Self.NodePtr
    var size: Int

    fn __init__(out self):
        self.root = Self.NodePtr()
        self.size = 0

    fn __copyinit__(out self, other: Self):
        self = Self()
        for node in other:
            self.insert(TreeNode.make_ptr(node.key, node.data.copy()))

    fn __moveinit__(out self, deinit other: Self):
        self.root = other.root
        self.size = other.size
        other.root = Self.NodePtr()
        _ = other.root

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

    fn __del__(deinit self):
        fn do_del(node: Self.NodePtr):
            if node:
                node.destroy_pointee()
                node.free()

        for_each[do_del](self.root)

    fn get_first(self) -> Self.NodePtr:
        if not self.root:
            return self.root

        return _get_left_most(self.root)

    fn insert(mut self, var node: Self.NodePtr):
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
                curr[].steal_data(node[])
                return

        if parent[] > node[]:
            node[].parent = parent
            parent[].left = node
        else:
            node[].parent = parent
            parent[].right = node

    @always_inline
    fn insert(mut self, var key: String, var data: Value):
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
            raise Error("Missing key error: ", key)
        return node[].data

    @always_inline
    fn __setitem__(mut self, var key: String, var data: Value):
        self.insert(key^, data^)

    @always_inline
    fn __contains__(self, key: String) -> Bool:
        return Bool(self.find(key))

    fn write_nodes(
        self, mut writer: Some[Writer], node: Self.NodePtr, mut written: Int
    ):
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
        return String(self)


########################################################################
# Utilities
########################################################################


fn for_each[visit: fn (TreeNodePtr)](node: TreeNodePtr):
    if not node:
        return
    for_each[visit](node[].left)
    visit(node)
    for_each[visit](node[].right)


fn _find(node: TreeNodePtr, key: String) -> type_of(node):
    if not node or node[].key == key:
        return node

    if node[].key < key:
        return _find(node[].right, key)
    return _find(node[].left, key)


fn _get_left_most(var node: TreeNodePtr) -> type_of(node):
    while node[].left:
        node = node[].left
    return node


fn _get_next(var node: TreeNodePtr) -> type_of(node):
    if node[].right:
        return _get_left_most(node[].right)
    while node[].parent and node == node[].parent[].right:
        node = node[].parent
    return node[].parent
