// A minimal, deterministic regression guard for the WASM poisoning bug.
//
// This is intentionally *not* run by default in CI yet; it is here to provide
// a standalone reproducer within the repo (TASK.md Step 2).
//
// It runs a single fixture known to trigger a wasm32 trap in upstream monty:
//   list__eq_self_referential.py
//
// Expected behavior (CPython): raise RecursionError.
// Current behavior (monty wasm32 v0.0.23): engine panics/traps.
//
// Run (manual):
//   dart compile js test/integration/wasm_poison_boundary_test.dart \
//     -o test/integration/web/wasm_poison_boundary_test.dart.js
//   # then serve test/integration/web and open in Chrome like other wasm tests.
//
// DCM: this is a compiled entry-point, not a unit test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';

Future<void> main() async {
  const name = 'list__eq_self_referential.py';
  final code = fixtureCorpus[name]!;

  print('REPRO_BEGIN:${jsonEncode({'name': name})}');
  final platform = createPlatformMonty();
  try {
    final r = await platform.run(code, scriptName: name);
    print('REPRO_RESULT:${jsonEncode({'name': name, 'ok': r.ok})}');
  } finally {
    await platform.dispose();
  }
}
