# NVIDIA GPU Support Plan (RTX 3080 bring-up + CUDA-competitor shootout)

Goal: run EmberJson's GPU engines on an RTX 3080 (Ampere, sm_86, 10 GB
GDDR6X @ 760 GB/s, PCIe 4.0 x16), add NVIDIA-optimized fast paths, and
directly compare against CUDA-based parsers (cuJSON primarily, cuDF
optionally) on the same box, same files, deliverable-matched.

## Where we start (measured state, Apple M3 Pro, 2026-07-19)

The whole GPU stack is written vendor-portable (no CUDA/Metal
intrinsics, shared-memory + `barrier()` scans, no warp-size
assumptions), so it should compile and run on NVIDIA unmodified. But it
carries **Metal-workaround taxes** that NVIDIA doesn't need — each one
is a documented fast-path opportunity:

| Metal constraint (probed) | Current workaround | NVIDIA fast path to try |
|---|---|---|
| `pack_bits` crashes Metal compiler | comptime-unrolled per-lane bit ORs (`_movemask16/64` in `_gpu/stage1.mojo`) | native `pack_bits` (movemask) — the known ~2x lever on K1 |
| `_dynamic_shuffle` crashes Metal compiler | per-lane `table[Int(idx[i])]` extracts (`_tbl` in `_gpu/stage1.mojo`, `_gpu/utf8.mojo`) | `_dynamic_shuffle` (PRMT/shuffle) |
| `UInt128` arithmetic crashes Metal compiler | 32-bit-limb mulhi (`_mul_64x64_128` in `_gpu/numbers.mojo`) | native `UInt128` / `full_multiplication` |
| Misaligned typed loads/stores silently address-rounded | byte-wise u64 assembly (`_load_u64_le`), byte-wise arena length stores | direct unaligned loads/stores |
| comptime `StackArray` globals don't link into kernels | tables uploaded as DeviceBuffers | possibly direct comptime tables (probe; buffer upload is fine either way) |
| Early `return`/`continue` in runtime loops miscompiles one inlined instance | single-exit flag-carrying control flow everywhere | keep single-exit (harmless); do NOT regress Metal |
| No FP64 at all | integer-form Eisel-Lemire (already vendor-neutral, keep) | keep (bit-exact and fast) |

Baselines to beat/match (M3 Pro, min-of-N, transfers included):

- Stage 1 (full validated index): 6.9-7.1 GB/s @ 11 MB, ~10.5 GB/s marginal
- Index + token types + bracket pairs (cuJSON-equivalent deliverable):
  1.38 / 4.57 / **5.09 GB/s** @ 11 / 105 / 420 MB
- Full `Document` single-doc: 1.75 GB/s @ 420 MB (GPU wins CPU above ~120-150 MB)
- Full `Document` batch: 1.08 GB/s @ 400 MB (1.8x vs 1-core CPU)
- Mojoson (ehsanmok/json) same machine: 3.47 GB/s @ 420 MB for a
  positions-only fragment (no strings/pairs/validation)

3080 expectations, honestly set: kernels are memory-bound, so
device-side rates should scale roughly with bandwidth (~5x M3 Pro →
stage-1 kernel-only plausibly 30-60 GB/s). But PCIe 4 x16 caps H2D at
~20-25 GB/s, so **transfer-inclusive numbers will be PCIe-shaped** —
cuJSON has the same physics; compare both ways (see N5 methodology).
VRAM budget: full pipeline allocates ~4-5x input (masks 0.63x +
positions ~0.5x + tape/arena blobs ~1.5x + staging) → cap single-shot
inputs at ~1.5 GB on 10 GB; index-only mode ~2.5-3 GB. Larger inputs
need the batch/chunked path.

## Prepared today (in-tree, ready for the desktop)

- `tools/gpu_probe.mojo` — cross-vendor capability probe: launches one
  kernel per construct in try/except and prints a SUPPORTED/UNSUPPORTED
  matrix (pack_bits, dynamic_shuffle, u128, misaligned access, table
  linkage, multi-exit loops, shared-mem atomics, host-pointer wrap).
  Run FIRST on the 3080; it decides every fast-path switch.
- `tools/gpu_crossover.mojo` — the scale benchmark harness
  (`single` / `batch` / `index` modes, min-of-3, GB/s).
- `tools/gen_large_datasets.py` + pixi task `gen_large` — regenerates
  the 100 MB / 400 MB batch + single-doc test files from
  `bench_data/big_lines_complex.jsonl` (they are not committed).

## The desktop day, in order

### N0 — Bring-up (gate: everything green before touching perf)
1. Linux + NVIDIA driver (>= 550 recommended for the Mojo nightly);
   `pixi install` in the repo (pixi.toml already targets linux-64; the
   GPU stdlib ships with the pinned `mojo` package — no `max` needed).
2. `pixi run mojo tools/gpu_probe.mojo` → record the 3080 capability
   matrix. Expect all Metal-crashers to be SUPPORTED here.
3. Full gates on NVIDIA: `pixi run test` (GPU suites self-enable via
   `has_accelerator()`), `pixi run fuzz` (4-engine differential),
   `pixi run bench_gpu`. Any failure here is a stop-the-line bug —
   the differential tests pinpoint the layer.
