#!/usr/bin/env python3
"""Cross-compile the SIMD kernels and report instruction counts per target.

Run manually -- NOT part of `pixi run test`. It needs a cross-compiling
toolchain and takes minutes. Its job is to make the claims in
docs/superpowers/specs/2026-09-02-simd-shuffle-portability-design.md
reproducible, and to catch a toolchain upgrade silently changing how
these kernels lower.

    pixi run python tools/check_codegen.py

STILL UNVERIFIED ON REAL HARDWARE. Every x86 number this prints is a
static instruction count from cross-compilation. Counts are not cycles:
they distinguish native lowering from a scalarized gather, nothing more.
When hardware becomes available, in priority order:

  1. AVX-512. Two machines needed, because they lower differently: an
     AVX-512BW part without VBMI (Skylake-SP, Cascade Lake -- VPSHUFB
     ymm) and a VBMI part (Ice Lake, Zen 4/5 -- VPERMB). First confirm
     the AVX2/width-32 path these now take is good in wall-clock. Then
     measure whether raising KERNEL_WIDTH to 64 is worth it: the
     classifier says no (14-16 either way), is_valid_utf8 says probably
     yes (64 bytes per iteration instead of 32, same instruction count).
  2. SSSE3-only x86. HAS_BYTE_SHUFFLE excludes it purely for lack of a
     test machine; static counts say the classifier would go 200 -> 82.
     Enabling it is one token: has_avx2() -> _has_feature["ssse3"]().
  3. The conda linux-64 artifact's actual target. Inferred from
     pixi.toml setting no target-cpu, not observed. Settle it with
     `objdump -d <package .so> | grep -c pshufb`.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# (label, extra mojo build flags). Bare aarch64 uses the host triple.
TARGETS = [
    ("host (apple silicon)", []),
    ("x86-64 (SSE2)", ["--target-cpu=x86-64"]),
    ("x86-64-v2 (SSSE3)", ["--target-cpu=x86-64-v2"]),
    ("znver2 (AVX2)", ["--target-cpu=znver2"]),
    ("haswell (AVX2)", ["--target-cpu=haswell"]),
    ("skylake-avx512 (no VBMI)", ["--target-cpu=skylake-avx512"]),
    ("icelake-server (VBMI)", ["--target-cpu=icelake-server"]),
    ("znver4 (VBMI)", ["--target-cpu=znver4"]),
]
X86_TRIPLE = ["--target-triple=x86_64-unknown-linux-gnu"]

PROBE = '''
from emberjson._index.classifier import classify
from emberjson._index.simd_ops import SimdInput
from emberjson._utf8 import is_valid_utf8

@export
@no_inline
def probe_classify(p: Pointer[UInt8, ImmUntrackedOrigin]) -> UInt64:
    var b = classify(SimdInput.load(p))
    return b.op ^ b.whitespace

@export
@no_inline
def probe_eq(p: Pointer[UInt8, ImmUntrackedOrigin]) -> UInt64:
    return SimdInput.load(p).eq(UInt8(0x5C))

@export
@no_inline
def probe_utf8(s: Span[Byte, ImmUntrackedOrigin]) -> Bool:
    return is_valid_utf8(s)
'''

FUNCS = ["probe_classify", "probe_eq", "probe_utf8"]


_LABEL_RE = re.compile(
    r"^_?(" + "|".join(re.escape(f) for f in FUNCS) + r"):$"
)


def count(asm: str, fn: str) -> int:
    """Instructions between the function label and its end.

    Terminate on `.Lfunc_end` / `-- End function` / `.cfi_endproc`. Do
    NOT use `\\s` in a terminator regex if you port this to awk: macOS
    awk does not honor it, the terminator never fires, and counts run
    into the next function.

    The host target (bare aarch64, no `--target-triple`) cross-compiles
    to nothing -- it is a native Mach-O build on this machine, not ELF --
    and Mach-O `--emit=asm` output carries none of the three terminators
    above: no `.cfi_endproc`, no `.Lfunc_end`, no `-- End function`.
    Without a fallback, `inside` would latch True at the host probe's
    label and never clear, so the count silently absorbs every
    instruction in every function after it in the file (verified: the
    host row measured 77/19/228 instead of the expected 58/19/151,
    exactly matching what you get by summing forward through the next
    probes). The extra condition below -- terminate on hitting any
    *other* known probe's own label -- fixes this for Mach-O without
    touching the ELF path, since on ELF the real terminator always fires
    first.
    """
    n = 0
    inside = False
    for line in asm.splitlines():
        if re.match(rf"^_?{re.escape(fn)}:$", line):
            inside = True
            continue
        if inside and (
            ".Lfunc_end" in line
            or "-- End function" in line
            or ".cfi_endproc" in line
            or (_LABEL_RE.match(line) and not re.match(
                rf"^_?{re.escape(fn)}:$", line
            ))
        ):
            inside = False
        if inside and re.match(r"^[ \t]+[a-z]", line):
            n += 1
    return n


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "probe.mojo"
        src.write_text(PROBE)
        print(f"{'target':<28}" + "".join(f"{f:>16}" for f in FUNCS))
        failures = []
        for label, flags in TARGETS:
            asm_path = Path(tmp) / "out.s"
            cmd = (
                ["mojo", "build", "--emit=asm", "-I", str(REPO),
                 "-o", str(asm_path)]
                + (X86_TRIPLE + flags if flags else [])
                + [str(src)]
            )
            proc = subprocess.run(
                cmd, cwd=REPO, capture_output=True, text=True
            )
            if proc.returncode:
                print(f"{label:<28}  BUILD FAILED")
                print(proc.stderr.strip()[:400])
                failures.append(label)
                continue
            asm = asm_path.read_text()
            counts = [count(asm, f) for f in FUNCS]
            print(f"{label:<28}" + "".join(f"{c:>16}" for c in counts))
            if any(c == 0 for c in counts):
                print(
                    f"  WARNING: a probe counted 0 instructions on {label}."
                    " The symbol was probably renamed -- fix FUNCS."
                )
                failures.append(label)
        print(
            "\nExpected shape: probe_classify around 58 on apple silicon,"
            " 36 on znver2/haswell, 14-16 on the three AVX-512 targets,"
            " and the portable path (~187-200) on x86-64 and x86-64-v2"
            " (neither has AVX2, so HAS_BYTE_SHUFFLE is false for both)."
            " Anything in the hundreds on a shuffle target means a kernel"
            " scalarized: check for vpextrb/vpinsrb or movzbl+punpck in"
            " the asm.\n"
            "probe_eq: around 19 on apple silicon, 9 on znver2/haswell,"
            " 5 on znver4.\n"
            "probe_utf8: around 151 on apple silicon and every shuffle"
            " x86 target (znver2/haswell/AVX-512). x86-64 and"
            " x86-64-v2 have no byte-shuffle instruction under this"
            " gate (SSSE3 alone does not satisfy has_avx2()), so"
            " is_valid_utf8 takes _is_valid_utf8_no_shuffle there instead"
            " of the table-lookup kernel -- expect a different, and"
            " probably larger, count on those two rows. There is no"
            " fixed target for it; what matters is that it stays far"
            " below the ~695-instruction scalarized byte-gather that the"
            " no-shuffle path exists specifically to avoid. A count near"
            " 695 on x86-64 or x86-64-v2 means the ASCII-prefix vector"
            " scan (compare + movemask, which baseline SSE2 has) is not"
            " firing and every byte is falling through to the scalar"
            " validator -- investigate before trusting the number."
        )
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
