#!/usr/bin/env bash
# =============================================================================
# tool/check_api_exercised.sh — is every public entry point actually PLUMBED?
# =============================================================================
# A mock proves the wiring compiles. It cannot prove the engine can do the
# thing. Monty.compile() had a thorough test file --
# test/unit/platform/monty_compile_test.dart -- written entirely against
# MockMontyPlatform, whose compileCode returns `jsonEncode({'code': code})`.
# Nothing ever called Monty.compile() against FFI or WASM, so the API was green
# in CI and dead in every shipped configuration: native/src/handle.rs:558
# returns Err unconditionally, on every target (core#152).
#
# This asks one question of each public entry point on Monty and MontyRepl:
# does ANY file that runs against a real backend mention it?
#
# THE REAL SURFACE IS THREE DIRECTORIES, NOT ONE. Getting this wrong is how the
# check cries wolf, and a check that cries wolf gets deleted. Measured while
# writing it -- scanning only `test/**/*_test.dart` reported five entry points
# as untested and all five were FALSE:
#
#   test/integration/**   incl. the shared `_*_body.dart` bodies that the
#                         ffi_/wasm_ pairs import -- `typeCheck`,
#                         `resolveFutures` and `resumeAsFuture` live ONLY there
#   example/**            smoke-run by tool/run_example_smoke.sh and by CI --
#                         `clearState` and `detectContinuation` live only here
#   packages/*/lib/**     the conformance runners, driven on real backends by
#                         corpus_js / corpus_wasm / oracle_ffi -- this is the
#                         only caller of `resumeWithException`
#
# The entry-point list is DERIVED from the source, not enumerated here. A
# hand-written list does not grow a row when someone adds a public method, so
# the new method would be exempt from the check by default -- which is the
# failure this exists to prevent, wearing a different hat.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

BASELINE=tool/api-exercised-baseline.txt

python3 - "$BASELINE" <<'PY'
import re, sys, pathlib

baseline_path = pathlib.Path(sys.argv[1])
declared = set()
if baseline_path.exists():
    for line in baseline_path.read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if line:
            declared.add(line)

SOURCES = ['lib/src/monty.dart', 'lib/src/repl/monty_repl.dart']
# A public method declaration at class-member indentation. `_private` and
# operators are excluded; getters have no parens and are not entry points.
DECL = re.compile(
    r'^  (?:static\s+)?(?:Future<[^>]*>|Stream<[^>]*>|void|[A-Z][\w<>?,\[\] ]*)\s+'
    r'([a-z]\w*)\s*\(', re.M)

entry_points = {}
for src in SOURCES:
    text = pathlib.Path(src).read_text(errors='replace')
    for name in DECL.findall(text):
        entry_points.setdefault(name, src)

if not entry_points:
    print('FAIL: parsed ZERO public entry points out of:', ', '.join(SOURCES))
    print('  The declaration regex no longer matches this source. A check that')
    print('  silently examines nothing is worse than no check.')
    sys.exit(1)

real_files = []
for pat in ('test/integration/**/*.dart', 'example/*.dart', 'packages/*/lib/**/*.dart'):
    real_files.extend(pathlib.Path('.').glob(pat))
corpus = {p: p.read_text(errors='replace') for p in real_files}

if len(corpus) < 50:
    print(f'FAIL: the real-backend surface is only {len(corpus)} files.')
    print('  Expected 100+. A glob that stopped matching would mark every')
    print('  entry point unexercised, so refuse rather than report nonsense.')
    sys.exit(1)

unexercised = []
for name in sorted(entry_points):
    hits = sum(1 for s in corpus.values() if re.search(r'\.' + name + r'\s*\(', s))
    if hits == 0:
        unexercised.append(name)

now = set(unexercised)
new = now - declared
stale = declared - now

if new:
    print(f'FAIL: {len(new)} public entry point(s) are not exercised by any')
    print('      file that runs against a real backend:')
    for n in sorted(new):
        print(f'    {n}()  —  declared in {entry_points[n]}')
    print()
    print('  A unit test against MockMontyPlatform does not count, and that is')
    print('  the point: the mock returns whatever it is told to. Add a test')
    print('  under test/integration/, an example/ program, or a conformance')
    print('  driver -- or, if it is genuinely untestable, add the name to')
    print(f'  {baseline_path} with the reason on the same line.')
    sys.exit(1)

if stale:
    print(f'FAIL: {len(stale)} name(s) in {baseline_path} ARE now exercised:')
    for n in sorted(stale):
        print(f'    {n}')
    print('  Delete those lines. A declared exception that no longer applies')
    print('  is a licence nobody is using and everybody inherits.')
    sys.exit(1)

print(f'PASS — {len(entry_points)} public entry points, '
      f'{len(entry_points) - len(now)} exercised on a real backend, '
      f'{len(now)} declared in the baseline.')
PY
