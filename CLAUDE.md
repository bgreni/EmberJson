# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All commands use **Pixi** as the task runner.

```bash
pixi run test          # Run all tests
pixi run build         # Build emberjson.mojoc
pixi run format        # Format code (mojo format -l 80 .)
pixi run bench         # Run benchmarks
pixi run fuzz          # Run fuzzing tests
pixi run precommit     # format + test + fuzz + python_compat
```

**Evaluating peformance changes**

Running `pixi run bench_compare` generates a table that compares
the current run to the established values in `bench_result.txt`. Use
this command to evaluate performance related changes you make.

**Run a single test file:**
```bash
pixi run mojo -D ASSERT=all -I . test/emberjson/<path/to/test.mojo>
```

Tests are orchestrated by `run_tests.py`, which walks `test/emberjson/` and runs each `.mojo` file with `mojo -D ASSERT=all -I .`.

## Architecture

**EmberJson** is a JSON parsing/serialization library in Mojo (by Modular).

### Core Type

`Value` in `emberjson/value.mojo` is a `Variant` of 8 possible JSON types:

```
Value = Variant[Int64, UInt64, Float64, String, Bool, Object, Array, Null]
```

All JSON data is represented as this unified type.

### Module Layout

- **`emberjson/__init__.mojo`** — public API: `from_json`, `try_from_json`, `to_json`, `to_json_pretty`, etc.
- **`emberjson/value.mojo`** — core `Value` type
- **`emberjson/array.mojo`**, **`object.mojo`** — collection types
- **`emberjson/_deserialize/`** — parsing pipeline:
  - `parser.mojo` — hand-written recursive descent parser
  - `slow_float_parse.mojo` — fallback float parsing
  - `tables.mojo` — lookup tables for character classification
- **`emberjson/_serde/`** — the JSON format layer for
  [emberserde](../emberserde) (a path dependency), which supplies the
  format-agnostic `Serializable`/`Deserializable` framework and reflection
  defaults:
  - `serializer.mojo` — `EmberJsonSerializer` + `to_json`
  - `deserializer.mojo` — `EmberJsonDeserializer` (drives the hand-written
    `Parser`) + `from_json`
- **`emberjson/teju/`** — Teju Jagua float-to-string algorithm (large lookup tables in `tables.mojo`)
- **`emberjson/schema.mojo`** — JSON Schema validation
- **`emberjson/_pointer.mojo`** — RFC 6901 JSON Pointer
- **`emberjson/patch/`** — RFC 6902 JSON Patch
- **`emberjson/lazy.mojo`** — lazy/deferred parsing
- **`emberjson/jsonl.mojo`** — JSON Lines format

### Key Traits

- `JsonValue` — base trait for JSON-compatible types
- emberserde's `Serializable` / `Deserializable` — implement for custom
  serialization/deserialization (re-exported through `emberjson.traits`)

### Public API

```mojo
from_json[T, options](json_string)     # → T (raises DeserializationError)
try_from_json[T, options](json_string) # → Optional[T]
to_json[pretty, indent](value)         # → String (raises SerializationError)
to_json_pretty[indent](value)          # → String, indented

# T selects the strategy at compile time:
#   Value    → hand-written recursive-descent parser, mutable variant
#   Document → immutable tape, no per-node allocation, fastest full parse
#   other    → emberserde reflection

parse_pointer[options](s, "/a/b/0")    # → Value (only the target is parsed)
try_parse_pointer[options](s, path)    # → Optional[Value]
is_valid_utf8(bytes_or_slice)          # → Bool (ON by default in from_json)
```

## Mojo Version

Requires `mojo >=1.1.0.dev2026082905,<2` (MAX nightly channel; the
authoritative pin is `pixi.toml`, spelled out there three times — workspace
plus the two `[package.*-dependencies]` tables). Platforms: osx-arm64, linux-aarch64, linux-64.

A full reference for the Mojo APIs https://docs.modular.com/llms-mojo.txt