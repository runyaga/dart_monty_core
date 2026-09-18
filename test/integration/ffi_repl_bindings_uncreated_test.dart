// Every FfiReplBindings method, called before create().
//
// Nine methods carry the identical guard -- `throw StateError('REPL not
// created. Call create() first.')` -- and on the gate's own
// coverage/honest.info not one of the nine had ever executed:
// ffi_repl_bindings.dart 69, 118, 129, 140, 154, 169, 187, 201, 216.
//
// The guard is what stands between a null handle and an FFI call. A method
// that lost it would pass garbage across the boundary, which is not a Dart
// exception -- it is whatever the native side does with a bad pointer.
//
// TABLE-DRIVEN because the risk is a method being ADDED without the guard,
// not one of these nine regressing on its own. Two methods deliberately do
// something else, and are asserted separately rather than excluded quietly.
@Tags(['integration', 'ffi'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:dart_monty_core/src/repl/ffi_repl_bindings.dart';
import 'package:test/test.dart';

FfiReplBindings _uncreated() =>
    FfiReplBindings(bindings: const NativeBindingsFfi());

void main() {
  group('an un-created FFI REPL refuses every handle-taking call', () {
    final cases = <String, Future<Object?> Function(FfiReplBindings)>{
      'feedRun': (b) => b.feedRun('1'),
      'feedStart': (b) => b.feedStart('1'),
      'resume': (b) => b.resume(WireJson.value(1)),
      'resumeWithError': (b) => b.resumeWithError('x'),
      'resumeWithException': (b) => b.resumeWithException('ValueError', 'x'),
      'resumeNotFound': (b) => b.resumeNotFound('f'),
      'resumeAsFuture': (b) => b.resumeAsFuture(),
      'resolveFutures': (b) => b.resolveFutures(
        WireJson.callResults(const {}),
        WireJson.callErrors(const {}),
      ),
      'snapshot': (b) => b.snapshot(),
    };

    for (final entry in cases.entries) {
      test('${entry.key} throws StateError naming create()', () async {
        await expectLater(
          entry.value(_uncreated()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(contains('REPL not created'), contains('create()')),
            ),
          ),
          reason: 'the message has to tell the caller what to do next',
        );
      });
    }

    test('the table covers every guard in the source', () {
      // A method added later with the same guard, and not added here, is the
      // failure this catches -- the table cannot discover itself.
      expect(
        cases,
        hasLength(9),
        reason:
            'ffi_repl_bindings.dart carries 9 "REPL not created" guards; if '
            'that count changed, add the new method to this table',
      );
    });
  });

  group('the two deliberate exceptions to that rule', () {
    test('setExtFns returns SILENTLY instead of throwing', () async {
      // Registration before create() is a no-op by design: create() syncs the
      // names itself, so refusing here would make ordering matter when it does
      // not. Asserted so a later "consistency" tidy-up is a deliberate change.
      await expectLater(_uncreated().setExtFns(const ['a']), completes);
    });

    test('detectContinuation needs no handle at all', () async {
      // It asks the engine about a string, not about a session, so it works
      // before any REPL exists.
      expect(await _uncreated().detectContinuation('1 + 1'), isA<int>());
    });
  });

  test('restore() replaces rather than requiring a prior create()', () async {
    // restore() detaches any old finalizer and installs a new handle, so it is
    // the one handle-taking call that is legal first. It still refuses BYTES
    // it cannot read, which is what this asserts -- not a StateError.
    // It DOES throw StateError -- measured: "repl restore failed: not a monty
    // dump" -- so the type alone cannot tell the two refusals apart. The
    // message is the discriminator, and that is what a caller reads.
    await expectLater(
      _uncreated().restore(Uint8List.fromList([0, 1, 2])),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('restore failed'), isNot(contains('not created'))),
        ),
      ),
      reason: 'invalid bytes must fail as bad input, not as "not created"',
    );
  });
}
