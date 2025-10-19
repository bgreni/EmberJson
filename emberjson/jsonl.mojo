from pathlib import Path
from .json import JSON
from memory import ArcPointer, memset
from .constants import `\n`, `\r`


struct _ReadBuffer(Copyable, Movable, Sized, Stringable, Writable):
    alias BUFFER_SIZE = 4096
    var buf: InlineArray[Byte, Self.BUFFER_SIZE]
    var length: UInt

    fn __init__(out self):
        self.buf = InlineArray[Byte, Self.BUFFER_SIZE](fill=0)
        self.length = 0

    fn ptr(mut self) -> UnsafePointer[Byte, origin = origin_of(self.buf)]:
        return self.buf.unsafe_ptr()

    fn index(self, b: Byte) -> Int:
        for i in range(self.length):
            if self.buf[i] == b:
                return i

        return -1

    fn clear(mut self, n: UInt):
        self.length -= n

        for i in range(0, self.length):
            self.buf[i] = self.buf[i + n]

        memset(self.ptr() + self.length, 0, Self.BUFFER_SIZE - self.length)

    fn clear(mut self):
        memset(self.ptr(), 0, Self.BUFFER_SIZE)
        self.length = 0

    fn __str__(self) -> String:
        return String(bytes=Span(ptr=self.buf.unsafe_ptr(), length=self.length))

    fn write_to(self, mut writer: Some[Writer]):
        writer.write(String(self))

    fn __len__(self) -> Int:
        return self.length


struct JSONLinesIter(Movable):
    alias Element = JSON

    var f: FileHandle
    var next_object: JSON
    var read_buf: _ReadBuffer

    fn __init__(out self, var file: FileHandle):
        self.f = file^
        self.next_object = JSON()
        self.read_buf = _ReadBuffer()

    fn __has_next__(mut self) -> Bool:
        try:
            var line = self._read_until_newline()
            if not line:
                return False
            self.next_object = JSON(parse_bytes=line.as_bytes())
            return True
        except e:
            print(e)
        return False

    fn __next__(mut self, out j: JSON):
        j = self.next_object^
        self.next_object = JSON()

    fn __iter__(var self) -> Self:
        return self^

    fn _read_until_newline(mut self) raises -> String:
        ref file = self.f

        var line = String()

        @parameter
        fn consume_line(ind: Int) raises -> String:
            line += StringSlice(from_utf8=self.read_buf.buf)[0:ind]
            self.read_buf.clear(UInt(ind + 1))

            return line

        var newline_ind = self.read_buf.index(`\n`)
        if newline_ind != -1:
            return consume_line(newline_ind)

        while True:
            buf_span = Span(
                ptr=self.read_buf.ptr() + self.read_buf.length,
                length=UInt(self.read_buf.BUFFER_SIZE - self.read_buf.length),
            )
            var read = file.read(buf_span)
            self.read_buf.length += UInt(read)

            if read <= 0:
                if len(self.read_buf) != 0:
                    line += StringSlice(from_utf8=self.read_buf.buf)[
                        0 : len(self.read_buf)
                    ]
                    self.read_buf.clear()
                return line

            newline_ind = self.read_buf.index(`\n`)

            if newline_ind != -1:
                return consume_line(newline_ind)
            else:
                line += StringSlice(from_utf8=self.read_buf.buf)
                self.read_buf.clear()


fn read_lines(p: Path) raises -> JSONLinesIter:
    return JSONLinesIter(open(p, "r"))


fn write_lines(p: Path, lines: List[JSON]) raises:
    with open(p, "w") as f:
        for i in range(len(lines)):
            f.write(lines[i])
            if i < len(lines) - 1:
                f.write("\n")
