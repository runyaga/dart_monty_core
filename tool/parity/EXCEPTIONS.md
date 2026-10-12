# Parity named exceptions and rule choices

Every difference the parity scorer tolerates is a named exception in `tool/parity/rows.json`, with the
stable ID used below. Nothing else is tolerated, and an exception applies to a case only when the
difference it names is actually present in that case. Evidence is in the `parity-baseline` CI
artifact (`<case>/core-<backend>.json`) against `tool/parity/expected/<case>/`.

**Why each one matters (measured):** with no exceptions, core `5873ec5` on arm64 scores FFI PRESENT
33/185 (dart2js 32, dart2wasm 32) instead of the recorded 37/36/36. Every exception changes at least one
row's status, and four of the 37 PRESENT rows rely on one: `host_eager_attributes`, `memory_filesystem`,
`callback_files`, `resolve_pending_futures`.

## Named exceptions

| ID | Rows (cases) | Fields | Observed difference | Rationale | Without it | Removed when |
|---|---|---|---|---|---|---|
| `placeholder-type` | `lossy_output_placeholders` (`v_cycle_list`, `v_cycle_dict`, `v_function`, `v_repr`) | value type tag | core `{"t":"opaque","kind":"cycle","v":"[...]"}`; upstream `{"t":"str","v":"[...]"}`, same text | upstream's binding exports repr/cycle/function placeholders as plain `str`; core carries the same text in a typed wrapper. The re-entry cases (`r_cycle`, `r_function`) still differ, so the row stays PARTIAL | ABSENT (recorded PARTIAL) | core returns placeholders as `str` |
| `identity-only` | `boundary_value_graph` (`v_alias`, `v_alias_nested`, `i_alias`) | value identity | upstream marks a shared sub-object once (id/ref); core's decoded tree repeats it as equal copies | values compared with identity markers resolved. Cases that test identity itself (`i_alias_is`, `r_alias`) are compared in full and still differ | ABSENT (recorded PARTIAL) | core preserves sharing |
| `host-calls-not-compared` | `host_eager_attributes` (`h_x01_eager_all`, `h_x02_eager_list`, `h_x03_eager_none`) | host-call transcript | upstream logs `convert_value` events and a method call on the granted object; core has no conversion hook and reports the method call without a receiver. Values, exceptions and prints are equal | the row is the eager attribute values; the transcript differences belong to `host_value_conversion_hook` and `host_method_dispatch` | ABSENT (recorded **PRESENT**) | core routes host-object calls by receiver and has a conversion hook |
| `rename-missing-message` | `memory_filesystem` (`b11fs_rename_missing`) | exception message | core `No such file or directory: '/data/nope' -> '/data/z.txt'`; upstream OSAccess `No such file or directory: '/data/nope'`. Same type | every other in-memory filesystem case is equal (58/59); core's wording matches upstream `MountDir` | PARTIAL (recorded **PRESENT**) | core uses OSAccess's wording |
| `call-host-is-core-default` | `os_calendar_calls`, `clock_source` (`b14_date_callhost`) | "case config applied" | the case's `os_policy` `call_host` is recorded as unsupported (no OsPolicy API); value and OS-call transcript are equal | `call_host` is the only behaviour core has, so the unsupported policy changes nothing in this case; other policy cases still differ | ABSENT (recorded PARTIAL) | core exposes OsPolicy |
| `limit-wording` | `feed_execution_limit` (`l06_feed_timeout`, FFI) | exception message | `time limit exceeded: …` vs upstream `feed time limit exceeded: …`. Same type (TimeoutError) | a feed timeout fires with upstream's type; the per-feed reset cases (`l08`, `l09`) still differ | ABSENT on vm (recorded PARTIAL) | core's limits follow 1.x feed/turn semantics |
| `payload-host-type` | `callback_files` (probe `api_callback_files`) | the write event's `type` field | Python `str` (pydantic-monty `CallbackFile`) vs core `VfsText`; path, text, values and order are equal | the host language's type name for the same payload, not sandbox behaviour | ABSENT (recorded **PRESENT**) | not expected (inherently per binding) |
| `no-suspension-position` | `run_progress_variants`, `resume_os_call`, `resolve_pending_futures`, `feed_repl_suspendable` (their probes) | suspension `position` | core `null`; upstream filename + byte range | core exposes no suspension position, which `suspension_source_position` measures on its own (ABSENT); these rows compare kind, name, args, kwargs, resumed values and errors | ABSENT (recorded PARTIAL ×3, **PRESENT** for `resolve_pending_futures`) | core reports suspension positions |

## Rule choices

Not exceptions, but they decide statuses:

| Rows | Rule | Why |
|---|---|---|
| `memory_filesystem` | oracle is upstream's `OSAccess`+`MemoryFile` (`refmem-py.json`); compares value, exception type and message | the row is the in-memory filesystem; upstream's in-memory filesystem is the comparable oracle |
| `interactive_continuation`, `compile_program`, `compiled_source` | oracle is upstream `monty`'s Rust API at the pinned commit (`ref-rust.json`) | no upstream binding exposes them |
| `file_mode_inspection`, `file_handle_value_conversion` | value and exception only, not the OS-call transcript | path-type differences in transcripts (str vs PurePosixPath) belong to `os_callback_adapter` |
| `raised_exception` / `traceback_frames` | exception type + message / frames only, over the 273 `b12_*` cases | each row is one part of an exception |
| `host_class_type_proxy` | REFUSED when core raises "a type cannot be sent back" or cannot build a class value at all | both are core refusing a type object |
| `turn_execution_limit`, `host_sleep_budget`, `garbage_collection_interval`, `host_suspension_budget` | ABSENT, not REFUSED, when the limit has no `MontyLimits` field | a missing knob is absence, even where the web backend refuses session limits |
| `resume_os_call` | the not-handled probe records core's public substitute (`osCallNoHandlerDefault` + `resumeWithException`) as `unsupported` | core has no not-handled verb; reproducing upstream's error with a substitute is not parity of the API |
| `os_entry_removal` | no exception | its one cross-platform difference (`b11fs_unlink_dir`) is upstream `MountDir` following the macOS errno; on the committed Linux expectations core matches |
| `boolean_integer_values` | no exception | core's own cases match |

## Per-architecture expectations

Not an exception: recorded as measured. On x86_64, core returns `float("nan")` with the sign bit set
(`fff8000000000000`; upstream `7ff8000000000000`, observable in Python via `math.copysign`) on the VM and
dart2wasm, so `float_values` is PARTIAL there: FFI PRESENT 36/185, dart2js 36, dart2wasm 35. On arm64 (the
platform the manifest baseline was measured on) it is 37/36/36. `rows.json` and `baseline-current.json`
record both under `platforms`; any other deviation fails. Removed when core canonicalises NaN to upstream's
bits.
