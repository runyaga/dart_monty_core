// WASM binding for the MontyRepl snapshot/restore lifecycle shared body.
//
// Run with dart2js:  dart test test/integration/wasm_repl_snapshot_lifecycle_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_repl_snapshot_lifecycle_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/repl/wasm_repl_bindings.dart';
import 'package:dart_monty_core/src/wasm/wasm_bindings_js.dart';
import 'package:test/test.dart';

import '_repl_snapshot_lifecycle_test_body.dart';

void main() {
  runReplSnapshotLifecycleTests();

  // WEB-ONLY. These two parameters are honoured on FFI and refused here, so
  // they cannot live in the shared body.
  //
  // The Worker's replRestore message carries neither limits nor ext fns, so
  // monty_repl_restore is called with NULL for both. Dropping them silently is
  // what makes this worth a test rather than a comment: a dropped limit is a
  // security control that reports success, and a dropped ext fn does not
  // surface until some later call fails as an unknown name, far from the
  // restore that caused it. Both must refuse loudly until the Worker plumbs
  // them through -- at which point these tests fail and tell you to delete
  // them.
  group('WASM restore refuses what the Worker cannot carry', () {
    test('restore(extFns:) throws UnsupportedError', () async {
      final bindings = WasmReplBindings(bindings: WasmBindingsJs());
      await expectLater(
        bindings.restore(Uint8List(0), extFns: const ['host_fn']),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('extFns'), contains('unknown name')),
          ),
        ),
        reason:
            'If this now succeeds, the Worker carries ext fns through '
            'replRestore. Delete this test and drop the guard in '
            'lib/src/repl/wasm_repl_bindings.dart.',
      );
    });

    test('restore(limitsJson:) throws UnsupportedError', () async {
      final bindings = WasmReplBindings(bindings: WasmBindingsJs());
      await expectLater(
        bindings.restore(Uint8List(0), limitsJson: '{"stack_depth":5}'),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('security control reporting success'),
          ),
        ),
        reason:
            'If this now succeeds, the Worker carries limits through '
            'replRestore. Delete this test and drop the guard in '
            'lib/src/repl/wasm_repl_bindings.dart.',
      );
    });

    test('an empty extFns list is not treated as a request', () async {
      // Bounds the guard above: `extFns: const []` asks for nothing, so it must
      // NOT refuse. Without this, the guard could be tightened to `!= null` and
      // no test would notice it breaking every caller that passes a default.
      final bindings = WasmReplBindings(bindings: WasmBindingsJs());
      await expectLater(
        bindings.restore(Uint8List(0), extFns: const []),
        throwsA(isNot(isA<UnsupportedError>())),
        reason:
            'An empty ext-fn list requests no externals, so it carries no '
            'information that restore could drop.',
      );
    });
  });
}
