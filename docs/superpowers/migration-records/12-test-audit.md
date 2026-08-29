# Test audit — which of the 143 new tests earn their place

**Premise:** the migration replaced an implementation, not a behaviour set. The
pre-existing 299 tests kept passing throughout, and once Task 8 rewired the
public API onto `_serde`, those tests *became* tests of the new implementation.
Any new test that re-checks old behaviour through the private layer is
duplicating them one level lower — which is also the weaker place to test.

**Root cause of the excess:** the Task 6 dispatch said *"Every ported wrapper
needs a test through the NEW path, and every raise path needs a negative test."*
That instruction was wrong: the wrappers were already covered, and were about to
be covered *through the new path* automatically. Subsequent fix rounds repeated
the "prior tasks were dinged for thin coverage" framing, which only ever ratchets
one way.

**Verdict:** of 143 new tests, **~62 earn their place** and **~81 should go**.
Net suite: 444 → ~363, with no behaviour left uncovered.

**Confidence key:** ✅ = name + layer make it unambiguous. ⚠️ = verify the body
covers the same case before deleting.

---

## 1. `test_schema_fields.mojo` — 31 tests → keep 9, drop 22

Imports `from emberjson._serde import from_json_string, to_json_string`.
`test_schema.mojo` covers the same wrappers via `from emberjson import
deserialize, serialize` (112 call sites), which now routes through `_serde`.

### DROP — same-named counterpart already in `test_schema.mojo`

| drop | covered by |
|---|---|
| `test_range` ✅ | `test_range_int`, `test_range_float` |
| `test_exclusive_range` ✅ | `test_exclusive_range` |
| `test_size` ✅ | `test_size_string`, `test_size_list` |
| `test_non_empty` ✅ | `test_non_empty` |
| `test_starts_ends_with` ✅ | `test_starts_ends_with` |
| `test_unique` ✅ | `test_unique` |
| `test_eq_ne_not` ✅ | `test_not_ne` |
| `test_multiple_of` ✅ | `test_multiple_of` |
| `test_all_of` ✅ | `test_all_of` |
| `test_one_of` ✅ | `test_one_of` |
| `test_any_of` ✅ | `test_any_of` |
| `test_none_of` ✅ | `test_none_of` |
| `test_enum` ✅ | `test_enum` |
| `test_secret` ✅ | `test_secret` |
| `test_clamp` ✅ | `test_clamp` |
| `test_transform` ✅ | `test_transform` |
| `test_coerce_custom_func` ✅ | `test_coerce` |
| `test_coerce_builtins` ✅ | `test_coerce_int/uint/float/string` |
| `test_cross_field_validator` ✅ | `test_cross_field_validator` |
| `test_validated_serializes_payload` ⚠️ | `test_range_serialization` |
| `test_default_serializes_payload` ⚠️ | `test_default` (extended in the final wave with three `serialize` asserts) |
| `test_secret_redaction_survives_nesting` ⚠️ | `test_secret` — **verify nesting depth** before dropping; if the existing test is flat, keep this one |

### KEEP → fold into `test_schema.mojo`

Genuinely new behaviour — the `Default`→`Field` semantic change, `Field`'s new
capabilities, and typed errors:

- `test_default_fills_when_key_missing`
- `test_default_present_key_wins`
- `test_default_explicit_null_raises` ← **the migration's one behaviour change**
- `test_optional_default_null_binds_none` ← its escape hatch
- `test_default_missing_required_field_still_raises`
- `test_field_rename_skip_and_aliases` ← capability EmberJson never had
- `test_field_composes_with_a_validator`
- `test_validation_failure_reports_kind_and_path`
- `test_coerce_failure_reports_kind`

**File disposition:** delete `test_schema_fields.mojo` entirely.

---

## 2. `test_borrow_lazy.mojo` — 29 tests → keep 23, drop 6

The `raw_bytes` half tests a hook that did not exist before. Nothing in the old
suite covers it. This is the file that most earns its size.

### DROP — duplicates `test_lazy.mojo`

