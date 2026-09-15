# Thin wrappers so SoL-Pi's Evidence-Preserving Reducer actually engages.
#
# The reducer only considers a tool result a reduction candidate when the
# command matches DIAGNOSTIC_COMMAND in
# SoL-Pi/src/sol-pi/extensions/evidence-preserving-reducer/config.ts:
#
#   lake build | lean | coq | cargo (build|test|check) | zig build | pytest |
#   python -m (pytest|unittest|py_compile) | ctest | cmake --build | ninja |
#   make | npm test | pnpm test | yarn test | go test | bazel test
#
# `dart test` is NOT in that list, so every Dart run in this repo produced logs
# the reducer ignored — and this suite emits tens of thousands of lines. `make`
# IS in the list, so routing Dart through these targets is what switches the
# mechanism on. Verified prerequisite: output must also exceed the 4096-byte
# floor (config.ts DEFAULT_MIN_BYTES) and carry failure signals, which a failing
# 590-fixture run comfortably does.
#
# Note the regex anchors on `(?:^|[;&|()\s])make`, so it must be invoked as a
# bare `make ...` — not via an absolute path.

DART ?= dart

.PHONY: ffi-repl ffi-repl-slice crash-probe gate test-wasm test-wasm-dart2wasm

## Full FFI REPL corpus suite — the one that currently dies with SIGABRT.
ffi-repl:
	$(DART) test test/integration/ffi_repl_corpus_test.dart -p vm \
	  --run-skipped --tags=ffi -x crash-probe

## The subprocess crash guards, isolated. They spawn a child that dlopens the
## same native library, so they are kept out of the main run.
crash-probe:
	$(DART) test test/integration/ffi_repl_corpus_test.dart -p vm \
	  --run-skipped --tags=ffi -n "still crashes"

## Run only the first N fixtures, for bisecting an accumulation failure.
## Usage: make ffi-repl-slice N=100
N ?= 50
ffi-repl-slice:
	SOLPI_FIXTURE_LIMIT=$(N) $(DART) test \
	  test/integration/ffi_repl_corpus_test.dart -p vm --run-skipped --tags=ffi \
	  -x crash-probe

## WASM fixture corpus (dart2js) — the one that matters for Leg 6.
## Runs headless Chrome.
##
## Env:
##   KEEP_WEB_ASSETS=1  keep staged web assets after the run
##   KEEP_CHROME_LOG=1  keep Chrome stderr log (prints the path)
##
## NOTE: invoke via `make`, not `bash tool/test_wasm.sh`, to keep SoL-Pi's log
## reducer engaged.
test-wasm:
	bash tool/test_wasm.sh

## WASM fixture corpus (dart2wasm) — same corpus via dart2wasm.
test-wasm-dart2wasm:
	bash tool/test_wasm.sh --dart2wasm

## The repo's own full gate. NOTE: tool/gate.sh's first argument is the OUTPUT
## DIRECTORY, not a gate name — `bash tool/gate.sh ffi_features` runs the WHOLE
## suite into a folder called ffi_features. That cost two agents hours.
gate:
	bash tool/gate.sh
