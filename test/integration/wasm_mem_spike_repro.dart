import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';

/// Minimal reproduction for the WASM corpus poisoning:
///
/// The full corpus run shows a hard boundary at:
///   - refcount__gather_detached_sibling.py  => MontyPanicError: memory access out of bounds
///   - refcount__gather_exception.py         => WASM init failed: ... Cannot allocate Wasm memory ...
///
/// This repro runs just those two fixtures (in order) and prints:
///   - RESULT lines
///   - any thrown errors
///
/// Run via:
///   dart test/integration/wasm_mem_spike_repro.dart   (in a browser-like env)
///
/// In CI/harness we rely on `make test-wasm` for the actual Chrome execution;
/// this file is committed as the standalone guard requested by TASK.md.
Future<void> main() async {
  final fixtures = <String>[
    'refcount__gather_detached_sibling.py',
    'refcount__gather_exception.py',
  ];

  for (final name in fixtures) {
    final code = fixtureCorpus[name];
    if (code == null) {
      throw StateError('fixture not found: $name');
    }

    print('REPRO_BEGIN:${jsonEncode({'name': name})}');

    final platform = createPlatformMonty();
    try {
      MontyResult r;
      try {
        r = await platform.run(code, scriptName: name);
      } on Object catch (e) {
        print('REPRO_THROW:${jsonEncode({'name': name, 'error': '$e'})}');
        rethrow;
      }

      print(
        'REPRO_RESULT:${jsonEncode({'name': name, 'ok': r.ok, 'error': '${r.error}'})}',
      );
    } finally {
      await platform.dispose();
    }
  }
}