| drop | covered by |
|---|---|
| `test_lazy_string_via_borrowing_deserializer` ✅ | `test_lazy_string` |
| `test_lazy_int_via_borrowing_deserializer` ✅ | `test_lazy_int` |
| `test_lazy_uint_via_borrowing_deserializer` ✅ | `test_lazy_uint` |
| `test_lazy_float_via_borrowing_deserializer` ✅ | `test_lazy_float` |
| `test_lazy_value_via_borrowing_deserializer` ✅ | `test_lazy_value` |
| `test_lazy_string_unsafe_slice_strips_quotes` ⚠️ | `test_lazy_string` — **verify** it asserts the quote-strip, not just the value |

### KEEP — all 23 remaining

`raw_bytes` mechanics (15): the six kinds, three kind-mismatch rejections,
`test_borrowed_span_aliases_the_input` (the no-copy proof),
`test_cursor_advances_past_borrowed_value`, `test_deferred_parse_of_borrowed_bytes`,
`test_conformance_relationships`, `test_raw_bytes_refuses_padded_options`.

`Lazy`-on-`RawKind` behaviour (8): the two kind-mismatch tests,
`test_lazy_span_aliases_the_input`, the three `serialize` tests including
`test_serialize_reencodes_rather_than_echoing` (the divergence pin),
`test_lazy_default_kind_is_map_for_plain_struct`,
`test_lazy_serialize_surfaces_get_failure`.

**File disposition:** keep as its own file — it covers a new subsystem, which is
exactly when a new file is warranted.

---

## 3. `test_format_serialize.mojo` — 24 tests → keep 8, drop 16

### DROP — covered by `test_value.mojo` (29), `test_roundtrip.mojo` (27), `test_reflection_serialize.mojo` (8)

`test_struct_serializes_compact` ✅, `test_string_is_escaped` ⚠️,
`test_float_uses_teju` ⚠️, `test_list_serializes_as_array` ✅,
`test_pretty_nests_with_indent` ✅ (→ `test_pretty_serialize`),
`test_null_serializes_to_null_literal` ✅, `test_array_serializes_compact` ✅,
`test_empty_array_serializes_compact` ✅, `test_object_serializes_compact` ✅,
`test_empty_object_serializes_compact` ✅,
`test_value_serializes_every_scalar_arm` ✅,
`test_value_serializes_object_and_array_arms_by_delegation` ⚠️,
`test_serializes_every_arm` ⚠️, `test_serializes_bare_array` ✅,
`test_serializes_bare_object` ✅, `test_serializes_null` ✅.

⚠️ on `test_float_uses_teju` and the "every arm" pins: these assert **exact
bytes**, where `test_roundtrip.mojo` asserts round-tripping. Check that at least
one surviving test pins float formatting exactly before dropping
`test_float_uses_teju` — teju output is the kind of thing a round-trip test can
miss.

### KEEP → fold into `test_reflection_serialize.mojo`

- `test_pretty_empty_object`, `test_pretty_empty_array`,
  `test_pretty_nested_empty_object`, `test_pretty_nested_empty_array` — the
  empty-container divergence fixed in Task 4 round 1. No prior coverage.
- `test_large_array_survives_buffer_overflow`,
  `test_large_pretty_array_survives_buffer_overflow` — the Task 10 buffering
  fix. These force multiple internal flushes; nothing else does.
- `test_object_key_needing_escape_is_escaped`,
  `test_non_string_dict_key_is_quoted` — the `serialize_key` fast path added in
  Task 10. New code, new tests.

**File disposition:** delete after folding the 8.

---

## 4. `test_format_deserialize.mojo` — 20 tests → keep 5, drop 15

### DROP

| drop | covered by |
|---|---|
| `test_struct_from_wire` ✅ | `test_reflection_deserialize.test_deserialize` |
| `test_list_from_wire` ✅ | same |
| `test_value_deserialize_scalar_int/uint/float/string/bool/null` (6) ✅ | `test_value.mojo` — `test_integer`, `test_float`, `test_string`, `test_bool`, `test_null` |
| `test_array_deserialize_direct`, `test_array_deserialize_empty` ✅ | `test_array.mojo` (17) |
| `test_object_deserialize_direct`, `test_object_deserialize_empty` ✅ | `test_object.mojo` (26) |
| `test_two_char_field_name_binds` ✅ | artefact of a relay error in fix round 1 — it exists only because a backslash was dropped when I relayed the repro. Pure noise. |
| `test_missing_field_reports_kind_and_path` ✅ | duplicated verbatim in `test_public_api_typed_errors.mojo` |
| `test_error_path_points_at_nested_field` ✅ | same |

