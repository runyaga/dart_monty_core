# AGENTS.md: build, test, gate

dart_monty_core runs Python (upstream `pydantic/monty`) from Dart. The worker
stack (`native/worker/`, `lib/src/worker/`) runs it in a worker process
(native) or a worker module (browser), on three Dart compilers (VM, dart2js,
dart2wasm). Sections 1 to 8 target that stack. Section 9 covers the older
FFI/WASM engine (`native/src/`, `js/`), which is still in the tree. Commands
come first.

## 1. Fresh clone: three commands

```bash
dart pub get                     # root only (see the note on packages/monty_conformance)
bash tool/build_worker.sh        # builds the worker binary; ~4 min cold. Needs rustup
dart test --exclude-tags=ffi,wasm,integration,ladder,example,worker   # ~6 s
```

- The worker binary lands in `lib/src/bin/<os>-<arch>/` (gitignored). Rebuild
  it after any change under `native/worker/`; `bash tool/build_worker.sh --check`
  fails if it is stale.
- Tools needed: Dart SDK (pinned, see section 8), Rust via rustup (the channel
  comes from `native/rust-toolchain.toml`) plus `cargo-deny` (`cargo install cargo-deny --locked`;
  `tool/gate.sh` runs `cargo deny check`), Chrome for web tests, Python 3.11+ (CI uses 3.12; the worker build and
  mirror check call `python3`), and Node 22+
  for the Pages driver in the gate (CI uses Node 24; Node 20 lacks the global
  `WebSocket` it needs).
- Observed on macOS arm64, Dart 3.13.5: after `dart pub get` inside
  `packages/monty_conformance`, `dart format` rewrote three files there. The root run is enough.
- Optional, once: `bash tool/install-hooks.sh` (fast pre-commit subset; it is
  not the gate).

## 2. Which test command for which change

| You changed | Run | Time |
|---|---|---|
| Pure-Dart library code | the unit command from section 1 | ~6 s |
| One test file | `dart test path/to_test.dart` (`-N "name substring"` is a plain-text filter; `-n` takes a regex, anchor it for an exact match) | s |
| Code that also compiles for the web | the same file with `-p chrome -c dart2js`, then `-c dart2wasm` | s |
| Worker channel, pool, session | `bash tool/test_worker_web.sh` (Chrome, both compilers) and `dart test test/integration/worker -p vm --tags=worker` | 20 s / 45 s |
| Anything the upstream corpus covers | `bash tool/test_corpus_worker.sh native` (browser legs: `chrome dart2js`, `firefox dart2wasm`, ...) | 10 s |
| `native/worker/` Rust | `bash tool/build_worker.sh`, then `cd native/worker && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked --release` | min |
| Anything, before you push | `bash tool/gate.sh`, then commit and run `bash tool/dcm_host_gate.sh` on the host (it checks committed `HEAD`; section 4) | min |

A feature needs both a VM runner (`test/integration/worker/*_io_test.dart`) and
a web runner (`test/unit/worker/*_web_test.dart`); they share helper files such
as `_config_cases.dart`, `_host_cases.dart` and `_restore_cases.dart`. A missing
runner leaves that platform untested. Do not edit the tree while
`tool/gate.sh` runs: the web run can load half-written files, and the gate's
`read_only_tree` step reports a change in `git status`.

Before writing a test, read `docs/contributor/testing-philosophy.md`; before
trusting a green run, read `docs/contributor/testing-runbook.md`.

## 3. Test-count floors

A run whose tests are all skipped can still exit 0, and a filter or import
break can silently shrink a suite, so every suite has a floor under its test
count. Raise a floor when a suite grows (set it just below
the observed count); never lower one to make a run pass. They live in:

- `tool/gate.sh`: `sf unit_tests 700`, `sf unit_web 1400`, `sf worker_vm 165`;
- `tool/test_worker_web.sh`: `FLOOR=230` (per compiler);
- `tool/test_corpus_worker.sh`: the `floor=` values per leg;
- `.github/workflows/ci.yaml`: the `assert_test_count.sh` calls (same numbers).

Change the gate and CI floors in the same PR. Adding web worker tests usually
means bumping `tool/test_worker_web.sh`.

