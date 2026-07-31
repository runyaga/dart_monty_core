# AGENTS.md — dart_monty_core build & test guide

Reference for two audiences: **(1) consumers compiling `dart_monty_core`
from source** (see Toolchain prerequisites below), and **(2) maintainers**
building, testing, and releasing this package.

## Toolchain prerequisites

| Need | macOS | Linux | Windows |
|---|---|---|---|
| Rust | rustup.rs | rustup.rs | rustup.rs |
| C linker | `xcode-select --install` | `apt install build-essential` | VS Build Tools w/ C++ |
| Dart SDK ≥ 3.10 | `brew install dart` | dart.dev/get-dart | dart.dev/get-dart |
| Web tests | Node 20+ + Chrome | Node 20+ + Chrome | Node 20+ + Chrome |

Maintainers also need the WASM target for rebuilding `lib/assets/`:

```bash
rustup target add wasm32-wasip1
```

`dart_monty_core` does **not** ship pre-built FFI dylibs — they're built
from source on every consumer's machine via `hook/build.dart`. The hook
supports desktop triples only (macOS / Linux / Windows × arm64 + x64);
iOS and Android fall through with no asset emitted. WASM consumers get
pre-built artefacts from `lib/assets/` (Mode A). When using
`dart_monty_core` directly, mobile (iOS / Android) compilation is the
consumer's responsibility — they compile the native crate and wire it
into their Flutter plugin themselves.
[`dart_monty`](https://github.com/runyaga/dart_monty) is the higher-level
Flutter wrapper for consumers who want the integration layer instead.

## Architecture

```
native/src/  (Rust crate: lib, convert, error, handle, repl_handle)
  ├─ cargo build --release           → libdart_monty_core_native.{dylib,so,dll}   [FFI]
  ├─ cargo build --bin oracle        → native/target/debug/oracle              [oracle]
  └─ cargo build --target wasm32     → dart_monty_core_native.wasm             [WASM]
                                              │
js/src/  (esbuild via node build.js)          ▼
  ├─ bridge.js (main thread)       ┐
  └─ worker_src.js + wasm_glue     ┴── lib/assets/  (committed; ships on pub.dev)
```

`lib/assets/` is the only directory that receives build output. Everything
else copies from it. The three files there are committed to git so web
consumers don't need a Rust toolchain.

## Repository layout

```
native/                       Rust shim (5 source files; cargo crate)
js/                           JS bridge source (esbuild)
lib/                          Dart library; lib/assets/ is the committed JS+WASM bundle
hook/                         native-assets build hook (cargo on consumer pub get)
test/unit/                    pure-Dart unit tests (functional)
test/integration/             FFI + WASM integration + oracle conformance
  ├── ffi_*_test.dart         FFI feature tests
  ├── wasm_*_test.dart        WASM feature tests (mirror of ffi_*)
  ├── oracle_ffi_*_test.dart  oracle conformance (531 fixtures)
  ├── wasm_runner*.dart       WASM corpus runners (dart2js + dart2wasm)
  └── repros/                 xfail repros + _xfail.dart helper
test/fixtures/                test data (corpus symlink + side-loadable .py repros)
packages/dart_monty_web/      browser REPL demo (pure Dart web)
tool/                         maintainer scripts (prebuild, test_wasm, …)
.github/workflows/            ci.yaml, publish.yaml, deploy-pages.yml,
                              pr-labeler.yml, trufflehog.yaml,
                              upstream-monty-check.yaml
```

## Build

```bash
bash tool/prebuild.sh                 # rebuilds everything under lib/assets/
```

Or do steps manually:

```bash
cd native
cargo build --release                                  # FFI dylib
cargo build --bin oracle                               # oracle binary
cargo build --target wasm32-wasip1 --release           # WASM binary
cd ../js && npm install --force && node build.js       # JS bridge → lib/assets/

# WASM tests + web demo also need the WASI runtime (esbuild doesn't copy it):
cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
   test/integration/web/@pydantic/monty-wasm32-wasi/
```

If you change `native/include/dart_monty.h`, regenerate bindings:
`bash tool/generate_bindings.sh`.

## Tests

**Before you write a test**, you must be able to name three things — the break
you applied and saw go red, where the expected value came from, and what your
reference shares with the code it checks (the answer must be nothing).
[`docs/contributor/testing-philosophy.md`](docs/contributor/testing-philosophy.md)
says why each one has bitten this repo.

**Before you run tests**, read
[`docs/contributor/testing-runbook.md`](docs/contributor/testing-runbook.md):
nine mechanisms, what each verifies, what each *cannot* verify, and the traps
that make a green run meaningless.

The commit gate is `bash tool/gate.sh` — a red step means do not commit, even
when it looks unrelated to your change.

Test layout: `test/unit/` is pure Dart. `test/integration/{ffi,wasm}_*_test.dart`
pair up per feature and share a `_<feature>_test_body.dart`, so a new feature
needs **both** runners — a missing one runs nowhere, which has happened twice.

## Static checks

Commands and the DCM-ratchet rationale live in the runbook
([mechanisms 7 and 8](docs/contributor/testing-runbook.md)). In short: `dcm`
has a known non-zero baseline, so a clean run was never the bar —
`tool/dcm_ratchet.sh` fails on any *new* issue above `tool/dcm-baseline.json`,
and `--update` is a deliberate act that belongs in its own commit with a reason.

## Demos

```bash
bash tool/serve_demo.sh              # dart2js, opens :8098
bash tool/serve_demo.sh --dart2wasm
bash tool/serve_demo.sh --skip-build
```

GitHub Pages auto-deploys from `main` via `deploy-pages.yml`.
URL: https://runyaga.github.io/dart_monty_core/

There is no in-tree Flutter demo — the previous `dart_monty_flutter`
sidecar was removed under the Mode A asset refactor. Flutter examples
belong in `dart_monty`.

## CI

- `ci.yaml` — analyze, format, **DCM ratchet**, FFI feature + oracle, WASM
  (dart2js + dart2wasm), Rust fmt/clippy/deny/coverage, patch-coverage 70%
  gate. Runs on PRs and `main`.
- **The Dart SDK is pinned** (`sdk: 3.11.4`) in `ci.yaml` and `publish.yaml`.
  It was `stable`, which floats: `dart format` passed in June and failed later
  on the *same commit* because a newer Dart reformatted the ffigen output. A
  gate whose inputs float cannot tell "we broke it" from "the world moved".
  Bump the pin deliberately, as its own commit. (`deploy-pages.yml` stays on
  `stable` — docs build, not a gate.)
- `publish.yaml` — fires on tag push matching
  `v[0-9]+.[0-9]+.[0-9]+*`; analyze → dry-run → `pub publish --force`
  via OIDC.
- `deploy-pages.yml` — `main` → GitHub Pages.

Artifact hand-offs: `ffigen` → `dart_monty_bindings.dart`; `build-wasm`
→ `dart_monty_core_native.wasm`; `test` → `lcov.info`.

## Releasing

Versioning: `0.X.0 ↔ monty v0.0.X`. When upstream ships `monty v0.0.N`,
bump the git tag on all three `monty*` deps in `native/Cargo.toml`
(they must move together), verify conformance, then ship
`dart_monty_core 0.N.0`. Patch releases (`0.X.Y`, Y>0) are reserved
for our own fixes between upstream bumps. Pre-1.0: consumers pin exact
(`dart_monty_core: 0.19.0`, not `^0.19.0`).

Current: `0.19.0 ↔ monty v0.0.19`.

**First publish of a new package must be manual** — pub.dev rejects
OIDC for packages that don't yet exist:

```bash
git pull origin main
dart pub publish --dry-run
dart pub publish               # browser OAuth, then 'y' to confirm
```

After the first publish, tag pushes auto-publish via `publish.yaml`:

```bash
# Bump pubspec.yaml version + CHANGELOG, commit, push, then:
git tag v0.19.0 && git push origin v0.19.0
```

## Common failure modes

| Symptom | Fix |
|---|---|
| `EBADPLATFORM` on `npm install` | `npm install --force` |
| `no default linker (cc)` on `pub get` | Install C linker (see prereqs) |
| Chrome `TypeError: … 'init'` | Copy `wasi-worker-browser.mjs` (see Build) |
| FFI `DynamicLibraryLoadError` | `cd native && cargo build --release` |
| FFI `ProcessException` on oracle | `cd native && cargo build --bin oracle` |
| `Unknown experiment: native-assets` | Update Dart SDK to ≥ 3.10 |
| `Only users are allowed to upload new packages` | First pub.dev publish must be interactive |
| `lib/assets/` stale after editing `native/` or `js/` | `bash tool/prebuild.sh && git add lib/assets/` |
| Bindings stale check fails in CI | `bash tool/generate_bindings.sh` |

