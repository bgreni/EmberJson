"""Unit tests for the carry-scan transfer-function algebra.

Pure integer math — these run on every machine (no GPU needed), so the
scan correctness argument holds on CI too. The reference implementation
is the sequential carry semantics of the CPU scanners, built from the
same `_index/portable.mojo` primitives.
"""

from emberjson._gpu.scan import (
    IDENTITY_ELEM,
    apply_state,
    chunk_transfer_element,
    compose,
    constant_element,
)
from emberjson._index.portable import (
    escape_next,
    prefix_xor_portable,
    structurals_from_masks,
)
from std.testing import *
from std.testing.prop.strategy import Rng


struct _Masks(Copyable, Movable):
    var backslash: UInt64
    var quote: UInt64
    var op: UInt64
    var ws: UInt64

    def __init__(out self, mut rng: Rng) raises:
        # Density-varied random masks; ensure disjoint-ish classes like
        # real classification (a byte has one class) by masking overlaps.
        self.backslash = rng.rand_scalar[DType.uint64]()
        self.quote = rng.rand_scalar[DType.uint64]() & ~self.backslash
        self.op = (
            rng.rand_scalar[DType.uint64]() & ~self.backslash & ~self.quote
        )
        self.ws = (
            rng.rand_scalar[DType.uint64]()
            & ~self.backslash
            & ~self.quote
            & ~self.op
        )


def _ref_step(state: UInt8, m: _Masks, valid: UInt64) -> UInt8:
    """Sequential reference: one chunk of the CPU scanners' carry
    evolution for input state (e = bit0, p = bit1)."""
    var e_in = UInt64(state & 1)
    var p_in = UInt64((state >> 1) & 1)
    var r = escape_next(m.backslash, e_in)
    var escaped = r[0]
    var e_out = r[1]
    var rq = m.quote & ~escaped
    var in_string = prefix_xor_portable(rq) ^ (0 - p_in)
    var p_out = (in_string >> 63) & 1
    var sc = structurals_from_masks(m.op, m.ws, rq, in_string, 0, valid)[1]
    return UInt8(e_out | p_out << 1 | sc << 2)


def test_left_identity() raises:
    var rng = Rng(seed=101)
    for _ in range(200):
        var m = _Masks(rng)
        var x = chunk_transfer_element(
            m.backslash, m.quote, m.op, m.ws, UInt64.MAX
        )
        assert_equal(compose(IDENTITY_ELEM, x), x)


def test_compose_associative() raises:
    var rng = Rng(seed=202)
    for _ in range(200):
        var a = chunk_transfer_element(
            _Masks(rng).backslash,
            _Masks(rng).quote,
            _Masks(rng).op,
            _Masks(rng).ws,
            UInt64.MAX,
        )
        var mb = _Masks(rng)
        var b = chunk_transfer_element(
            mb.backslash, mb.quote, mb.op, mb.ws, UInt64.MAX
        )
        var mc = _Masks(rng)
        var c = chunk_transfer_element(
            mc.backslash, mc.quote, mc.op, mc.ws, UInt64.MAX
        )
        assert_equal(compose(compose(a, b), c), compose(a, compose(b, c)))


def test_element_matches_sequential_reference() raises:
    var rng = Rng(seed=303)
    for _ in range(500):
        var m = _Masks(rng)
        # Exercise partial-chunk valid masks too (final chunk of a
        # segment), plus the all-valid fast case.
        var valid = UInt64.MAX
        if rng.rand_int(min=0, max=3) == 0:
            var rem = rng.rand_int(min=1, max=63)
            valid = (UInt64(1) << UInt64(rem)) - 1
        var elem = chunk_transfer_element(
            m.backslash, m.quote, m.op, m.ws, valid
        )
        for state in range(4):
            assert_equal(
                apply_state(UInt8(state), elem),
                _ref_step(UInt8(state), m, valid),
                "state " + String(state),
            )


def test_scan_equals_sequential() raises:
    """The real scan property: composing a prefix of chunk elements and
    applying the initial state equals stepping the sequential scanners
    chunk by chunk."""
    var rng = Rng(seed=404)
    for _ in range(20):
        var n = rng.rand_int(min=1, max=300)
        var seq_state: UInt8 = 0  # (e=0, p=0) initial, like the scanners
        var prefix: UInt16 = IDENTITY_ELEM
        for i in range(n):
            var m = _Masks(rng)
            # Carry-in for chunk i from the composed exclusive prefix
            # must equal the sequentially evolved state.
            assert_equal(
                apply_state(0, prefix) & 3,
                seq_state & 3,
                "carry-in @chunk " + String(i),
            )
            # sc of the applied prefix is the previous chunk's scalar
            # bit; sequential tracker carries it identically.
            assert_equal(
                apply_state(0, prefix) >> 2,
                seq_state >> 2,
                "scalar carry @chunk " + String(i),
            )
            var elem = chunk_transfer_element(
                m.backslash, m.quote, m.op, m.ws, UInt64.MAX
            )
            seq_state = _ref_step(seq_state & 3, m, UInt64.MAX)
            prefix = compose(prefix, elem)


def test_constant_element_absorbs() raises:
    """Segment-reset property: composing anything before a constant
    element yields the constant — and scans through it behave as if the
    state machine restarted."""
    var rng = Rng(seed=505)
    for _ in range(200):
        var m = _Masks(rng)
        var x = chunk_transfer_element(
            m.backslash, m.quote, m.op, m.ws, UInt64.MAX
        )
        var mh = _Masks(rng)
        var head = chunk_transfer_element(
            mh.backslash, mh.quote, mh.op, mh.ws, UInt64.MAX
        )
        var const_head = constant_element(apply_state(0, head))
        # Absorption: anything before the head is forgotten.
        assert_equal(compose(x, const_head), const_head)
        # The constant's output equals the head chunk evaluated from the
        # reset state.
        for state in range(4):
            assert_equal(
                apply_state(UInt8(state), const_head),
                _ref_step(0, mh, UInt64.MAX),
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
