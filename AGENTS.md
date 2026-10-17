# AGENTS.md: build, test, gate

dart_monty_core runs Python (upstream `pydantic/monty`) from Dart. The worker
stack (`native/worker/`, `lib/src/worker/`) runs it in a worker process
(native) or a worker module (browser), on three Dart compilers (VM, dart2js,
dart2wasm). Commands come first.

## 1. Fresh clone: three commands

```bash
dart pub get                     # root only (see the note on packages/monty_conformance)
bash tool/build_worker.sh        # builds the worker binary; ~4 min cold. Needs rustup
dart test --exclude-tags=integration,ladder,example,worker   # ~6 s
```

- The worker executable and host mount-service cdylib land in
  `lib/src/bin/<os>-<arch>/` (gitignored): `dart_monty_worker` (Windows: `.exe`)
  and `libdart_monty_worker.dylib` / `.so` / `dart_monty_worker.dll`. Rebuild
  it after any change under `native/worker/`; `bash tool/build_worker.sh --check`
  fails if it is stale.
- Tools needed: Dart SDK (pinned, see section 8), Rust via rustup (the channel
  comes from `native/rust-toolchain.toml`) plus `cargo-deny` (`cargo install cargo-deny --locked`;
  `tool/gate.sh` runs `cargo deny check`), Chrome for web tests, Python 3.11+ (CI uses 3.12; the worker build and
  mirror check call `python3`), and Node (CI uses Node 24) for the wasm smoke
  test `tool/test_worker_wasm.mjs`.
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

Host-mount changes also run the VM adjudicator directly:
`dart test test/unit/conformance/mount_fs_adjudicator_test.dart -p vm`.
It runs the two pinned `mount_fs__*.py` fixtures against a real `MountDir` at
`/mnt`, with upstream's temporary host tree and default overlay, plus read-only,
closed-mount and lying-handler negative controls. The native corpus uses the
same host-mount route; its failing set must still equal
`packages/monty_conformance/lib/src/worker_corpus_manifest.dart` in both
directions. Mutation checks of the adjudicator's controls and of the
mount/session transitions are run by maintainers with an external mutation
runner; no per-area runner ships in this repo.

Before writing a test, read `docs/contributor/testing-philosophy.md`; before
trusting a green run, read `docs/contributor/testing-runbook.md`.

## 3. Test-count floors

A run whose tests are all skipped can still exit 0, and a filter or import
break can silently shrink a suite, so every suite has a floor under its test
count. Raise a floor when a suite grows (set it just below
the observed count); never lower one to make a run pass. They live in:

- `tool/gate.sh`: `sf unit_tests 3173`, `sf unit_web 6212`, `sf worker_vm 598`;
- `tool/test_worker_web.sh`: `FLOOR=550` (per compiler);
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
pinned one.

## 5. Generated files: regenerate, never hand-edit

| File | Regenerate | Verify |
|---|---|---|
| `test/unit/worker/_*_oracle.g.dart` (config, host, restore, worker_class, print, os_handler, session) | `PY -I tool/generate_<name>_oracle.py` | same with `--check` |
| `test/unit/worker/_display_fixtures.g.dart` | `python3 -I tool/generate_display_fixtures.py <parity checkout>` | same with `--check` |
| `lib/src/bin/*/dart_monty_worker` | `bash tool/build_worker.sh` | `--check` |
| `tool/export-golden.txt` | `dart --packages=.dart_tool/package_config.json tool/check_export_boundary.dart --post-cutover --update` | same without `--update` |
| `tool/coverage-baseline.json` | maintainer-run `tool/record_coverage_baseline.sh --no-commit`, from main's successful CI artifact | once per release, in the release PR only |

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

- **Do not edit** `tool/coverage-baseline.json` or `CHANGELOG.md` in a PR,
  unless the PR carries the `changelog-assembly` label (the release PR only;
  `no-changelog` exempts the fragment requirement, not this). The coverage
  baseline is refreshed once per release, in the release PR
  (`bash tool/record_coverage_baseline.sh --no-commit` on main, then carry the
  file into the release branch); it is not recorded after every merge. Record the
  change as `changes/<slug>.md` (format in `changes/README.md`;
  `dart tool/changelog_assemble.dart --dry-run` previews assembly). Editing the
  PR body re-runs the fragment check; a cancelled duplicate shows red until
  superseded, so edit the body before the last push.
- **Coverage ratchet** (`tool/coverage_ratchet.sh`) fails on any per-file
  decrease and on a baseline file that vanished. A deleted file is accepted
  only through the base-ref rule (`tool/ci_ratchet_base.sh`), which also covers
  a baseline entry for a file an earlier merge already deleted (the baseline
  is refreshed only once per release); there is no override. Add tests for lines a deleted test used to cover.
- **Parity pin.** `PARITY_PIN` in `.github/workflows/ci.yaml` is a full SHA of
  the parity suite (`dart_monty_parity`). The `Parity` and `Parity E0` jobs
  fail when a PR renames an API the pinned suite uses. Order: change the
  suite first, merge it, then bump `PARITY_PIN` (one line plus a fragment).
- **Strict required checks.** Branch protection on main requires a PR branch
  to be up to date with main before it can merge.
- **Upstream pin.** `tool/upstream/upstream-pin.json` is the single source for
  the upstream version, tag and commit; `tool/check_upstream_pin.py` and
  `tool/check_worker_mirror.py --local` verify the worker crate mirrors it.

### Upstream follow job

The daily `upstream-follow.yaml` job tests first-parent commits from `pydantic/monty` main one at a time and keeps `last_good.json` and `evidence.jsonl` on the `upstream-follow-state` branch without changing `tool/upstream/upstream-pin.json`.

