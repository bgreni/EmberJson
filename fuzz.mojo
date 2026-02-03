from emberjson import parse, Array, Object, Value, Null, JSON
from emberjson.utils import write_escaped_string
from utils.numerics import isinf
from time import monotonic
from testing import assert_equal
from testing.prop.strategy import Strategy, Rng
from testing.prop import PropTest, PropTestConfig
from benchmark import keep
from time import perf_counter_ns
from sys.param_env import is_defined


@fieldwise_init
struct JsonStringStrategy(Movable, Strategy):
    comptime Value = String

    fn value(self, mut rng: Rng) raises -> Self.Value:
        var j: JSON

        if coin_flip(rng):
            j = self.gen_object(rng, 0)
        else:
            j = self.gen_array(rng, 0)

        return String(j)

    fn gen_value(self, mut rng: Rng, depth: Int) raises -> Value:
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

    fn gen_string(self, mut rng: Rng) raises -> String:
        # TODO: Fix string strategy
        var strat = String.strategy(unicode=False, only_printable=True)
        return strat.value(rng)

    fn gen_array(self, mut rng: Rng, depth: Int) raises -> Array:
        var arr = Array()
        var l = rng.rand_int(min=0, max=20 // max(depth, 1))
        arr.reserve(l)
        for _ in range(l):
            arr.append(self.gen_value(rng, depth))
        return arr^

    fn gen_object(self, mut rng: Rng, depth: Int) raises -> Object:
        var ob = Object()
        var l = rng.rand_int(min=0, max=20 // max(depth, 1))
        for _ in range(l):
            ob[self.gen_string(rng)] = self.gen_value(rng, depth)
        return ob^


fn coin_flip(mut rng: Rng) raises -> Bool:
    return rng.rand_bool()


fn main() raises:
    @parameter
    if is_defined["GEN_JSONL"]():
        var rng = Rng(seed=Int(perf_counter_ns()))
        var strat = JsonStringStrategy()

        with open("./bench_data/big_lines_complex.jsonl", "w") as f:
            for _ in range(1_000):
                f.write(strat.value(rng), "\n")

    else:
        print("Running fuzzy tests...")
        var iters = 100

        @parameter
        fn test_parse(s: String) raises:
            var rng = Rng(seed=Int(perf_counter_ns()))
            var j: JSON = {}
            if iters % 4 == 0:
                var start = rng.rand_int(min=0, max=len(s))
                var end = rng.rand_int(min=start, max=len(s))
                var corrupted = s[start:end]
                try:
                    j = parse(corrupted)
                except:
                    # Main thing is we don't want this to crash.
                    # But don't enforce failure on the off chance this slicing happens to
                    # produce valid json.
                    pass
            else:
                j = parse(s)
            iters -= 1
            keep(j)

        var test = PropTest(config=PropTestConfig(runs=iters))
        test.test[test_parse](JsonStringStrategy())
        print("Test passed!")
