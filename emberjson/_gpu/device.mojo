"""GPU session management for the GPU parsing pipeline.

`GpuSession` owns the `DeviceContext` and, in later phases, the reusable
scratch buffers (input staging, mask arrays, positions) that amortize
allocation across parses. GPU entry points fail loud: on a machine with
no accelerator they raise `NO_ACCELERATOR_ERROR` rather than silently
falling back to the CPU engines.

Kernel launches are always wrapped in `comptime if has_accelerator()` so
CPU-only targets (e.g. linux-64 CI) never elaborate GPU codegen; the
host-side types compile everywhere.

Probed facts this module relies on (Apple M3 Pro, Metal backend):
  * u64 bit math (`pop_count`, `count_trailing_zeros`, shift-XOR
    prefix scans), `ptr.load[width=16]`, `SIMD.eq`, shared-memory
    `stack_allocation` + `barrier`, and `Atomic.fetch_add` all work.
  * `pack_bits` crashes the Metal shader compiler
    (XPC_ERROR_CONNECTION_INTERRUPTED at pipeline-state creation) — GPU
    mask extraction must use unrolled bit loops or SWAR-u64 instead.
  * Zero-copy aliasing (host-pointer `DeviceBuffer` wrap, direct
    `HostBuffer` kernel access) is not functional: kernel writes land in
    a device-side copy. Staging must use explicit `enqueue_copy`
    (pinned `HostBuffer` <-> `DeviceBuffer` works) or `map_to_host`.
"""

from std.bit import count_trailing_zeros
from std.gpu import global_idx
from std.gpu.host import DeviceBuffer, DeviceContext, HostBuffer
from std.math import ceildiv
from std.memory import memcpy, memset, pack_bits
from std.sys import has_accelerator
from layout import TileTensor, row_major

from emberjson._utf8 import is_valid_utf8

from emberjson._deserialize.parser import Parser, ParseOptions
from emberjson._deserialize.tape import TapeSink
from emberjson._deserialize.tape_indexed import _walk_tape_from_index
from emberjson._deserialize.tables import POWER_OF_FIVE_128
from emberjson.document import Document, _finish_document
from emberjson.utils import PaddedBuffer, lut
from .assemble import assemble_line
from .brackets import (
    BracketBuffers,
    depth_aggs_kernel,
    depth_block_kernel,
    depth_finalize_kernel,
    gather_pairs_kernel,
    hist_kernel,
    oc_compact_kernel,
    oc_count_kernel,
    pair_validate_kernel,
    sort_scatter_kernel,
    u32_scan_apply_kernel,
    u32_scan_block_kernel,
    MAX_BRACKET_DEPTH,
)
from .scan import scan_counts_kernel
from .stage1 import Stage1Buffers, run_stage1_pipeline
from .stage2 import (
    Stage2Buffers,
    line_bases_kernel,
    materialize_kernel,
    pair_scan_aggs_kernel,
    pair_scan_apply_kernel,
    pair_scan_block_kernel,
    tokenize_kernel,
)
from .stage1 import BLOCK
from .utf8 import run_utf8_validation, utf8_chunk_count

comptime NO_ACCELERATOR_ERROR = "emberjson.gpu: no accelerator available"


@always_inline
def _lower_bound(ptr: UnsafePointer[UInt32, _], n: Int, key: UInt32) -> Int:
    """First index whose value is >= key (positions are ascending)."""
    var lo = 0
    var hi = n
    while lo < hi:
        var mid = (lo + hi) // 2
        if ptr[mid] < key:
            lo = mid + 1
        else:
            hi = mid
    return lo


comptime _SMOKE_N = 1024
comptime _SMOKE_BLOCK = 256
comptime _smoke_layout = row_major[_SMOKE_N]()


def _smoke_kernel(
    outp: TileTensor[DType.uint32, type_of(_smoke_layout), MutAnyOrigin],
):
    comptime assert outp.flat_rank == 1
    var tid = global_idx.x
    if tid < _SMOKE_N:
        outp[tid] = rebind[outp.ElementType](UInt32(tid * 3 + 1))


