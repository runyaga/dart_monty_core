// The precompiled API -- Monty.compile / runPrecompiled / startPrecompiled --
// does not work, on ANY backend. This pins that, in both directions.
//
// WHY A TEST THAT ASSERTS A DEFECT. test/unit/platform/monty_compile_test.dart
// covers this surface thoroughly and entirely against MockMontyPlatform, whose
// compileCode returns `jsonEncode({'code': code})`. Nothing in the suite ever
// called Monty.compile() against a real backend, so the API had a green test
// file and was dead in every shipped configuration. A mock asserts that the
// plumbing is wired; it cannot assert that the engine can do the thing.
//
// Same contract as tool/wasm-corpus-expected-failures.txt: declaring the known
// failure keeps the code RUNNING, and a fix shows up as a red test here rather
// than passing unnoticed. If these tests start failing because the calls
// SUCCEEDED, that is the good direction -- delete this file, drop
// example/06_compile_and_platform.dart from _skipReasons in
// example_smoke_test.dart, and lower MAX_SKIPS in tool/example_floor.sh.
//
// NOT AN FFI DEFECT, despite this file's name (it is named ffi_* so the
// tool/gate.sh and ci.yaml globs pick it up; both select
// test/integration/ffi_*_test.dart). The fault is in the SHARED Rust layer:
//
//   native/src/handle.rs:558
//     pub fn snapshot(&self) -> Result<Vec<u8>, String> {
//       Err("snapshot is not supported on the one-shot
//       handle: monty's SessionRef has no variant
//            for an un-started MontyRun ...".into())
//
// There is no conditional in that function -- it cannot return Ok for any
// caller, on any target. native/src/handle.rs:570 `restore` is the same shape.
// Both backends reach it by the identical two-step sequence:
//
//   FFI   ffi_core_bindings.dart:185  create(code) -> snapshot(handle)
//   WASM  worker_src.js:915,948      monty_create -> monty_snapshot
//
// So core#152's "broken on the FFI backend" is measurably understated. The
// worker even comments "Snapshot the compiled (pre-execution) handle --
// captures bytecode only" (worker_src.js:938), a belief the Rust it calls
// contradicts.
@Tags(['integration', 'ffi'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// What to do when one of these calls starts WORKING.
const _staleDeclaration =
    'This call SUCCEEDED. That is the good direction and this test is now '
    'stale: delete test/integration/ffi_compile_precompiled_test.dart, remove '
    'example/06_compile_and_platform.dart from _skipReasons in '
    'test/integration/example_smoke_test.dart, and lower MAX_SKIPS to 0 in '
    'tool/example_floor.sh (which raises the example floor to 15).';

Future<Object?> _capture(Future<void> Function() body) async {
  try {
    await body();

    return null;
  } on Object catch (e) {
    return e;
  }
}

void main() {
  group('precompiled API — DECLARED DEFECT, core#152', () {
    test('Monty.compile() fails: one-shot handle cannot snapshot', () async {
      final thrown = await _capture(() async {
        await Monty.compile('x = 1\nprint(x)\n');
      });

      expect(thrown, isNotNull, reason: _staleDeclaration);
      expect(
        '$thrown',
        contains('snapshot is not supported on the one-shot handle'),
        reason:
            'It still fails, but for a DIFFERENT reason than core#152 records. '
            'Re-diagnose before changing this expectation -- a stale reason '
            'hiding a real cause is the failure this example already suffered '
            'once (example_smoke_test.dart:25).',
      );
    });

    test(
      'Monty.runPrecompiled() fails: the one-shot handle cannot restore',
      () async {
        final thrown = await _capture(() async {
          await Monty.runPrecompiled(Uint8List.fromList([1, 2, 3]));
        });

        expect(thrown, isNotNull, reason: _staleDeclaration);
        expect(
          '$thrown',
          contains('restore is not supported on the one-shot handle'),
          reason:
              'Not an "invalid bytes" error: restore refuses before '
              'it looks at them, so no input reaches the parser.',
        );
      },
    );

    test(
      'the two halves fail independently, so fixing one is not enough',
      () async {
        // Stated explicitly because the obvious repair -- give compile() a REPL
        // handle, which CAN snapshot via SessionRef::Idle -- fixes the producer
        // and leaves runPrecompiled() reading through MontyHandle::restore,
        // which would still refuse. Whoever takes core#152 needs both.
        final compileThrew = await _capture(() async {
          await Monty.compile('x = 1\n');
        });
        final restoreThrew = await _capture(() async {
          await Monty.runPrecompiled(Uint8List.fromList([0]));
        });

        expect(compileThrew, isNotNull, reason: _staleDeclaration);
        expect(restoreThrew, isNotNull, reason: _staleDeclaration);
        expect(
          '$compileThrew'.contains('snapshot') &&
              '$restoreThrew'.contains('restore'),
          isTrue,
          reason:
              'Two distinct refusals, native/src/handle.rs:558 and :570. '
              'A fix that addresses only one leaves the API unusable.',
        );
      },
    );
  });
}
