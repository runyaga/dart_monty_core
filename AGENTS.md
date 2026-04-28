# AGENTS.md — dart_monty_core build & test guide

Maintainer reference for building, testing, and releasing this package.

## Toolchain prerequisites

| Need | macOS | Linux | Windows |
|---|---|---|---|
| Rust | rustup.rs | rustup.rs | rustup.rs |
| C linker | `xcode-select --install` | `apt install build-essential` | VS Build Tools w/ C++ |
| Dart SDK ≥ 3.10 | `brew install dart` | dart.dev/get-dart | dart.dev/get-dart |
| Web tests | Node 20+ + Chrome | Node 20+ + Chrome | Node 20+ + Chrome |

Cross-compilation targets:

```bash
rustup target add wasm32-wasip1
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios   # iOS
rustup target add aarch64-linux-android x86_64-linux-android armv7-linux-androideabi  # Android (also needs NDK + cargo-ndk)
```

`dart_monty_core` does **not** ship pre-built FFI dylibs — they're built
from source on every consumer's machine via `hook/build.dart`. WASM
consumers get pre-built artefacts from `lib/assets/` (Mode A). Flutter
consumers should depend on
[`dart_monty`](https://github.com/runyaga/dart_monty), which bundles
per-arch binaries.

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
  ├── oracle_ffi_*_test.dart  oracle conformance (464 fixtures)
  ├── wasm_runner*.dart       WASM corpus runners (dart2js + dart2wasm)
  └── repros/                 xfail repros + _xfail.dart helper
test/fixtures/                test data (corpus symlink + side-loadable .py repros)
packages/dart_monty_web/      browser REPL demo (pure Dart web)
tool/                         maintainer scripts (prebuild, test_wasm, …)
.github/workflows/            ci.yaml, publish.yaml, deploy-pages.yml
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

## Tests — three categories

**Functional (`test/unit/`)** — pure Dart, no interpreter, ~50ms.
Covers `MontyValue` (18 subtypes), `MontyResult`, `MontyException`,
the `MontyError` hierarchy, mount handler, REPL metadata.

```bash
dart test --exclude-tags=ffi,wasm,integration,ladder,example
```

**Integration (`test/integration/{ffi,wasm}_*_test.dart`)** —
exercises the real interpreter through one of the two backends. Each
feature usually has `ffi_<feature>_test.dart` and
`wasm_<feature>_test.dart` sharing a `_<feature>_test_body.dart`.

```bash
# FFI
cd native && cargo build --release && cd ..
dart test test/integration/ffi_*_test.dart -p vm --run-skipped --tags=ffi

# WASM (full pipeline; --skip-build to reuse assets)
bash tool/test_wasm.sh
```

**Oracle conformance (`test/integration/oracle_ffi_*_test.dart`)** —
464 Python fixtures × Rust oracle binary vs Dart FFI. Outputs must
match exactly. The same corpus is replayed through WASM via
`wasm_runner.dart` (dart2js) and `wasm_runner_wasm.dart` (dart2wasm),
both driven by `tool/test_wasm.sh`.

```bash
cd native && cargo build --bin oracle && cd ..
dart test test/integration/oracle_ffi_test.dart \
          test/integration/oracle_ffi_ext_test.dart \
  -p vm --run-skipped --tags=ffi
```

**Repros (`test/integration/repros/`)** — side-loadable `.py` + xfail
Dart test pair for each upstream-blocked bug. `xfail()` inverts the
assertion: today the inner expectation fails (bug reproduces), test
passes. When upstream fixes it, `xfail()` raises and CI flags the
test for promotion. Removing the wrapper is the only change needed.

## Static checks

```bash
dart analyze --fatal-infos
dart format --line-length=80 --set-exit-if-changed lib/ test/ hook/ tool/

cd native
cargo fmt --check
cargo clippy -- -D warnings
cargo deny check
cargo llvm-cov --summary-only --ignore-filename-regex 'src/bin/'   # ≥60% gate
```

DCM (code metrics + custom rules) runs in CI only — requires licence keys.

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

- `ci.yaml` — analyze, format, FFI feature + oracle, WASM (dart2js +
  dart2wasm), Rust fmt/clippy/deny/coverage, DCM, patch-coverage 70%
  gate. Runs on PRs and `main`.
- `publish.yaml` — fires on tag push matching
  `v[0-9]+.[0-9]+.[0-9]+*`; analyze → dry-run → `pub publish --force`
  via OIDC.
- `deploy-pages.yml` — `main` → GitHub Pages.

Artifact hand-offs: `ffigen` → `dart_monty_bindings.dart`; `build-wasm`
→ `dart_monty_core_native.wasm`; `test` → `lcov.info`.

## Releasing

Versioning: `0.X.0 ↔ monty v0.0.X`. When upstream ships `monty v0.0.18`,
bump `native/Cargo.toml`'s git tag, verify conformance, then ship
`dart_monty_core 0.18.0`. Patch releases (`0.X.Y`, Y>0) are reserved
for our own fixes between upstream bumps. Pre-1.0: consumers pin exact
(`dart_monty_core: 0.17.0`, not `^0.17.0`).

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
git tag v0.18.0 && git push origin v0.18.0
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

`AGENTS.md` is excluded from pub.dev publish via `.pubignore`.