## 4. Gates CI does not run

| Check | How | Why it is local |
|---|---|---|
| DCM lint ratchet | `bash tool/dcm_host_gate.sh` (host, not container; it analyses a detached worktree at committed `HEAD`, so commit first) | commercial licence; `tool/gate.sh` prints SKIP for `dcm_ratchet` and `metrics_ratch` inside a container |
| DCM metrics ratchet | same script | same |
| DCM exclusions | `bash tool/check_dcm_exclusions.sh --deep` | needs DCM |
| Container reaper | `bash tool/dmc_container.sh check` | only meaningful in the gate container |

- A DCM ratchet fails on any issue above `tool/dcm-baseline.json` and
  `tool/metrics-baseline.json`. Before treating a red as yours, run the same
  script on a clean checkout of `origin/main` and diff the output. The
  ratchets fail in both directions: a fix that removes baselined issues must
  lower the baseline in the same commit (`--update`), while deliberately
  relaxing a baseline goes in its own commit with a reason.
- `metrics_ratchet` counts violations of dcm's thresholds (`dcm_options.yaml`:
  15 methods per class); the baseline grandfathers existing ones. Split a class
  that crosses the threshold instead of raising the baseline.
- A skip (exit 77, `SKIP` in `SUMMARY.txt`) is green but checked nothing.

Other gate notes (these also run in CI): `dart format` is SDK-version
sensitive, so `bash tool/check_sdk_pin.sh` fails when your `dart` is not the
pinned one; `bash tool/check_pages.sh` needs a free local port, so rerun
`pages_render` alone if it flakes on a busy machine.

## 5. Generated files: regenerate, never hand-edit

| File | Regenerate | Verify |
|---|---|---|
| `test/unit/worker/_*_oracle.g.dart` (config, host, restore, worker_class, print) | `PY -I tool/generate_<name>_oracle.py` | same with `--check` |
| `test/unit/worker/_display_fixtures.g.dart` | `python3 -I tool/generate_display_fixtures.py <parity checkout>` | same with `--check` |
| `lib/src/bin/*/dart_monty_worker` | `bash tool/build_worker.sh` | `--check` |
| `tool/export-golden.txt` | `dart --packages=.dart_tool/package_config.json tool/check_export_boundary.dart --update` | same without `--update` |
| `tool/coverage-baseline.json` | maintainer-run `tool/record_coverage_baseline.sh`, from main's successful CI artifact | never in a PR |

`PY` is a Python 3.12 with upstream's oracle installed from the hash-pinned
lock. `bash tool/check_oracles.sh` builds a cached `.venv-oracle` (gitignored)
and runs `--check` on every `tool/generate_*_oracle.py`; the gate runs it as
`oracle_check` and CI runs it too (`dart pub get` first). To regenerate one
file, use that venv's Python:

```bash
.venv-oracle/bin/python -I tool/generate_host_oracle.py          # write
.venv-oracle/bin/python -I tool/generate_host_oracle.py --check  # exit 1 if stale
```

An oracle file's cases and the Dart runner (`_*_cases.dart`) change together.

## 6. Baselines, fragments, pins

- **Do not edit** `tool/coverage-baseline.json` in a PR, under any label. Do
  not edit `CHANGELOG.md` either, unless the PR carries the `changelog-assembly`
  label (release assembly only; `no-changelog` exempts the fragment
  requirement, not this). Record the
  change as `changes/<slug>.md` (format in `changes/README.md`;
  `dart tool/changelog_assemble.dart --dry-run` previews assembly). Editing the
  PR body re-runs the fragment check; a cancelled duplicate shows red until
  superseded, so edit the body before the last push.
- **Coverage ratchet** (`tool/coverage_ratchet.sh`) fails on any per-file
  decrease and on a baseline file that vanished. A deleted file is accepted
  only through the base-ref rule (`tool/ci_ratchet_base.sh`); there is no
  override. Add tests for lines a deleted test used to cover.