### KEEP → fold into `test_reflection_deserialize.mojo`

- `test_escaped_field_name_binds` — ⚠️ overlaps
  `test_mixed_lazy.test_escaped_field_keys_still_match`; keep **one** of the two,
  and prefer this one since it was the regression's actual repro.
- `test_ordinary_unescaped_key_still_binds` — guards the fast path the escape
  fix could have broken.
- `test_deserialize_any_returns_object_value` — `SelfDescribingDeserializer`, new.
- `test_null_deserialize_round_trips`, `test_null_deserialize_rejects_non_null`
  — `Null.deserialize` was new code with a raise path nothing else executes.

**File disposition:** delete after folding the 5.

---

## 5. The two facade files — 37 tests → keep ~15, merge into one

`test_public_entry_points.mojo` (18) should never have been created.
`test_public_api_typed_errors.mojo` (19) already owned that topic, and
emberserde's own CLAUDE.md states the rule: *"Add coverage to the existing test
file that already owns the topic — don't spin up a new `test_*.mojo`."*

### DROP outright

- `test_try_parse_returns_none_on_invalid_utf8` ✅ — **exists verbatim in both
  files** with identical assertions.
- `test_parse_rejects_invalid_utf8` ✅ → `test_parse_invalid_utf8_reports_exact_message_and_kind`.
- `test_valid_multibyte_input_passes_every_public_entry_point` ⚠️ →
  `test_utf8.test_valid_sequences`, `test_corpus_is_valid`.
- `test_serialize_struct_round_trips_through_the_facade` ✅,
  `test_to_string_agrees_with_serialize_on_a_value` ✅ →
  `test_serialize_round_trips`, `test_to_string_round_trips`.
- `test_serialize_pretty_through_the_facade`, `test_to_string_pretty_through_the_facade` ⚠️
  → `test_reflection_serialize.test_pretty_serialize`.
- `test_serialize_empty_containers_through_the_facade` ✅ → the kept
  `test_pretty_empty_*` from §3.
- `test_object_serialize_preserves_insertion_order` ⚠️ → `test_object.mojo` (26
  tests) almost certainly pins ordering already — **verify**.
- `test_serialize_bytes_honors_pretty` — **KEEP**, it pins the Task 10 fix.
- `test_deserialize_ignores_unknown_field_by_default` /
  `test_deserialize_unknown_field_reports_unknown_field_kind` — **KEEP both**,
  they pin the permissiveness change and its `DenyUnknownFields` opt-in.

### KEEP — the `ParseOptions` channel (6, all genuinely new)

`test_deserialize_decodes_unicode_escapes_by_default`,
`test_deserialize_ignore_unicode_option_reaches_the_parser`,
`test_deserialize_strict_mode_option_reaches_the_parser`,
`test_deserialize_validate_utf8_option_can_be_turned_off`,
`test_try_deserialize_threads_options_too`,
`test_options_default_matches_the_no_options_spelling`.

Plus `test_the_private_format_layer_does_not_validate_utf8` and
`test_parse_accepts_invalid_utf8_when_validation_is_off` — both pin real
asymmetries.

### KEEP from the typed-errors file

The `kind`/`path` tests (`missing_field`, `type_mismatch`, `duplicate_field`,
`populates_path_for_nested_failure`, `path_reaches_through_two_levels`) and the
`try_*`-returns-`None` trio. Typed errors are new public behaviour.

**File disposition:** merge both into `test_public_api_typed_errors.mojo`,
delete `test_public_entry_points.mojo`.

---

## 6. `test_field_reexport.mojo` — 2 tests → keep both

Tiny, and pins a bug that was *masked by its own test file* until the final
review caught it (`from emberjson import Field; f[]` failing in isolation). Its
whole point is importing **only** the facade, so it must not be folded into a
file that also imports `emberjson.schema` — that would recreate the masking.

