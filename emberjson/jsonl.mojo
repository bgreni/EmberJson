from std.pathlib import Path
from .json import JSON
from std.memory import ArcPointer, memset, Span, memcpy
from .constants import `\n`, `\r`
from std.os import PathLike
from .simd import SIMD8_WIDTH
from std.bit import count_leading_zeros
from std.memory.unsafe import pack_bits


struct _ReadBuffer(Copyable, Movable, Sized, Writable):
    comptime BUFFER_SIZE = 4096
    var buf: InlineArray[Byte, Self.BUFFER_SIZE]
    var length: Int

    def __init__(out self):
        self.buf = InlineArray[Byte, Self.BUFFER_SIZE](fill=0)
        self.length = 0

    @always_inline
    def ptr(ref self) -> UnsafePointer[Byte, origin=origin_of(self.buf)]:
        return self.buf.unsafe_ptr()

    def index(self, b: Byte) -> Int:
        for i in range(self.length):
            if self.buf[i] == b:
                return i

        return -1

    def clear(mut self, n: Int):
        self.length -= n

        memcpy(
            dest=self.ptr(),
            src=self.ptr() + n,
            count=self.length,
        )

        memset(self.ptr() + self.length, 0, Self.BUFFER_SIZE - self.length)

    def clear(mut self):
        memset(self.ptr(), 0, Self.BUFFER_SIZE)
        self.length = 0

    def write_to(self, mut writer: Some[Writer]):
        writer.write(StringSlice(ptr=self.ptr(), length=self.length))

    def __len__(self) -> Int:
        return self.length


struct JSONLinesIter(Iterator):
    comptime Element = JSON

    var f: FileHandle
    var next_object: JSON
    var read_buf: _ReadBuffer

    def __init__(out self, var file: FileHandle):
        self.f = file^
        self.next_object = JSON()
        self.read_buf = _ReadBuffer()

    def __next__(mut self, out j: JSON) raises StopIteration:
        var line: List[Byte]
        try:
            line = self._read_until_newline()
        except e:
            raise StopIteration()

        try:
            j = JSON(parse_bytes=Span(ptr=line.unsafe_ptr(), length=len(line)))
        except e:
            raise StopIteration()

    def __iter__(var self) -> Self:
        return self^

    def collect(deinit self, out l: List[Value]) raises:
        l = List[Value]()
        while True:
            try:
                l.append(self.__next__())
            except StopIteration:
                break

    def _read_until_newline(mut self) raises -> List[Byte]:
        ref file = self.f

        var line = List[Byte]()

        var newline_ind = self.read_buf.index(`\n`)
        if newline_ind != -1:
            var p = self.read_buf.ptr()
            var old_len = len(line)
            line.resize(old_len + newline_ind, 0)
            memcpy(dest=line.unsafe_ptr() + old_len, src=p, count=newline_ind)
            self.read_buf.clear(newline_ind + 1)
            return line^

        while True:
            buf_span = Span(
                ptr=self.read_buf.ptr() + self.read_buf.length,
                length=self.read_buf.BUFFER_SIZE - self.read_buf.length,
            )
            var read = file.read(buf_span)
            self.read_buf.length += read

            if read <= 0:
                if len(self.read_buf) != 0:
                    var p = self.read_buf.ptr()
                    var old_len = len(line)
                    var count = len(self.read_buf)
                    line.resize(old_len + count, 0)
                    memcpy(dest=line.unsafe_ptr() + old_len, src=p, count=count)
                    self.read_buf.clear()
                return line^

            newline_ind = self.read_buf.index(`\n`)

            if newline_ind != -1:
                var p = self.read_buf.ptr()
                var old_len = len(line)
                line.resize(old_len + newline_ind, 0)
                memcpy(
                    dest=line.unsafe_ptr() + old_len, src=p, count=newline_ind
                )
                self.read_buf.clear(newline_ind + 1)
                return line^
            else:
                var p = self.read_buf.ptr()
                var old_len = len(line)
                var count = len(self.read_buf)
                line.resize(old_len + count, 0)
                memcpy(dest=line.unsafe_ptr() + old_len, src=p, count=count)
                self.read_buf.clear()


def read_lines(p: Some[PathLike]) raises -> JSONLinesIter:
    return JSONLinesIter(open(p, "r"))


def write_lines(p: Path, lines: List[JSON]) raises:
    with open(p, "w") as f:
        for i in range(len(lines)):
            f.write(lines[i])
            if i < len(lines) - 1:
                f.write("\n")
