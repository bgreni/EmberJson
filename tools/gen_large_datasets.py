#!/usr/bin/env python3
"""Regenerates the large-scale GPU benchmark datasets (not committed).

Produces, in bench_data/large/ (gitignored):
  batch_100mb.jsonl / batch_400mb.jsonl   - concatenated JSONL batches
  single_11mb.json / single_105mb.json / single_420mb.json
      - the same records joined into ONE valid JSON array (the
        single-large-document workload where the GPU path beats the CPU
        above ~120-150 MB on M3 Pro; see NVIDIA_GPU_PLAN.md baselines).

Source corpus: bench_data/big_lines_complex.jsonl (committed; itself
regenerable via `pixi run gen_jsonl`).

Usage: pixi run gen_large
"""

import os

SRC = "bench_data/big_lines_complex.jsonl"
OUT = "bench_data/large"


def main():
    os.makedirs(OUT, exist_ok=True)
    src = open(SRC, "rb").read()
    lines = [l for l in src.split(b"\n") if l.strip()]

    with open(f"{OUT}/batch_100mb.jsonl", "wb") as f:
        for _ in range(9):
            f.write(src)
    with open(f"{OUT}/batch_400mb.jsonl", "wb") as f:
        for _ in range(36):
            f.write(src)

    open(f"{OUT}/single_11mb.json", "wb").write(
        b"[" + b",\n".join(lines) + b"]"
    )
    open(f"{OUT}/single_105mb.json", "wb").write(
        b"[" + b",\n".join(lines * 9) + b"]"
    )
    open(f"{OUT}/single_420mb.json", "wb").write(
        b"[" + b",\n".join(lines * 36) + b"]"
    )
    for name in sorted(os.listdir(OUT)):
        sz = os.path.getsize(f"{OUT}/{name}") // (1024 * 1024)
        print(f"  {name}: {sz} MB")


if __name__ == "__main__":
    main()