**File disposition:** keep as-is. It is 36 lines.

---

## Summary

| file | now | keep | disposition |
|---|---|---|---|
| `test_schema_fields.mojo` | 31 | 9 | fold → `test_schema.mojo`, delete |
| `test_borrow_lazy.mojo` | 29 | 23 | keep as its own file |
| `test_format_serialize.mojo` | 24 | 8 | fold → `test_reflection_serialize.mojo`, delete |
| `test_format_deserialize.mojo` | 20 | 5 | fold → `test_reflection_deserialize.mojo`, delete |
| `test_public_api_typed_errors.mojo` | 19 | ~13 | absorbs the other facade file |
| `test_public_entry_points.mojo` | 18 | ~8 | merge in, delete |
| `test_field_reexport.mojo` | 2 | 2 | keep as-is |
| **total** | **143** | **~68** | 4 files deleted, suite 444 → ~369 |

## Method for executing this

Delete by *behaviour*, not by name. For every proposed deletion:

1. Name the surviving test that covers the same behaviour.
2. Confirm it reaches the same code — after Task 8 the public API routes to
   `_serde`, so a public-API test does exercise the new layer.
3. Resolve every ⚠️ by reading both bodies before removing anything.
4. Delete in small commits, running the suite after each, so a coverage loss is
   attributable.

The 299 pre-existing tests are the load-bearing evidence that this migration
preserved behaviour — they were written before the new implementation existed.
Nothing in this audit touches them.


---

# EXECUTION RESULT + CORRECTION TO THIS AUDIT

**Executed:** 444 → 404 tests, 2 files deleted, 1 file merged away.

| step | change |
|---|---|
| `test_schema_fields.mojo` deleted, 5 folded into `test_schema.mojo` | −26 |
| 5 duplicate `Lazy` alias tests dropped from `test_borrow_lazy.mojo` | −5 |
| 5 confirmed duplicates dropped from `test_format_deserialize.mojo` | −5 |
| the two facade files merged, 4 dropped, 1 relocated to `test_object.mojo` | −4 |

## This audit over-claimed. Two corrections found while executing:

**1. The `Default` cluster was already folded.** The audit proposed keeping 10
tests from `test_schema_fields.mojo`; reading `test_default`'s body showed the
final fix wave had *already* folded present-key-wins, null-raises, both
`Optional` halves **and** in-struct fill into it (`d1`–`d4`). Only 5 survived.

**2. The audit's core premise does not hold for `Value`/`Object`/`Array`.**
The premise was: *the pre-existing suite covers this, because the public API now
routes to `_serde`.* That is true for structs and schema wrappers —
`test_schema.mojo` and `test_reflection_*.mojo` genuinely call
`deserialize`/`serialize`. It is **false** for the core JSON types:

- `test_value.mojo` calls `serialize`/`to_string` **zero times**. Its
  `test_pretty` uses `write_pretty` (the `PrettyPrintable` path).
- `test_roundtrip.mojo` asserts `String(json) == src` — that is `write_to`
  (the `Writable` path).
- On the read side it builds via `Value(parse_string=...)` — the parser
  directly, not `deserialize[Value]`.

`Writable`, `PrettyPrintable` and `Serializable` are three separate code paths
on the same types. So the ~16 byte-exact serde-path pins in
`test_format_serialize.mojo` and the `Value`/`Array`/`Object` cases in
`test_format_deserialize.mojo` cover something the pre-existing suite never
touched. **They were kept.** Deleting them on the audit's original reasoning
would have removed the only coverage of `Value`-through-serde.

Revised verdict: of 143 new tests, **~103 earn their place**, not ~68. The
excess was real but roughly half the size the audit first claimed.

## Still open (not executed)

- `test_format_serialize.mojo` (24) and `test_format_deserialize.mojo` (15)
  remain as separate files. Their names say "format", but post-deletion they
  are really "`Value`/`Object`/`Array` through the serde path" — worth renaming
  rather than merging, since no existing file owns that topic.
- `test_borrow_lazy.mojo` (24) stays; `raw_bytes` is genuinely new surface.
