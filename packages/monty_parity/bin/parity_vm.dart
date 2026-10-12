// Runs parity cases on the Dart VM (core's FFI backend).
//
// usage: dart run bin/parity_vm.dart OUTDIR case.json [case.json ...]
//        dart run bin/parity_vm.dart --probes OUTDIR
//
// Writes OUTDIR/<case_id>/core-vm.json (and core1-vm.json for one-shot
// cases), or OUTDIR/<probe>/core-vm.json for the probes. A case that throws
// in the runner records `runner_error`.
import 'dart:convert';
import 'dart:io';

import 'package:monty_parity/monty_parity.dart';

const enc = JsonEncoder.withIndent(' ');

Future<void> main(List<String> args) async {
  if (args.first == '--probes') {
    final res = await runProbes('vm');
    for (final MapEntry(:key, :value) in res.entries) {
      final d = Directory('${args[1]}/$key')..createSync(recursive: true);
      File(
        '${d.path}/core-vm.json',
      ).writeAsStringSync('${enc.convert(value)}\n');
      stdout.writeln(
        'core-vm probe $key: ${value['runner_error'] == null ? 'ok' : 'ERROR'}',
      );
    }
    exit(0);
  }
  final outdir = args.first;
  for (final path in args.skip(1)) {
    final c = (jsonDecode(File(path).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final id = c['id']! as String;
    final d = Directory('$outdir/$id')..createSync(recursive: true);
    Map<String, Object?> res;
    try {
      res = await runCase(c, 'vm');
    } on Object catch (e, st) {
      res = newOutcome(id, 'core', 'vm')..['runner_error'] = '$e\n$st';
    }
    File('${d.path}/core-vm.json').writeAsStringSync('${enc.convert(res)}\n');
    Map<String, Object?>? one;
    try {
      one = await runOneShot(c, 'vm');
    } on Object catch (e, st) {
      one = newOutcome(id, 'core1', 'vm')..['runner_error'] = '$e\n$st';
    }
    if (one != null) {
      File(
        '${d.path}/core1-vm.json',
      ).writeAsStringSync('${enc.convert(one)}\n');
    }
    stdout.writeln(
      'core-vm $id: ${res['runner_error'] == null ? 'ok' : 'ERROR'}',
    );
  }
  exit(0);
}
