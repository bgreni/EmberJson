#!/usr/bin/env python3
"""Assert `pixi.lock` names exactly one Mojo compiler version.

The lockfile records the compiler twice over: once for the workspace
environment that runs the tests, and once for emberserde's source build
environment, which produces `emberserde.mojoc`. A `.mojoc` only loads with the
compiler that built it, but pixi solves the two independently --
`pixi update mojo` moves only the first, and editing the emberserde spec
re-solves only the second. When they drift, every stage fails with
"precompiled file is incompatible" followed by a cascade of unrelated-looking
errors. Keep them together with `pixi update mojo emberserde`.

    pixi run check_lock_compilers
"""

import re
import sys

LOCKFILE = "pixi.lock"
COMPILER = re.compile(r"/mojo-compiler-([^/-]+)-[^/]+\.conda")


def main() -> int:
    with open(LOCKFILE) as f:
        versions = sorted(set(COMPILER.findall(f.read())))

    if len(versions) == 1:
        print(f"{LOCKFILE}: one Mojo compiler: {versions[0]}")
        return 0

    if not versions:
        print(f"{LOCKFILE}: no mojo-compiler packages found", file=sys.stderr)
        return 1

    print(
        f"{LOCKFILE}: mixes Mojo compilers, so emberserde.mojoc will not load"
        " with the workspace compiler:",
        file=sys.stderr,
    )
    for version in versions:
        print(f"  mojo-compiler {version}", file=sys.stderr)
    print(
        "Re-resolve both together with `pixi update mojo emberserde`.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
