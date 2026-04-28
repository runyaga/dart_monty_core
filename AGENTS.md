# AGENTS.md — dart_monty_core build & test guide

Reference for two audiences: **(1) consumers compiling `dart_monty_core`
0.17.0 from source** (the only path on 0.17.0 — see Toolchain
prerequisites below), and **(2) maintainers** building, testing, and
releasing this package. Once 0.17.1 ships prebuilt binaries (see
"Native binary release pipeline (0.17.1+)" near the end), audience (1)
can skip the Rust toolchain entirely.

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

## Native binary release pipeline (0.17.1+)

Starting at 0.17.1, prebuilt FFI binaries are published as GitHub
Release assets and downloaded by `hook/build.dart` on consumer
machines. Compile-from-source is preserved as a fallback when a network
download fails or when a contributor is iterating on the Rust crate
(presence of `native/Cargo.toml` in the package root is the signal —
see `hook/build.dart`).

### Artefacts shipped per release

| Platform | Triple | File | Approx. size |
|---|---|---|---|
| macOS arm64 | `aarch64-apple-darwin` | `libdart_monty_core_native-aarch64-apple-darwin.dylib` | ~6 MB |
| macOS x86_64 | `x86_64-apple-darwin` | `libdart_monty_core_native-x86_64-apple-darwin.dylib` | ~6 MB |
| Linux x86_64 | `x86_64-unknown-linux-gnu` | `libdart_monty_core_native-x86_64-unknown-linux-gnu.so` | ~6 MB |
| Linux aarch64 | `aarch64-unknown-linux-gnu` | `libdart_monty_core_native-aarch64-unknown-linux-gnu.so` | ~6 MB |
| Windows x86_64 | `x86_64-pc-windows-msvc` | `dart_monty_core_native-x86_64-pc-windows-msvc.dll` | ~6 MB |
| Android (4 ABIs) | `aarch64-linux-android` etc. | `libdart_monty_core_native-<abi>.so` | ~6 MB each |
| iOS xcframework | (universal) | `dart_monty_core_native.xcframework.zip` | 70 MB zipped, 171 MB unzipped |

WASM stays committed in `lib/assets/` — there is no FFI hook for the
web target.

### Why download instead of commit

iOS xcframework size (170 MB unzipped) rules out committing binaries
to the package: the resulting tarball would exceed pub.dev's 100 MB
hard cap. Download-on-demand from GitHub Releases keeps the published
package small (~6 MB tarball, just the WASM trio + Dart sources).

### Release workflow (new in 0.17.1)

1. Bump `pubspec.yaml` version to `0.17.1`.
2. `tool/build_release_artefacts.sh` (forthcoming) cross-compiles all
   triples and uploads them to a draft GitHub Release.
3. `hook/build.dart` (extended) probes platform at `pub get` time,
   downloads the matching artefact via HTTPS, verifies SHA-256 against
   a manifest committed alongside the hook, caches under
   `${PUB_CACHE}/dart_monty_core/native/<version>/<triple>/`, and
   wires it as the `CodeAsset`.
4. CI matrix-builds the artefacts on macOS, Ubuntu, Windows runners
   and asserts manifest checksums. Promote draft → published when the
   matrix is green.
5. Tag `v0.17.1` triggers `publish.yaml`; OIDC handles the upload.

### Outstanding design decisions for 0.17.1

- Manifest format (JSON next to `hook/build.dart` vs embedded const map).
- Behaviour when offline — fall back to source build silently or hard
  fail with an actionable error?
- Cache location (`PUB_CACHE` vs system temp).
- Code-signing for macOS dylib (Developer ID + notarization) — defer
  to 0.17.x when Apple Developer cert is provisioned.
