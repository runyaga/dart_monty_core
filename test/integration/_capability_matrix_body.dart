// E2 — capability matrix, bounded to the cells E3 will compare.
//
// WHAT THIS IS FOR. E3 compares four known contract defects against
// pydantic-monty. Before that comparison can mean anything, we have to know
// which backend/entry-point combinations can REACH each behaviour at all. A
// reproducer that throws `UnsupportedError` on web is not evidence about the
// defect under test; it is evidence the wrong entry point was used.
//
// Every cell prints its outcome FIRST, then asserts the one condition the
// matrix depends on: the probe REACHED the behaviour under test. A cell whose
// probe raised something unrelated (core#154's original memory probe measured
// a NameError) or returned cleanly says nothing about the case, so the matrix
// fails on it rather than recording it as data. The one permitted
// non-reaching outcome is the documented refusal: `Monty.exec(limits:)` on web
// throws UnsupportedError (core#140), recorded as REFUSED by
// tool/control/compare.py. Whether a reached outcome is a defect is still E3's
// question (compare.py), not this file's.
//
// THE AXIS THAT MATTERS, found by reading wasm_repl_bindings.dart:36-58:
//   Monty.exec(code, limits: …)        -> Monty(code).run(limits: …)
//                                      -> builds a MontyRepl
//                                      -> web REFUSES session limits (core#140)
//   createPlatformMonty().run(code, limits: …)
//                                      -> one-shot; limits work on web
// So the same reproducer needs a different entry point per backend, and a
// matrix indexed only by backend would record these cells wrongly.
//
// Output protocol, greppable the way ci.yaml greps FIXTURE_RESULT:
//   CAP:{"backend":…,"case":…,"entry":…,"outcome":…,"detail":…}
import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// One probe: the Python that triggers it, the limits it needs, and the
/// exception classes that show it reached the behaviour under test.
typedef _Case = ({
  String id,
  String code,
  MontyLimits? limits,
  Set<String> reaches,
  String why,
});

final _cases = <_Case>[
  (
    id: 'syntax',
    code: 'def (',
    limits: null,
    reaches: {'SyntaxError'},
    why: 'core#154 — dartdoc says binding-level failures throw; does it?',
  ),
  (
    id: 'timeout',
    code: 'while True: pass',
    limits: const MontyLimits(timeoutMs: 150),
    reaches: {'TimeoutError'},
    why: 'core#154 — a resource limit is a binding-level failure',
  ),
  (
    id: 'memory',
    // NOT `bytearray(10**9)`, which core#154's own write-up used: this
    // subset has no `bytearray`, so that probe measured a NameError and
    // nothing about memory. Measured alternatives that DO trip the bound:
    // `bytes(10**9)` and `list(range(10**8))`.
    code: 'x = [0] * (10**8)',
    limits: const MontyLimits(memoryBytes: 1024 * 1024),
    reaches: {'MemoryError', 'MemoryLimitExceeded'},
    why: 'core#154 + core#160 — single-object bound, not a heap ceiling',
  ),
];

String _typeOf(Object e) => e.runtimeType.toString();

/// Truncated so one pathological message cannot swamp the matrix.
String _clip(String s, [int n = 90]) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();

  return one.length <= n ? one : '${one.substring(0, n)}…';
}

void _emit(
  String backend,
  String id,
  String entry,
  String outcome,
  String detail, {
  String? excType,
}) {
  // The matrix is the deliverable; stdout is how it leaves the process.
  // ignore: avoid_print
  print(
    'CAP:${jsonEncode({
      'backend': backend,
      'case': id,
      'entry': entry,
      'outcome': outcome,
      'excType': excType,
      'detail': _clip(detail),
    })}',
  );
}

/// Runs one cell, emits it, and returns why it did NOT reach [c]'s behaviour,
/// or null when it did (or refused in the one documented way).
Future<String?> _probe(
  String backend,
  _Case c,
  String entry,
  Future<MontyResult> Function() call,
) async {
  String outcome;
  String? excType;
  try {
    final r = await call();
    excType = r.error?.excType;
    outcome = r.isError ? 'returned-error' : 'returned-ok';
    _emit(
      backend,
      c.id,
      entry,
      outcome,
      r.isError ? '${r.error}' : 'value=${r.value}',
      excType: excType,
    );
  } on Object catch (e) {
    excType = switch (e) {
      MontyScriptError(excType: final type) => type,
      MontyResourceError() => 'MemoryLimitExceeded',
      _ => null,
    };
    outcome = 'threw';
    _emit(backend, c.id, entry, outcome, '${_typeOf(e)}: $e', excType: excType);
    if (e is UnsupportedError) {
      // core#140: Monty.exec builds a MontyRepl, and web refuses REPL session
      // limits. Anywhere else a refusal means the cell measured nothing.
      final documented =
          backend.startsWith('wasm') &&
          entry == 'Monty.exec' &&
          c.limits != null;

      return documented ? null : '$entry refused instead of executing: $e';
    }
  }
  if (c.reaches.contains(excType)) return null;

  return '$entry did not reach ${c.reaches.join('/')}: $outcome '
      '(excType $excType)';
}

void runCapabilityMatrix(String declaredBackend) {
  // dart2js has a single number type, so 1 and 1.0 are the same object there
  // and distinct everywhere else — the property tool/test_wasm.sh documents as
  // the reason the two web compilers are not interchangeable. Resolved at
  // runtime because the mirror cannot know which compiler `dart test -c` got.
  final String backend;
  if (declaredBackend != 'wasm') {
    backend = declaredBackend;
  } else if (identical(1, 1.0)) {
    backend = 'wasm-dart2js';
  } else {
    backend = 'wasm-dart2wasm';
  }

  group('E2 capability matrix — $backend', () {
    for (final c in _cases) {
      test('${c.id} · both entry points', () async {
        // ENTRY POINT 1: the public API most consumers reach for. On web with
        // limits this is expected to refuse before executing anything.
        final exec = await _probe(
          backend,
          c,
          'Monty.exec',
          () => Monty.exec(c.code, limits: c.limits),
        );

        // ENTRY POINT 2: the platform one-shot, which the refusal message
        // itself names as the path where limits work on web.
        final run = await _probe(
          backend,
          c,
          'platform.run',
          () => createPlatformMonty().run(c.code, limits: c.limits),
        );

        // Both are checked after both are emitted, so a failing cell never
        // hides its sibling from the inventory.
        expect([exec, run].nonNulls, isEmpty, reason: c.why);
      });
    }

    // core#156 is deliberately NOT probed here: a loop calling an external
    // function has no suspension budget, so the probe would hang the suite
    // rather than report. It needs the external watchdog that E4 builds, which
    // is why E4 was moved ahead of the fuzzing work that would also hang.
    test('non-yielding loop (core#156) is deferred, not skipped silently', () {
      _emit(
        backend,
        'nonyield',
        'n/a',
        'deferred-to-E4',
        'needs an external watchdog; probing it here would hang the suite',
      );
      // Was `expect(true, isTrue)`: a pass that asserted nothing. Nothing was
      // probed, so the honest report is a skip with its reason (runbook
      // trap 6).
      markTestSkipped('core#156 is probed by E4 (tool/control/watchdog.sh)');
    });
  });
}