struct GpuSession(Movable):
    """A reusable GPU parsing session.

    Owns the `DeviceContext`; later phases add growable scratch buffers
    so repeated parses reuse device memory. Not thread-safe.

    Raises on construction when no accelerator is available.
    """

    var ctx: DeviceContext
    # Reusable input staging: pinned host buffer (zero-copy aliasing does
    # not work on this toolchain — see module docstring) + device buffer,
    # both grown geometrically and never shrunk.
    var _staging: HostBuffer[DType.uint8]
    var _input: DeviceBuffer[DType.uint8]
    var _input_cap: Int
    var _err_flag: DeviceBuffer[DType.int32]
    var _s1: Stage1Buffers
    var _s2: Stage2Buffers
    var _br: BracketBuffers

    comptime _MIN_CAP = 4096

    def __init__(out self) raises:
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            self.ctx = DeviceContext()
            self._input_cap = Self._MIN_CAP
            self._staging = self.ctx.enqueue_create_host_buffer[DType.uint8](
                self._input_cap
            )
            self._input = self.ctx.enqueue_create_buffer[DType.uint8](
                self._input_cap
            )
            self._err_flag = self.ctx.enqueue_create_buffer[DType.int32](1)
            self._s1 = Stage1Buffers(self.ctx)
            var five = List[UInt64]()
            for i in range(1302):
                five.append(lut[POWER_OF_FIVE_128](i))
            self._s2 = Stage2Buffers(self.ctx, five.unsafe_ptr())
            self._br = BracketBuffers(self.ctx)
            self.ctx.synchronize()

    def _stage_input(mut self, bytes: Span[Byte, _], window: Int) raises:
        """Copies `bytes` + zero padding through `window` bytes into the
        staging buffer and enqueues the upload to `_input`.

        `window` is the number of device bytes the kernels will read
        (a multiple of 64, >= len(bytes))."""
        var n = len(bytes)
        if self._input_cap < window:
            var new_cap = max(window, self._input_cap * 2)
            self._staging = self.ctx.enqueue_create_host_buffer[DType.uint8](
                new_cap
            )
            self._input = self.ctx.enqueue_create_buffer[DType.uint8](new_cap)
            self.ctx.synchronize()
            self._input_cap = new_cap
        var hptr = self._staging.unsafe_ptr()
        if n > 0:
            memcpy(dest=hptr, src=bytes.unsafe_ptr(), count=n)
        memset(hptr + n, 0, window - n)
        # Partial upload: only `window` bytes, not the buffer's whole
        # capacity (which may be much larger after a big parse). The
        # ptr-ptr-size overload is the only partial-copy form.
        self.ctx.enqueue_copy(
            dst_ptr=self._input.unsafe_ptr(),
            src_ptr=hptr,
            size=window,
        )

    def is_valid_utf8(mut self, s: StringSlice) raises -> Bool:
        """Validates `s` as UTF-8 (RFC 3629) on the GPU.

        Verdict-identical to the CPU `emberjson.is_valid_utf8`. Raises
        when no accelerator is available — never falls back to the CPU.
        The crossover vs the ~20-30 GB/s CPU validator is large (several
        MB); prefer the CPU validator for small inputs.
        """
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            var bytes = s.as_bytes()
            var num_chunks = utf8_chunk_count(len(bytes))
            self._stage_input(bytes, num_chunks * 64)
            self._err_flag.enqueue_fill(0)
            run_utf8_validation(
                self.ctx, self._input, self._err_flag, num_chunks
            )
            self.ctx.synchronize()
            with self._err_flag.map_to_host() as h:
                return h[0] == 0

    def _run_index_segmented[
        options: ParseOptions
    ](
        mut self,
        bytes: Span[Byte, _],
        chunk_off: List[UInt32],
        starts: List[UInt32],
        lens: List[UInt32],
    ) raises -> Tuple[List[UInt32], Bool]:
        """Runs the segmented GPU stage-1 pipeline over `bytes` with the
        given segment descriptors; returns (absolute ascending positions
        + 3 whole-input sentinels, utf8_ok). Does NOT raise on invalid
        UTF-8 — the batch caller needs the positions regardless (it falls
        back to per-line CPU validation to decide which lines to skip)."""
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            var n = len(bytes)
            var num_chunks = Int(chunk_off[len(chunk_off) - 1])
            # Upload window: the furthest any chunk reads is its segment
            # start + local*64 + 64 <= n + 63, rounded up.
            var window = max((ceildiv(n, 64) + 1) * 64, num_chunks * 64)
            self._stage_input(bytes, window)
            comptime if options.validate_utf8:
                self._err_flag.enqueue_fill(0)
            self._s1.ensure(self.ctx, num_chunks, n)
            self._s1.upload_segments(self.ctx, chunk_off, starts, lens)
            run_stage1_pipeline[options.validate_utf8](
                self.ctx,
                self._input,
                self._err_flag,
                self._s1,
                len(starts),
                num_chunks,
                n,
            )
            self.ctx.synchronize()
            var utf8_ok = True
            comptime if options.validate_utf8:
                with self._err_flag.map_to_host() as h:
                    utf8_ok = h[0] == 0
            var total: Int
            with self._s1.total.map_to_host() as h:
                total = Int(h[0])
            # Partial readback of exactly total + 3 sentinel entries —
            # whole-buffer maps/copies cost capacity-proportional time.
            # The ptr-ptr partial copy needs Metal-backed pointers on
            # both ends: stage through the pinned host buffer, then
            # memcpy into the List.
            self.ctx.enqueue_copy(
                dst_ptr=self._s1.positions_host.unsafe_ptr(),
                src_ptr=self._s1.positions.unsafe_ptr(),
                size=total + 3,
            )
            self.ctx.synchronize()
            var positions = List[UInt32](unsafe_uninit_length=total + 3)
            memcpy(
                dest=positions.unsafe_ptr(),
                src=self._s1.positions_host.unsafe_ptr(),
                count=total + 3,
            )
            return (positions^, utf8_ok)

    def _structural_index_gpu[
        options: ParseOptions
    ](mut self, bytes: Span[Byte, _]) raises -> List[UInt32]:
        """Single-segment stage 1 over `bytes`; returns the structural
        positions plus the three end-of-input sentinels — exactly what
        `structural_index[True]` + the sentinel appends produce on the
        CPU. Raises "Invalid UTF-8 in input" first when
        `options.validate_utf8` and the fused validation failed."""
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            var n = len(bytes)
            var num_chunks = max(ceildiv(n, 64), 1)
            var chunk_off: List[UInt32] = [0, UInt32(num_chunks)]
            var starts: List[UInt32] = [0]
            var lens: List[UInt32] = [UInt32(n)]
            var r = self._run_index_segmented[options](
                bytes, chunk_off, starts, lens
            )
            if not r[1]:
                raise Error("Invalid UTF-8 in input")
            var positions = List[UInt32]()
            swap(positions, r[0])
            return positions^

    def _run_stage2[
        options: ParseOptions
    ](mut self, num_tokens: Int, num_segs: Int) raises -> Tuple[Int, Int]:
        """Runs K6..K8 over the stage-1 output still resident on the
        device; returns (tape words, arena bytes). Token types, blobs,
        and per-line bases land in the `_s2` host buffers."""
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            self._s2.ensure_tokens(self.ctx, num_tokens, num_segs)
            var grid = ceildiv(num_tokens, BLOCK)
            comptime k6 = tokenize_kernel[options.ignore_unicode]
            self.ctx.enqueue_function[k6](
                self._input.unsafe_ptr(),
                self._s1.positions.unsafe_ptr(),
                self._s1.masks.unsafe_ptr(),
                self._s1.seg_chunk_off.unsafe_ptr(),
                self._s1.seg_starts.unsafe_ptr(),
                self._s2.types.unsafe_ptr(),
                self._s2.pairs.unsafe_ptr(),
                num_tokens,
                num_segs,
                self._s1.chunk_cap,
                grid_dim=grid,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[pair_scan_block_kernel](
                self._s2.pairs.unsafe_ptr(),
                self._s2.excl.unsafe_ptr(),
                self._s2.block_aggs.unsafe_ptr(),
                num_tokens,
                grid_dim=grid,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[pair_scan_aggs_kernel](
                self._s2.block_aggs.unsafe_ptr(),
                self._s2.block_bases.unsafe_ptr(),
                self._s2.totals.unsafe_ptr(),
                grid,
                grid_dim=1,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[pair_scan_apply_kernel](
                self._s2.excl.unsafe_ptr(),
                self._s2.block_bases.unsafe_ptr(),
                num_tokens,
                grid_dim=grid,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[line_bases_kernel](
                self._s1.positions.unsafe_ptr(),
                self._s2.excl.unsafe_ptr(),
                self._s2.totals.unsafe_ptr(),
                self._s1.seg_starts.unsafe_ptr(),
                self._s2.line_tape_base.unsafe_ptr(),
                self._s2.line_arena_base.unsafe_ptr(),
                num_tokens,
                num_segs,
                grid_dim=ceildiv(num_segs, BLOCK),
                block_dim=BLOCK,
            )
            self.ctx.enqueue_copy(
                dst_ptr=self._s2.totals_host.unsafe_ptr(),
                src_ptr=self._s2.totals.unsafe_ptr(),
                size=1,
            )
            self.ctx.synchronize()
            var packed = self._s2.totals_host.unsafe_ptr()[0]
            var tape_total = Int(packed >> 32)
            var arena_total = Int(packed & 0xFFFFFFFF)
            self._s2.ensure_blobs(self.ctx, tape_total + 1, arena_total + 8)

            comptime k8 = materialize_kernel[options.ignore_unicode]
            self.ctx.enqueue_function[k8](
                self._input.unsafe_ptr(),
                self._s1.positions.unsafe_ptr(),
                self._s2.types.unsafe_ptr(),
                self._s2.excl.unsafe_ptr(),
                self._s1.seg_starts.unsafe_ptr(),
                self._s2.line_arena_base.unsafe_ptr(),
                self._s2.tape_blob.unsafe_ptr(),
                self._s2.arena_blob.unsafe_ptr(),
                self._s2.five_table.unsafe_ptr(),
                num_tokens,
                num_segs,
                grid_dim=grid,
                block_dim=BLOCK,
            )
            # Readbacks (partial, through pinned buffers).
            self.ctx.enqueue_copy(
                dst_ptr=self._s2.types_host.unsafe_ptr(),
                src_ptr=self._s2.types.unsafe_ptr(),
                size=num_tokens,
            )
            if tape_total > 0:
                self.ctx.enqueue_copy(
                    dst_ptr=self._s2.tape_host.unsafe_ptr(),
                    src_ptr=self._s2.tape_blob.unsafe_ptr(),
                    size=tape_total,
                )
            if arena_total > 0:
                self.ctx.enqueue_copy(
                    dst_ptr=self._s2.arena_host.unsafe_ptr(),
                    src_ptr=self._s2.arena_blob.unsafe_ptr(),
                    size=arena_total,
                )
            self.ctx.enqueue_copy(
                dst_ptr=self._s2.tape_bases_host.unsafe_ptr(),
                src_ptr=self._s2.line_tape_base.unsafe_ptr(),
                size=num_segs,
            )
            self.ctx.enqueue_copy(
                dst_ptr=self._s2.arena_bases_host.unsafe_ptr(),
                src_ptr=self._s2.line_arena_base.unsafe_ptr(),
                size=num_segs,
            )
            self.ctx.synchronize()
            return (tape_total, arena_total)

    def _tokenize_only[
        options: ParseOptions
    ](mut self, num_tokens: Int, num_segs: Int) raises:
        """Runs just K6 (token classification) over the stage-1 output —
        the minimal stage-2 slice the bracket matcher needs."""
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            self._s2.ensure_tokens(self.ctx, num_tokens, num_segs)
            comptime k6 = tokenize_kernel[options.ignore_unicode]
            self.ctx.enqueue_function[k6](
                self._input.unsafe_ptr(),
                self._s1.positions.unsafe_ptr(),
                self._s1.masks.unsafe_ptr(),
                self._s1.seg_chunk_off.unsafe_ptr(),
                self._s1.seg_starts.unsafe_ptr(),
                self._s2.types.unsafe_ptr(),
                self._s2.pairs.unsafe_ptr(),
                num_tokens,
                num_segs,
                self._s1.chunk_cap,
                grid_dim=ceildiv(num_tokens, BLOCK),
                block_dim=BLOCK,
            )

    def _match_brackets(mut self, num_tokens: Int) raises -> Tuple[Int, Bool]:
        """Parallel bracket matching (cuJSON's depth-sort recognizer)
        over the K6 token types already on the device.

        Returns (container count, structurally_valid). On success the
        device `_br.pair_tok` maps every container TOKEN index to its
        partner's token index, and `_br.oc_tok`/`_br.pair_compact` (+
        host mirrors) carry the compact document-order view.
        """
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            var grid_t = ceildiv(num_tokens, BLOCK)
            self._br.ensure(self.ctx, num_tokens, 1)
            self.ctx.enqueue_function[oc_count_kernel](
                self._s2.types.unsafe_ptr(),
                self._br.oc_counts.unsafe_ptr(),
                num_tokens,
                grid_dim=grid_t,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[scan_counts_kernel](
                self._br.oc_counts.unsafe_ptr(),
                self._br.oc_bases.unsafe_ptr(),
                self._br.oc_total.unsafe_ptr(),
                grid_t,
                grid_dim=1,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_copy(
                dst_ptr=self._br.oc_cnt_host.unsafe_ptr(),
                src_ptr=self._br.oc_total.unsafe_ptr(),
                size=1,
            )
            self.ctx.synchronize()
            var oc_cnt = Int(self._br.oc_cnt_host.unsafe_ptr()[0])
            if oc_cnt == 0:
                return (0, True)
            self._br.ensure(self.ctx, num_tokens, oc_cnt)
            var grid_oc = ceildiv(oc_cnt, BLOCK)

            self.ctx.enqueue_function[oc_compact_kernel](
                self._s2.types.unsafe_ptr(),
                self._br.oc_bases.unsafe_ptr(),
                self._br.oc_tok.unsafe_ptr(),
                self._br.oc_delta.unsafe_ptr(),
                num_tokens,
                grid_dim=grid_t,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[depth_block_kernel](
                self._br.oc_delta.unsafe_ptr(),
                self._br.depth_incl.unsafe_ptr(),
                self._br.depth_aggs.unsafe_ptr(),
                oc_cnt,
                grid_dim=grid_oc,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[depth_aggs_kernel](
                self._br.depth_aggs.unsafe_ptr(),
                self._br.depth_bases.unsafe_ptr(),
                grid_oc,
                grid_dim=1,
                block_dim=BLOCK,
            )
            self._err_flag.enqueue_fill(0)
            self.ctx.enqueue_function[depth_finalize_kernel](
                self._br.oc_delta.unsafe_ptr(),
                self._br.depth_incl.unsafe_ptr(),
                self._br.depth_bases.unsafe_ptr(),
                self._br.depth_key.unsafe_ptr(),
                self._err_flag.unsafe_ptr(),
                oc_cnt,
                grid_dim=grid_oc,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[hist_kernel](
                self._br.depth_key.unsafe_ptr(),
                self._br.block_hists.unsafe_ptr(),
                oc_cnt,
                grid_oc,
                grid_dim=grid_oc,
                block_dim=BLOCK,
            )
            var hist_n = grid_oc * MAX_BRACKET_DEPTH
            var grid_h = ceildiv(hist_n, BLOCK)
            self.ctx.enqueue_function[u32_scan_block_kernel](
                self._br.block_hists.unsafe_ptr(),
                self._br.hist_scanned.unsafe_ptr(),
                self._br.hist_scan_aggs.unsafe_ptr(),
                hist_n,
                grid_dim=grid_h,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[scan_counts_kernel](
                self._br.hist_scan_aggs.unsafe_ptr(),
                self._br.hist_scan_bases.unsafe_ptr(),
                self._br.oc_total.unsafe_ptr(),
                grid_h,
                grid_dim=1,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[u32_scan_apply_kernel](
                self._br.hist_scanned.unsafe_ptr(),
                self._br.hist_scan_bases.unsafe_ptr(),
                hist_n,
                grid_dim=grid_h,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[sort_scatter_kernel](
                self._br.depth_key.unsafe_ptr(),
                self._br.oc_tok.unsafe_ptr(),
                self._br.hist_scanned.unsafe_ptr(),
                self._br.sorted_tok.unsafe_ptr(),
                self._br.sorted_key.unsafe_ptr(),
                oc_cnt,
                grid_oc,
                grid_dim=grid_oc,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[pair_validate_kernel](
                self._br.sorted_tok.unsafe_ptr(),
                self._br.sorted_key.unsafe_ptr(),
                self._s2.types.unsafe_ptr(),
                self._br.pair_tok.unsafe_ptr(),
                self._err_flag.unsafe_ptr(),
                oc_cnt,
                grid_dim=ceildiv(ceildiv(oc_cnt, 2), BLOCK),
                block_dim=BLOCK,
            )
            self.ctx.enqueue_function[gather_pairs_kernel](
                self._br.oc_tok.unsafe_ptr(),
                self._br.pair_tok.unsafe_ptr(),
                self._br.pair_compact.unsafe_ptr(),
                oc_cnt,
                grid_dim=grid_oc,
                block_dim=BLOCK,
            )
            self.ctx.enqueue_copy(
                dst_ptr=self._br.oc_tok_host.unsafe_ptr(),
                src_ptr=self._br.oc_tok.unsafe_ptr(),
                size=oc_cnt,
            )
            self.ctx.enqueue_copy(
                dst_ptr=self._br.pair_host.unsafe_ptr(),
                src_ptr=self._br.pair_compact.unsafe_ptr(),
                size=oc_cnt,
            )
            self.ctx.synchronize()
            var ok = True
            with self._err_flag.map_to_host() as h:
                ok = h[0] == 0
            return (oc_cnt, ok)

    def parse_document[
        options: ParseOptions = ParseOptions(),
        use_gpu_stage2: Bool = False,
    ](mut self, s: StringSlice) raises -> Document:
        """Parses a JSON document on the GPU into the standard `Document`.

        GPU stage 1 (structural indexing + fused UTF-8 validation) feeds
        the CPU stage-2 tape walk; output is byte-identical to
        `emberjson.parse_document`. Raises when no accelerator is
        available — never falls back to the CPU.

        Measured crossover (M3 Pro): the CPU `parse_document` is faster
        below ~120-150 MB (kernel-launch and staging floors); above it
        this path pulls ahead and reaches ~1.2x at 400 MB (1.75 vs
        1.45 GB/s) — the fastest way to parse a single document that
        large on this hardware. For many-document inputs prefer
        `parse_documents`, which wins from ~1 MB up.
        """
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            var buf = PaddedBuffer(s.as_bytes())
            var n = s.byte_length()
            var positions = self._structural_index_gpu[options](buf.span())
            var n_structurals = len(positions) - 3
            if n_structurals == 0:
                raise Error("Invalid json value")
            var p = Parser[options=options._padded()](padded=buf)
            comptime if use_gpu_stage2:
                # Full device materialization (numbers/strings/literals
                # prebuilt) + host grammar walk. Byte-identical output;
                # REFUTED for speed on Apple unified memory (the CPU
                # walker below wins there) — kept selectable for
                # discrete-GPU targets and covered by the same gates.
                var totals = self._run_stage2[options](n_structurals, 1)
                var sink = TapeSink(
                    tape_capacity=totals[0] + 1,
                    strings_capacity=totals[1] + 16,
                )
                assemble_line(
                    p,
                    sink,
                    self._s2.types_host.unsafe_ptr(),
                    n_structurals,
                    positions.unsafe_ptr(),
                    n,
                    self._s2.tape_host.unsafe_ptr(),
                    totals[0],
                    self._s2.arena_host.unsafe_ptr(),
                    totals[1],
                )
                return _finish_document[options](sink^)
            else:
                var sink = TapeSink(
                    tape_capacity=n // 3 + 8,
                    strings_capacity=n // 2 + 16,
                )
                _walk_tape_from_index(
                    p, sink, positions.unsafe_ptr(), n_structurals
                )
                return _finish_document[options](sink^)

    def parse_documents[
        options: ParseOptions = ParseOptions(),
        use_gpu_stage2: Bool = False,
    ](mut self, s: StringSlice) raises -> List[Document]:
        """Parses JSON Lines text on the GPU: one `Document` per line.

        The whole text runs through segmented GPU stage 1 in one pipeline
        (each line is a segment with independent carry state), then the
        CPU stage-2 walk builds each line's Document. Matches
        `read_lines` semantics: blank lines and malformed lines
        (including lines that are invalid UTF-8 when
        `options.validate_utf8`) are silently skipped. Raises when no
        accelerator is available — never falls back to the CPU.
        """
        comptime if not has_accelerator():
            raise Error(NO_ACCELERATOR_ERROR)
        else:
            var docs = List[Document]()
            var n = s.byte_length()
            if n == 0:
                return docs^
            var buf = PaddedBuffer(s.as_bytes())
            var bytes = buf.span()
            var base = bytes.unsafe_ptr()

            # Split into line segments (content excludes the '\n'; a
            # trailing '\r' is whitespace the walk never indexes).
            var starts = List[UInt32]()
            var lens = List[UInt32]()
            var line_start = 0
            var i = 0
            while i + 16 <= n:
                var v = (base + i).load[width=16]()
                var m = UInt64(pack_bits(v.eq(SIMD[DType.uint8, 16](0x0A))))
                while m != 0:
                    var nl = i + Int(count_trailing_zeros(m))
                    starts.append(UInt32(line_start))
                    lens.append(UInt32(nl - line_start))
                    line_start = nl + 1
                    m &= m - 1
                i += 16
            while i < n:
                if base[i] == 0x0A:
                    starts.append(UInt32(line_start))
                    lens.append(UInt32(i - line_start))
                    line_start = i + 1
                i += 1
            if line_start < n:
                starts.append(UInt32(line_start))
                lens.append(UInt32(n - line_start))
            if len(starts) == 0:
                return docs^

            # Per-segment chunk ranges (blank lines own zero chunks).
            var chunk_off = List[UInt32]()
            chunk_off.append(0)
            var chunks = 0
            for k in range(len(lens)):
                chunks += ceildiv(Int(lens[k]), 64)
                chunk_off.append(UInt32(chunks))
            if chunks == 0:
                return docs^

            var r = self._run_index_segmented[options](
                bytes, chunk_off, starts, lens
            )
            var positions = List[UInt32]()
            swap(positions, r[0])
            var total = len(positions) - 3
            # Whole-input UTF-8 was clean -> every line is clean. If not,
            # fall back to cheap per-line CPU validation so only the bad
            # lines are skipped (sequences cannot span the '\n').
            var check_lines_utf8 = False
            comptime if options.validate_utf8:
                check_lines_utf8 = not r[1]

            if total == 0:
                return docs^
            var num_segs = len(starts)
            var p = Parser[options=options._padded()](padded=buf)
            comptime if use_gpu_stage2:
                var s2_totals = self._run_stage2[options](total, num_segs)
                var tape_total = s2_totals[0]
                var arena_total = s2_totals[1]
                var t_types = self._s2.types_host.unsafe_ptr()
                var t_tape = self._s2.tape_host.unsafe_ptr()
                var t_arena = self._s2.arena_host.unsafe_ptr()
                var tb = self._s2.tape_bases_host.unsafe_ptr()
                var ab = self._s2.arena_bases_host.unsafe_ptr()
                for k in range(num_segs):
                    var lstart = Int(starts[k])
                    var llen = Int(lens[k])
                    if llen == 0:
                        continue
                    if check_lines_utf8:
                        if not is_valid_utf8(
                            Span(ptr=base + lstart, length=llen)
                        ):
                            continue
                    var lend = lstart + llen
                    var lo = _lower_bound(
                        positions.unsafe_ptr(), total, UInt32(lstart)
                    )
                    var hi = _lower_bound(
                        positions.unsafe_ptr(), total, UInt32(lend)
                    )
                    var cnt = hi - lo
                    if cnt == 0:
                        continue
                    var tape_base = Int(tb[k])
                    var tape_end = (
                        Int(tb[k + 1]) if k + 1 < num_segs else tape_total
                    )
                    var arena_base = Int(ab[k])
                    var arena_end = (
                        Int(ab[k + 1]) if k + 1 < num_segs else arena_total
                    )
                    var sink = TapeSink(
                        tape_capacity=tape_end - tape_base + 1,
                        strings_capacity=arena_end - arena_base + 16,
                    )
                    try:
                        assemble_line(
                            p,
                            sink,
                            t_types + lo,
                            cnt,
                            positions.unsafe_ptr() + lo,
                            lend,
                            t_tape + tape_base,
                            tape_end - tape_base,
                            t_arena + arena_base,
                            arena_end - arena_base,
                        )
                        docs.append(_finish_document[options](sink^))
                    except:
                        continue
                return docs^
            else:
                var scratch = List[UInt32]()
                for k in range(num_segs):
                    var lstart = Int(starts[k])
                    var llen = Int(lens[k])
                    if llen == 0:
                        continue
                    if check_lines_utf8:
                        if not is_valid_utf8(
                            Span(ptr=base + lstart, length=llen)
                        ):
                            continue
                    var lend = lstart + llen
                    var lo = _lower_bound(
                        positions.unsafe_ptr(), total, UInt32(lstart)
                    )
                    var hi = _lower_bound(
                        positions.unsafe_ptr(), total, UInt32(lend)
                    )
                    var cnt = hi - lo
                    if cnt == 0:
                        continue
                    # Per-line index: absolute positions + three
                    # sentinels at the line end, where the '\n' (or the
                    # padding NUL for the final line) fails dispatch.
                    scratch.resize(unsafe_uninit_length=cnt + 3)
                    memcpy(
                        dest=scratch.unsafe_ptr(),
                        src=positions.unsafe_ptr() + lo,
                        count=cnt,
                    )
                    for j in range(3):
                        scratch[cnt + j] = UInt32(lend)
                    var sink = TapeSink(
                        tape_capacity=llen // 3 + 8,
                        strings_capacity=llen // 2 + 16,
                    )
                    try:
                        _walk_tape_from_index(
                            p, sink, scratch.unsafe_ptr(), cnt
                        )
                        docs.append(_finish_document[options](sink^))
                    except:
                        continue
                return docs^

    def _smoke_test(mut self) raises -> Bool:
        """Launches a trivial kernel and verifies its output.

        Proves in-package kernel codegen + launch + readback on the
        current machine; used by the GPU test scaffolding.
        """
        comptime if not has_accelerator():
            return False
        else:
            var buf = self.ctx.enqueue_create_buffer[DType.uint32](_SMOKE_N)
            self.ctx.enqueue_function[_smoke_kernel](
                TileTensor(buf, _smoke_layout),
                grid_dim=_SMOKE_N // _SMOKE_BLOCK,
                block_dim=_SMOKE_BLOCK,
            )
            self.ctx.synchronize()
            var ok = True
            with buf.map_to_host() as host:
                for i in range(_SMOKE_N):
                    if host[i] != UInt32(i * 3 + 1):
                        ok = False
                        break
            return ok
