# Parity harness

Measures how far dart_monty_core matches upstream [pydantic/monty](https://github.com/pydantic/monty)
1.1.0, per capability row of `tool/upstream/capability-manifest.tsv`, on the Dart VM (FFI), dart2js
and dart2wasm.

| Path | What |
|---|---|
| `cases/<suite>/<id>.json` | parity cases: Python code or REPL feeds, typed inputs, scripted external / OS-call answers, limits, OS policy, mounts, host objects |
| `expected/<id>/` | upstream's outcome for each case and probe: `ref-py.json` (pydantic-monty), `refmem-py.json` (upstream's in-memory filesystem), `ref-rust.json` (upstream monty's Rust API, three Rust-only probes) |
| `manifest.json` | binds every case (sha256) to the expected outcomes generated from it (sha256), plus the sha256 of the generator (the oracle's code) and of the upstream pins |
| `oracle/` | the reference oracle that generates `expected/`: `run_cases.py`, `run_probes.py`, `rust/` |

| `rows.json` | per capability row: its cases or probes, the recorded status per backend, per-architecture expectations, and the named exceptions (stable IDs; full summary in `EXCEPTIONS.md`) |
| `run.py`, `score.py`, `probes_compare.py` | run the cases through core on a backend; score each row against `expected/` |

The Dart runner is `packages/monty_parity`.

## Checks

- **Gate (offline, every change):** `python3 -I tool/check_parity_manifest.py` fails if a case changed
  without its expected outcome being regenerated (or the reverse), an expected outcome changed outside a
  regeneration, or the oracle's code or the upstream pins changed since the outcomes were generated.
- **CI job `parity-oracle`:** regenerates every expected outcome from the hash-pinned oracle and fails on
  any byte of difference. It runs, and is required, whenever a parity input changes (cases, expected
  outcomes, manifest, oracle code, upstream pins, the workflows); otherwise it is shown as skipped and the
  `changes` job's summary says so. It also runs weekly and on demand
  (`.github/workflows/parity-oracle.yaml`).

## Regenerating the expected outcomes

Needed after adding or editing a case, changing the oracle, or moving the upstream pin. Run on
**Linux x86_64** (what CI runs; one case's upstream error, `b11fs_unlink_dir`, follows the host errno and
differs on macOS):

```sh
python3.12 -m venv /tmp/oracle
/tmp/oracle/bin/pip install --require-hashes --only-binary :all: --no-deps -r tool/upstream/requirements.lock
(cd tool/parity/oracle/rust && cargo build --locked --release)

# check: every committed outcome regenerates byte for byte, and the manifest binds them
/tmp/oracle/bin/python -I tool/parity/oracle/check_expected.py \
  --rust tool/parity/oracle/rust/target/release/parity-rust-oracle

# regenerate: rewrites expected/ and manifest.json in one step
/tmp/oracle/bin/python -I tool/parity/oracle/check_expected.py --write \
  --rust tool/parity/oracle/rust/target/release/parity-rust-oracle
```

Review the diff and commit the cases, `expected/` and `manifest.json` together.
