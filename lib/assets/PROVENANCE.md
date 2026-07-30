# lib/assets provenance

Regenerate with: bash tool/prebuild.sh

These three files are committed so web consumers need no Rust/Node toolchain.
The wasm build is NOT byte-reproducible (see issue #41): rebuilding from an
unchanged tree yields different bytes. A `git diff` on the blob therefore
cannot tell you whether anything meaningful changed, which is why P4's gate
verifies BEHAVIOUR (dart2js + dart2wasm corpora green against a freshly built
asset) and records provenance here instead of diffing bytes.

## Build inputs

| input | value |
|---|---|
| monty tag | v0.0.19 |
| core commit | 51bec56 |
| target triple | wasm32-wasip1 |
| cargo profile | release |
| cargo features | NONE (test-hooks must be off in shipped assets) |
| rustc | rustc 1.96.0 (ac68faa20 2026-05-25) |
| node | v26.0.0 |
| built (UTC) | 2026-07-30T08:58:00Z |

## Artefacts

| file | bytes | sha256 |
|---|---|---|
| `dart_monty_core_bridge.js` | 19034 | `2645a793c9bbb097c04b32b1e82a45ca…` |
| `dart_monty_core_worker.js` | 51823 | `2f37657f9855b2302f559afbf620b53a…` |
| `dart_monty_core_native.wasm` | 14375976 | `9176459f67b130a16e09b40a5401c6eb…` |

## Notes for this build

- The wasm grew 13,728,501 → 14,375,976 bytes moving monty v0.0.18 → v0.0.19.
  That is a genuine engine size change, not reproducibility noise.
- `bridge.js` and `worker.js` are **byte-identical** to the 0.18.1 build.
  Upstream #525 moved browser wasm onto web workers, but our own glue already
  used them, so that change required no JS-side work — Rust-side only.
- Zero npm runtime dependencies. The `@pydantic/monty*` packages are
  vestigial here (our `js/src/wasm_glue.js` displaced them), which is why P4
  needed no npm version bump.