The gate blanks the embedded worker manifest so the built worker is the one tested.

Run it with `workflow_dispatch` to set a commit limit or accept the exact reviewed pending SHA. The gate runs every selected stage and records parity and corpus failures by identifier. A clean first commit records an empty baseline; the first ordinary failure records a baseline and advances. A red commit adds a failure beyond that baseline, stops the job, and opens or updates `Upstream follow: needs attention`. Dispatch with that pending SHA in `accept` to record its new failures and fixes, update the baseline, and advance past it; any other SHA is an error. Stage-level and incomplete gate-report failures are always red and are never baselined. A flagged commit changes a worker mirror file, `.proto`, protocol constant, `test_cases` tree, or workspace version and advances. The weekly digest names the commit that introduces each recorded failure. Use `python3 -I tool/follow_upstream.py run --help` for the local command.

The weekly `upstream-follow-browser.yaml` job rebuilds the wasm worker against
`last_good` and runs the browser corpus and browser parity on the runner's own
Chrome. It never advances `last_good`; a failure fails the job and opens
`Upstream follow: browser parity failed`.

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
| `asset_fresh`: `lib/assets/...wasm is STALE` | `bash tool/prebuild.sh` rebuilds the asset and re-records provenance |
| `worker_size` over budget | the gzip budget is 5.75 MB (`tool/check_worker_wasm_size.sh`); only a deliberate edit there raises it |
| `cargo deny` advisory | fix it, or add a reasoned entry in `native/worker/deny.toml` |

## 8. Toolchain pins

- **Dart SDK is pinned** (`sdk: 3.13.5`) in every workflow, including
  `deploy-pages.yml`, and tracks current stable: when a new stable ships, bump
  all pins in one commit. `dart format` output differs between SDKs, so a
  floating pin cannot tell a break from a moved world.
- **Rust is not pinned**: `native/rust-toolchain.toml` says `stable`. A new
  rustc can change codegen stack use and add clippy lints. The worker therefore
  fixes its own stack: 2 MiB on wasm32 (`native/worker/build.rs`).
- GitHub Actions are pinned by SHA (`tool/check_action_pins.sh`).

## 9. Layout and build

```
native/worker/   Rust worker crate (upstream's `monty subprocess`, mirrored)
lib/             Dart library; lib/assets/ holds the committed browser worker
hook/            native-assets hook: builds the worker only for a root package
                 that opts in (hooks: user_defines: dart_monty_core: build_worker: true)
test/            unit/, integration/worker/, contract/, corpus/, hook/
packages/        monty_conformance (corpus runner), dart_monty_web (stale demo)
tool/            scripts; tool/upstream/ holds pins and the oracle lock
changes/         changelog fragments
```

```bash
bash tool/prebuild.sh            # rebuilds the wasm asset and re-records provenance
bash tool/build_worker.sh        # native worker executable for tests
```

- The browser assets are `lib/assets/dart_monty_core_worker.js` and
  `dart_monty_core_worker.wasm`, committed so web consumers need no Rust. The
  JS loader is handwritten; only the wasm is built. The wasm is not
  byte-reproducible; `tool/check_asset_freshness.sh` checks input
  provenance (`tool/wasm-provenance.json`: a hash of `native/worker/` without
  `target/`, `native/rust-toolchain.toml`, `tool/build_worker_wasm.sh` and
  `tool/rust_remap.sh`), not bytes. Editing `build_worker_wasm.sh` makes the
  asset read stale until it is rebuilt or re-recorded. After a rebuild,
  `git add lib/assets/ tool/wasm-provenance.json`.
- Consumers without the hook opt-in get no native code and must supply a
  worker executable at `workerLocation` (`Monty.start`, `Monty.withPool`).
- Rust checks run in `native/worker/` (`cargo fmt`, `clippy`, `test`, `deny`).

## 10. CI

`ci.yaml` jobs, by what they protect: `gate` (the read-only checks of
`tool/gate.sh`, run by name with a counted total), `test` (unit, JIT + web),
`test-worker-vm`, `test-worker-web`, `worker-rust` (fmt, clippy, test, deny,
wasm smoke), `corpus-worker` and `corpus-worker-web` (upstream corpus, native
and in the browser), `parity`, `parity-e0`, `proto-drift`, `test-aot`,
`upstream-pin`, `coverage-merge` and `patch-coverage` (30% on changed lines,
pull requests only). `consumers.yaml` builds the two web consumer probes under
`tool/consumers/`.

- A `release`-labelled PR, or a `workflow_dispatch` with `force_all: true`,
  overrides the path filter; each job's other conditions still apply (for
  example `patch-coverage` needs a pull request). A skipped job is not green.

## 11. Versions and release

- Version maps from upstream: upstream `1.1.0` is package `0.110.x`; the patch
  is our own fixes on one upstream pin. `tool/check_version_pin.sh` enforces
  the mapping, reads `tool/upstream/upstream-pin.json`, covers
  `native/worker/Cargo.toml`, and refuses an upstream version with a
  component above 9 (the mapping joins three single digits).
- `0.110.0-dev.N` is a pre-release. `publish.yaml` matches `v[0-9]+.[0-9]+.[0-9]+*`
  but excludes `v*-dev.*`; `check_workflows_valid.sh` fails if a dev tag would
  publish.
- Release PR: assemble fragments (`dart tool/changelog_assemble.dart --version X`),
  run `dart pub publish --dry-run` there (it fails on a tree whose CHANGELOG
  lacks the version), then tag. Tags matching the pattern publish via OIDC.
- The first publish of a new package name must be manual.
