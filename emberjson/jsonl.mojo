from std.pathlib import Path
from std.collections import Span
from std.memory import unsafe_memset, unsafe_memcpy
from .constants import `\n`
from std.os import PathLike
from emberjson import Value


struct _ReadBuffer(Movable, Sized):
    comptime BUFFER_SIZE = 4096
    var buf: Array[Byte, Self.BUFFER_SIZE]
    var length: Int

    def __init__(out self):
        self.buf = Array[Byte, Self.BUFFER_SIZE](fill=0)
        self.length = 0

    @always_inline
    def ptr(ref self) -> Pointer[Byte, origin=origin_of(self.buf)]:
        return self.buf.unsafe_ptr()

    def index(self, b: Byte) -> Int:
        for i in range(self.length):
            if self.buf[i] == b:
                return i

        return -1

    def clear(mut self, n: Int):
        self.length -= n
        var p = self.ptr()
        for i in range(self.length):
            p[unsafe_offset=i] = p[unsafe_offset=i + n]
        unsafe_memset(
            p.unsafe_offset(self.length), 0, Self.BUFFER_SIZE - self.length
        )

    def clear(mut self):
        unsafe_memset(self.ptr(), 0, Self.BUFFER_SIZE)
        self.length = 0

    def drain_into(mut self, mut line: List[Byte], n: Int, skip: Int = 0):
        """Moves the first `n` bytes onto `line`, dropping `skip` more."""
        line.extend(Span(unsafe_ptr=self.ptr(), length=n))
        self.clear(n + skip)

    def __len__(self) -> Int:
        return self.length


struct JSONLinesIter(Iterator):
    comptime Element = Value

    var f: FileHandle
    var next_object: Value
    var read_buf: _ReadBuffer
    var first: Bool
    var read_error: Optional[String]

    def __init__(out self, var file: FileHandle):
        self.f = file^
        self.next_object = Value()
        self.read_buf = _ReadBuffer()
        self.first = True
        self.read_error = None

    def __next__(mut self, out j: Value) raises StopIteration:
        # Loop so blank lines and malformed lines don't truncate the stream:
        # only true EOF (signalled by `_read_until_newline` raising) ends
        # iteration. Blank lines return an empty buffer; malformed lines fail
        # to parse — both are skipped so subsequent valid records still surface.
        while True:
            var line: List[Byte]
            try:
                line = self._read_until_newline()
            except e:
                raise StopIteration()

            if len(line) == 0:
                continue

            if self.first:
                self.first = False
                if (
                    len(line) >= 3
                    and line[0] == 0xEF
                    and line[1] == 0xBB
                    and line[2] == 0xBF
                ):
                    var stripped = List[Byte](length=len(line) - 3, fill=0)
                    unsafe_memcpy(
                        dest=stripped.unsafe_ptr(),
                        src=line.unsafe_ptr().unsafe_offset(3),
                        count=len(line) - 3,
                    )
                    line = stripped^

            try:
                j = Value(
                    parse_bytes=Span(
                        unsafe_ptr=line.unsafe_ptr(), length=len(line)
                    )
                )
                return
            except e:
                continue

    def __iter__(var self) -> Self:
        return self^

    def collect(deinit self, out l: List[Value]) raises:
        l = List[Value]()
        while True:
            try:
                l.append(self.__next__())
            except StopIteration:
                break
        if self.read_error:
            raise Error(self.read_error.value())

    def _read_until_newline(mut self) raises -> List[Byte]:
        var line = List[Byte]()
        while True:
            var newline_ind = self.read_buf.index(`\n`)
            if newline_ind != -1:
                self.read_buf.drain_into(line, newline_ind, skip=1)
                return line^

            # No newline buffered: bank what we have, then refill.
            self.read_buf.drain_into(line, len(self.read_buf))
            var read: Int
            try:
                read = self.f.read(
                    Span(
                        unsafe_ptr=self.read_buf.ptr(),
                        length=self.read_buf.BUFFER_SIZE,
                    )
                )
            except e:
                self.read_error = String(e)
                raise Error("EOF")

            if read <= 0:
                # Distinguish a true EOF from a blank line. A blank line
                # returns an empty buffer via the `\n` branch above; only
                # here, with nothing read and no accumulated line content,
                # are we really past the end of the file.
                if len(line) == 0:
                    raise Error("EOF")
                return line^
            self.read_buf.length = read


def read_lines(p: Some[PathLike]) raises -> JSONLinesIter:
    """Opens `p` and returns an iterator over its JSON Lines records.

    Note:
        A `for` loop over the returned iterator cannot surface an I/O read
        error: the `Iterator` protocol only allows `__next__` to raise
        `StopIteration`, so a failed read looks identical to a clean
        end-of-file. Use `collect()`, which re-raises any recorded error
        after exhausting the iterator, or inspect the iterator's
        `read_error` field directly.
    """
    if Path(p.__fspath__()).is_dir():
        raise Error("read_lines: '", p.__fspath__(), "' is a directory")
    return JSONLinesIter(open(p, "r"))


def write_lines(p: Path, lines: List[Value]) raises:
    with open(p, "w") as f:
        for i in range(len(lines)):
            f.write(lines[i])
            f.write("\n")
