// Runs the parity cases baked into cases.g.dart in the browser (dart2js or
// dart2wasm) and prints each outcome on a marker line for
// tool/parity/run.py to collect.
// Printing is the transport: tool/parity/run.py reads the marker lines.
// ignore_for_file: avoid_print
@TestOn('browser')
library;

import 'dart:convert';

import 'package:monty_parity/monty_parity.dart';
import 'package:test/test.dart';

import 'cases.g.dart';

void main() {
  test('parity cases (web)', () async {
    const backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';
    for (final text in parityCases) {
      final c = (jsonDecode(text) as Map).cast<String, Object?>();
      final id = c['id']! as String;
      Map<String, Object?> res;
      try {
        res = await runCase(c, backend);
      } on Object catch (e, st) {
        res = newOutcome(id, 'core', backend)..['runner_error'] = '$e\n$st';
      }
      print('$outcomeMarker${jsonEncode(res)}');
      Map<String, Object?>? one;
      try {
        one = await runOneShot(c, backend);
      } on Object catch (e, st) {
        one = newOutcome(id, 'core1', backend)..['runner_error'] = '$e\n$st';
      }
      if (one != null) print('$outcomeMarker${jsonEncode(one)}');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('parity probes (web)', () async {
    const backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';
    final res = await runProbes(backend);
    for (final outcome in res.values) {
      print('$probeMarker${jsonEncode(outcome)}');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
