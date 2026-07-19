from emberjson import (
    parse,
    to_string,
    Array,
    GpuSession,
    Object,
    Value,
    Null,
    JSON,
    Parser,
    ParseOptions,
    Document,
)
from std.sys import has_accelerator
from emberjson._deserialize.tape import TapeSink, _Arena, parse_document_tape
from emberjson._deserialize.tape_indexed import parse_document_tape_indexed
from emberjson.utils import write_escaped_string, PaddedBuffer
from std.utils.numerics import isinf
from std.time import monotonic
from std.testing import assert_equal
from std.testing.prop.strategy import Strategy, Rng
from std.testing.prop.strategy.string_strategy import _StringStrategy
from std.testing.prop import PropTest, PropTestConfig
from std.benchmark import keep
from std.time import perf_counter_ns
from std.sys import is_defined
from std.testing import assert_equal


@fieldwise_init
struct JsonStringStrategy(Movable, Strategy):
    comptime Value = String

    def value(self, mut rng: Rng) raises -> Self.Value:
        var j: Value

        if coin_flip(rng):
            j = self.gen_object(rng, 0)
        else:
            j = self.gen_array(rng, 0)

        return String(j)

    def gen_value(self, mut rng: Rng, depth: Int) raises -> Value:
        var max_choice = 7  # 0-7
        if depth > 5:
            max_choice = 5  # 0-5 (Scalars: Null, Int, UInt, Str, Bool, Float)

        var a = rng.rand_int(min=0, max=max_choice)

        if a == 0:
            return Null()
        elif a == 1:
            return rng.rand_scalar[DType.int64]()
        elif a == 2:
            return rng.rand_scalar[DType.uint64]()
        elif a == 3:
            return self.gen_string(rng)
        elif a == 4:
            return coin_flip(rng)
        elif a == 5:
            return rng.rand_scalar[DType.float64]()
        elif a == 6:
            return self.gen_array(rng, depth + 1)
        elif a == 7:
            return self.gen_object(rng, depth + 1)
        else:
            raise Error("Invalid choice")

    def gen_string(self, mut rng: Rng) raises -> String:
        # The stdlib string strategy. The pinned nightly ships the strategy
        # struct but not yet the `String.strategy(...)` extension sugar;
        # switch to `String.strategy(unicode=False, only_printable=True)`
        # once the toolchain resolves it.
        var strat = _StringStrategy(
            min_len=0, max_len=20, unicode=False, only_printable=True
        )
        return strat.value(rng)

    def gen_array(self, mut rng: Rng, depth: Int) raises -> Array:
        var arr = Array()
        var l = rng.rand_int(min=0, max=20 // max(depth, 1))
        arr.reserve(l)
        for _ in range(l):
            arr.append(self.gen_value(rng, depth))
        return arr^

    def gen_object(self, mut rng: Rng, depth: Int) raises -> Object:
        var ob = Object()
        var l = rng.rand_int(min=0, max=20 // max(depth, 1))
        for _ in range(l):
            ob[self.gen_string(rng)] = self.gen_value(rng, depth)
        return ob^


def coin_flip(mut rng: Rng) raises -> Bool:
    return rng.rand_bool()


def _tape_doc[indexed: Bool](s: StringSlice) raises -> Document:
    """Builds a Document through one specific tape engine (padding even
    tiny inputs so both engines run on every fuzz case)."""
    var sink = TapeSink(
        tape_capacity=s.byte_length() // 3 + 8,
        strings_capacity=s.byte_length() // 2 + 16,
    )
    var buf = PaddedBuffer(s.as_bytes())
    var p = Parser[options=ParseOptions()._padded()](padded=buf)
    comptime if indexed:
        parse_document_tape_indexed(p, sink)
    else:
        parse_document_tape(p, sink)
    var tape = List[UInt64]()
    var strings = _Arena(capacity=0)
    swap(tape, sink.tape)
    swap(strings, sink.strings)
    return Document(tape^, strings^, False)


def check_engines_agree(s: StringSlice) raises:
    """Differential oracle: the byte-walk and index-driven tape engines
    must return the same accept/reject verdict on any input and, on
    accept, byte-identical serialization."""
    var ok_walk: Bool
    var out_walk = String()
    try:
        var d = _tape_doc[False](s)
        out_walk = to_string(d)
        ok_walk = True
    except:
        ok_walk = False

    var ok_idx: Bool
    var out_idx = String()
    try:
        var d = _tape_doc[True](s)
        out_idx = to_string(d)
        ok_idx = True
    except:
        ok_idx = False

    assert_equal(ok_walk, ok_idx)
    if ok_walk:
        assert_equal(out_walk, out_idx)

    # Third engine on GPU machines: the GPU stage-1 pipeline feeding the
    # same stage-2 walk must agree with both CPU engines. validate_utf8
    # is off to match the builders-only comparison above (the CPU
    # engines here run without the UTF-8 pre-check). Transient session
    # per case: construction is sub-millisecond and keeps this hermetic.
    comptime if has_accelerator():
        var ok_gpu: Bool
        var out_gpu = String()
        try:
            var session = GpuSession()
            var d = session.parse_document[ParseOptions(validate_utf8=False)](s)
            out_gpu = to_string(d)
            ok_gpu = True
        except:
            ok_gpu = False
        assert_equal(ok_walk, ok_gpu, "gpu engine verdict diverged")
        if ok_walk:
            assert_equal(out_walk, out_gpu)
        # Fourth engine: full device stage-2 materialization + host
        # grammar walk must agree as well.
        var ok_s2: Bool
        var out_s2 = String()
        try:
            var session2 = GpuSession()
            var d2 = session2.parse_document[
                ParseOptions(validate_utf8=False), True
            ](s)
            out_s2 = to_string(d2)
            ok_s2 = True
        except:
            ok_s2 = False
        assert_equal(ok_walk, ok_s2, "gpu stage-2 engine verdict diverged")
        if ok_walk:
            assert_equal(out_walk, out_s2)


def check_jsonl_engines_agree(a: StringSlice, b: StringSlice) raises:
    """Batch differential: joining docs (including corrupt ones) with
    newlines, the GPU batch parser must match the per-line CPU oracle
    (try-parse each line, skip failures) in count and serialization."""
    comptime if has_accelerator():
        comptime opts = ParseOptions(validate_utf8=False)
        var batch = String(a) + "\n" + String(b) + "\n\n" + String(a)

        var cpu = List[String]()
        var bytes = batch.as_bytes()
        var n = len(bytes)
        var line_start = 0
        var i = 0
        while i <= n:
            if i == n or bytes[i] == 0x0A:
                if i > line_start:
                    var line = StringSlice(
                        unsafe_from_utf8=Span(
                            ptr=bytes.unsafe_ptr() + line_start,
                            length=i - line_start,
                        )
                    )
                    try:
                        var sink = TapeSink(
                            tape_capacity=line.byte_length() // 3 + 8,
                            strings_capacity=line.byte_length() // 2 + 16,
                        )
                        var lbuf = PaddedBuffer(line.as_bytes())
                        var p = Parser[options=opts._padded()](padded=lbuf)
                        parse_document_tape_indexed(p, sink)
                        var tape = List[UInt64]()
                        var strings = _Arena(capacity=0)
                        swap(tape, sink.tape)
                        swap(strings, sink.strings)
                        cpu.append(to_string(Document(tape^, strings^, False)))
                    except:
                        pass
                line_start = i + 1
            i += 1

        var session = GpuSession()
        var gpu = session.parse_documents[opts](batch)
        assert_equal(len(gpu), len(cpu), "jsonl engine count diverged")
        for k in range(len(cpu)):
            assert_equal(to_string(gpu[k]), cpu[k])


def main() raises:
    comptime if is_defined["GEN_JSONL"]():
        var rng = Rng(seed=Int(perf_counter_ns()))
        var strat = JsonStringStrategy()

        with open("./bench_data/big_lines_complex.jsonl", "w") as f:
            for _ in range(1_000):
                f.write(strat.value(rng), "\n")

    else:
        print("Running fuzzy tests...")
        var iters = 100

        @parameter
        def test_parse(s: String) raises:
            var rng = Rng(seed=Int(perf_counter_ns()))
            var j: Value = {}
            if iters % 4 == 0:
                var start = rng.rand_int(min=0, max=s.byte_length())
                var end = rng.rand_int(min=start, max=s.byte_length())
                var corrupted = s[byte=start:end]
                try:
                    j = parse(corrupted)
                except:
                    # Main thing is we don't want this to crash.
                    # But don't enforce failure on the off chance this slicing happens to
                    # produce valid json.
                    pass
                # The two tape engines must agree even on garbage.
                check_engines_agree(corrupted)
                # And the batch engine must agree with the per-line
                # oracle on batches containing the garbage.
                check_jsonl_engines_agree(s, corrupted)
            else:
                j = parse(s)
                assert_equal(String(j), s)
                check_engines_agree(s)
            iters -= 1
            keep(j)

        var test = PropTest(config=PropTestConfig(runs=iters))
        test.test[test_parse](JsonStringStrategy())
        print("Test passed!")