4. `pixi run gen_large`, then `tools/gpu_crossover` at 11/105/420 MB
   (single, batch, index) → **the unmodified-portable-code baseline.**
   This alone is a publishable number: same source, two vendors.

### N1 — Competitor setup (before optimizing, so targets are concrete)
1. cuJSON: `git clone https://github.com/AutomataLab/cuJSON` + CUDA
   toolkit (nvcc + Thrust). Build their `main.cu` / JSONL variants per
   their README. Run on: their bundled datasets AND our generated
   105/420 MB files. Record their phase timings (they print
   H2D/kernel/extract splits) — kernel-only AND end-to-end.
2. Optional: cuDF (`pip install cudf-cu12`) `read_json` on the same
   files (full-parse-to-columns — closest to our Document mode).
3. Optional context rows: simdjson (their repo vendors a bench) and
   EmberJson CPU on the desktop's CPU.

### N2 — NVIDIA fast paths (probe-first, one lever at a time, bench each)
Structure: comptime target dispatch in the FOUR extraction primitives,
mirroring the CPU code's NEON-vs-portable two-layer pattern. Metal
paths stay the `else`; nothing about Apple behavior may change.

```mojo
from std.sys.info import is_nvidia_gpu
comptime if is_nvidia_gpu():
    # fast form (pack_bits / _dynamic_shuffle / UInt128 / direct loads)
else:
    # Metal-safe form (current code)
```

Order by measured leverage:
1. `_movemask16/64` → `pack_bits` (K1 classify is extraction-dominated;
   biggest single win expected).
2. `_tbl` → `_dynamic_shuffle` (K1 classifier + UTF-8 tables).
3. `_load_u64_le` / arena length stores → direct accesses (K8 numbers/strings).
4. `_mul_64x64_128` → native UInt128 (float tape words).
After each: `pixi run test` (GPU suites) + crossover index/single @420 MB.
The differential gates make each step safe to land fast.

### N3 — Pipeline shape for discrete memory (PCIe-aware)
1. Re-measure the phase split (the `bench_gpu` micro rows: launch
   overhead, H2D/D2H — expect launch ~5-10us vs Metal's ~170us; this
   alone reshapes small-input crossovers).
2. Readback diet for index mode: positions/pairs can stay on device
   for device-resident consumers; only copy what the host needs
   (already partial-copy structured; verify sizes at PCIe rates).
3. If Mojo's DeviceContext exposes streams/async on NVIDIA (probe),
   overlap chunked H2D with K1 for large inputs. If not: single-shot
   is fine to 1.5 GB; note as toolchain-blocked.

### N4 — Warp-level scans (only if N2 leaves us short of cuJSON)
Replace shared-memory Hillis-Steele block scans with warp-shuffle scans
(`std.gpu.primitives.warp`) under `is_nvidia_gpu()` in: stage-1 element
scan, count scans, stage-2 pair scans, bracket histogram scan. Expected
~1.2-1.5x on scan-heavy phases; measured decision, not automatic.

### N5 — The shootout report (methodology rules, learned the hard way)
- Same box, same files, min-of-N, warm; report BOTH end-to-end
  (transfers included) and kernel-only, per system, because cuJSON
  reports phase splits and fragments are not parses.
- **Deliverable-matched rows only:**
  - vs cuJSON "parse": our index+pairs mode (their output: positions +
    pair_pos; ours additionally carries token types + full in-string
    filtering — note the asymmetry in THEIR favor this time).
  - vs cuDF read_json: our full-Document batch mode.
  - No CUDA system produces our validated tape + arena + dup-key
    detection; state it rather than blur it.
- Publish the table in README alongside the M3 Pro numbers, with the
  exact harness commands so it's reproducible.

### N6 — Stretch (if the day has room)
- Phase 5b: feed the on-device `pair_tok` map into stage-2 container
  word patching + parent-atomic counts + parallel grammar checks to
  retire the host assemble walk in full-Document mode. On PCIe this is
  worth more than on unified memory (one tape+arena readback replaces
  positions readback + host walk). The bracket matcher (the keystone
  risk) is already built and gated.
- JSONL chunked streaming for >VRAM batches.

## Risks / unknowns for tomorrow
- Mojo nightly vs consumer Ampere (sm_86) and the driver on that box —
  N0 step 2 surfaces this immediately; keep the pinned nightly, only
  `pixi update` as a last resort (then re-run ALL gates).
- NVIDIA-specific miscompiles: assumed zero, verified by the same
  differential gates that caught every Metal one.
- 10 GB VRAM with the 420 MB full pipeline: fits (~2.5 GB); watch
  `ensure_*` growth if experimenting past 1 GB inputs.
- cuJSON build friction (CUDA version pins, Thrust API drift): budget
  30-60 min; their repo pins are in their README/Makefile.

## Definition of done
1. Capability matrix + full gate suite green on the 3080.
2. Crossover curves (single/batch/index) recorded for portable and
   fast-path builds.
3. cuJSON same-box, same-file numbers recorded (kernel-only + e2e).
4. README comparison table updated; memory notes updated.
5. Honest verdicts recorded for anything that loses — REFUTED entries
   are results, not failures.
