# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

All commands use **Pixi** as the task runner.

```bash
pixi run test          # Run all tests
pixi run build         # Build emberjson.mojopkg
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

- **`emberjson/__init__.mojo`** — public API: `parse`, `to_string`, `serialize`, `deserialize`, etc.
- **`emberjson/value.mojo`** — core `Value` type
- **`emberjson/array.mojo`**, **`object.mojo`** — collection types
- **`emberjson/_deserialize/`** — parsing pipeline:
  - `parser.mojo` — hand-written recursive descent parser
  - `slow_float_parse.mojo` — fallback float parsing
  - `tables.mojo` — lookup tables for character classification
  - `reflection.mojo` — reflection-based struct deserialization
- **`emberjson/_serialize/`** — serialization:
  - `reflection.mojo` — reflection-based struct serialization
- **`emberjson/teju/`** — Teju Jagua float-to-string algorithm (large lookup tables in `tables.mojo`)
- **`emberjson/schema.mojo`** — JSON Schema validation
- **`emberjson/_pointer.mojo`** — RFC 6901 JSON Pointer
- **`emberjson/patch/`** — RFC 6902 JSON Patch
- **`emberjson/lazy.mojo`** — lazy/deferred parsing
- **`emberjson/jsonl.mojo`** — JSON Lines format

### Key Traits

- `JsonValue` — base trait for JSON-compatible types
- `JsonSerializable` — implement for custom serialization
- `JsonDeserializable` — implement for custom deserialization

### Public API

```mojo
parse[options](json_string)          # → Value (raises on error)
try_parse[options](json_string)      # → Optional[Value]
parse_document[options](json_string) # → Document (immutable tape, fastest full parse)
try_parse_document[options](s)       # → Optional[Document]
parse_pointer[options](s, "/a/b/0")  # → Value (partial access: only the target is parsed/validated)
try_parse_pointer[options](s, path)  # → Optional[Value]
is_valid_utf8(bytes_or_slice)        # → Bool (RFC 3629 SIMD validator; ON by default in parsing — ParseOptions(validate_utf8=False) to skip)
to_string[pretty=False](value)       # → String
serialize[pretty=False](value)       # → String
deserialize[T](json_string)          # → T (reflection-based)
try_deserialize[T](json_string)      # → Optional[T]
```

## Mojo Version

Requires `mojo >=1.0.0b3.dev2026071006,<2` (MAX nightly channel). Platforms: osx-arm64, linux-aarch64, linux-64.

A full reference for the Mojo APIs https://docs.modular.com/llms-mojo.txt