- **Parity pin.** `PARITY_PIN` in `.github/workflows/ci.yaml` is a full SHA of
  the parity suite (`dart_monty_parity`). The `Parity` and `Parity E0` jobs
  fail when a PR renames an API the pinned suite uses. Order: change the
  suite first, merge it, then bump `PARITY_PIN` (one line plus a fragment).
- **Strict required checks.** Branch protection on main requires a PR branch
  to be up to date with main before it can merge.
- **Upstream pin.** `tool/upstream/upstream-pin.json` is the single source for
  the upstream version, tag and commit; `tool/check_upstream_pin.py` and
  `tool/check_worker_mirror.py --local` verify the worker crate mirrors it.

## 7. Common failures and fixes

| Symptom | Fix |
|---|---|
| `build_worker: ... is STALE` or worker tests run old code | `bash tool/build_worker.sh` |
| `dart test` finds no worker binary | `bash tool/build_worker.sh` |
| CI job `Parity E0` fails on a rename | section 6, parity pin order |
| `dcm_ratchet` red on code you did not touch | compare with clean `origin/main`; it is a known baseline |
| `unit_tests: ran N < floor` | a tag filter or import broke; section 3 |
| `Changelog fragment` failing | add `changes/<slug>.md`, or label `no-changelog` |
| A test hangs 30 s then fails "after test completion" | a settle-loop deadline; read the first failure, not the second |

## 8. Toolchain pins

- **Dart SDK is pinned** (`sdk: 3.13.5`) in every workflow, including
  `deploy-pages.yml`, and tracks current stable: when a new stable ships, bump
  all pins in one commit. `dart format` output differs between SDKs, so a
  floating pin cannot tell a break from a moved world.
- **Rust is not pinned**: `native/rust-toolchain.toml` says `stable`. A new
  rustc can change codegen stack use and add clippy lints. The worker therefore
  fixes its own stack: 2 MiB on wasm32 (`native/worker/build.rs`).
- GitHub Actions are pinned by SHA (`tool/check_action_pins.sh`).

## 9. The older FFI/WASM engine

Still in the tree and still built by CI: the `native/` crate (`native/src/`),
the JS bridge in `js/`, `hook/build.dart`, `test/integration/ffi_*_test.dart`
and `wasm_*_test.dart`, and the committed bundle in `lib/assets/`.

```
native/src/  (Rust crate)
  cargo build --release           -> libdart_monty_core_native.{dylib,so} / dart_monty_core_native.dll  [FFI]
  cargo build --bin oracle        -> native/target/debug/oracle
  cargo build --target wasm32-wasip1 --release -> dart_monty_core_native.wasm  [WASM]
js/src/  (esbuild via node build.js) -> bridge and worker JS
lib/assets/   committed generated assets (ships on pub.dev; web consumers need no Rust)
```

```bash
bash tool/prebuild.sh        # rebuilds the generated files under lib/assets/ (the proto worker JS is handwritten)
rustup target add wasm32-wasip1   # once; the wasm scripts add it themselves
```

- `lib/assets/` is where `prebuild.sh` puts committed generated assets (build
  intermediates go to `native/target/` and `native/worker/target/`), and it also re-records `tool/wasm-provenance.json`. After editing
  `native/` or `js/`, run
  `bash tool/prebuild.sh && git add lib/assets/ tool/wasm-provenance.json`.
- Changing `native/include/dart_monty.h` means `bash tool/generate_bindings.sh`.
- The FFI dylib is not shipped: `hook/build.dart` builds it from source on the
  consumer's machine (desktop triples only; iOS and Android emit no asset). It
  needs a C linker (`xcode-select --install`, `apt install build-essential`, or
  VS Build Tools with C++).
- Publishing: `publish.yaml` fires on a tag push matching `v[0-9]+.[0-9]+.[0-9]+*`
  and publishes via OIDC.

| Symptom | Fix |
|---|---|
| `no default linker (cc)` on `pub get` | install a C linker (above) |
| FFI `ProcessException` on oracle | `cd native && cargo build --bin oracle` |
| `lib/assets/` stale after editing `native/` or `js/` | `bash tool/prebuild.sh && git add lib/assets/ tool/wasm-provenance.json` |
| Bindings stale check fails in CI | `bash tool/generate_bindings.sh` |
