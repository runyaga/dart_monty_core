@Tags(['wasm'])
library;

// ignore_for_file: prefer-moving-to-variable

import 'dart:convert';

import 'package:dart_monty_core/src/wasm/wasm_bindings_js.dart';
import 'package:test/test.dart';

/// Regression test for session routing.
///
/// A prior JS-bridge change fixed `resume()` to use the passed session id, but
/// several resume-adjacent methods still hardcoded the default session.
///
/// This test creates two sessions, starts an iterative run in each that pauses
/// on an external function call, then resumes each one by routing to its own
/// session.
///
/// If the bridge routes to the wrong session, one platform will hang forever
/// (still pending) and/or the other will throw due to an unexpected resume.
void main() {
  test('resumeAsFuture routes to the correct JS-bridge session', () async {
    final bindings = WasmBindingsJs();
    await bindings.init();

    final session1 = await bindings.createSession();
    final session2 = await bindings.createSession();

    const code = """
from monty import external

x = external('f')
""";

    final p1 = await bindings.start(
      code,
      extFnsJson: json.encode(['f']),
      scriptName: 's1.py',
      sessionId: session1,
    );
    // start() must pause on the external function call.
    expect(p1.state, 'pending');

    final p2 = await bindings.start(
      code,
      extFnsJson: json.encode(['f']),
      scriptName: 's2.py',
      sessionId: session2,
    );
    expect(p2.state, 'pending');

    final r1 = await bindings.resumeAsFuture(sessionId: session1);
    expect(r1.state, isNot('pending'));

    final r2 = await bindings.resumeAsFuture(sessionId: session2);
    expect(r2.state, isNot('pending'));

    await bindings.disposeSession(session1);
    await bindings.disposeSession(session2);
  });
}
