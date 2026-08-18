// Measures what the M1 gate asks for and upstream does not publish: the
// per-call cost of putting the interpreter behind a pipe, and the cost of
// having a worker ready before it is needed.
//
//   dart run tool/pool_bench.dart              # JIT worker (dev path)
//   dart run tool/pool_bench.dart --aot        # AOT worker via `dart build cli`
//
// Reports rather than gates. A number that fails CI on a shared runner measures
// the runner; these numbers exist to decide whether the design is affordable,
// and that decision is made by a person reading them, once.
//
// Three quantities, and the difference between them is the whole point:
//
//   prewarm   spawn → ready handshake. Paid once per worker, amortised by
//             keeping workers alive; it is the cost pooling exists to hide.
//   ping      an empty round trip. Framing + pipe + scheduling, with no
//             interpreter involved — the floor this design adds to every call.
//   feedRun   the same round trip carrying `2 + 2`, minus the in-process cost
//             of `2 + 2`, which is the honest way to state the tax.
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/pool/worker_protocol.dart';

import '../test/integration/pool/worker_handle.dart';

const _warmup = 20;
const _samples = 200;
const _spawnSamples = 10;

Future<void> main(List<String> args) async {
  final useAot = args.contains('--aot');

  String? executable;
  List<String>? arguments;
  Directory? bundleDir;

  if (useAot) {
    bundleDir = await _buildAotWorker();
    executable = '${bundleDir.path}/bin/monty_worker';
    arguments = const <String>[];
  }

  _line('dart_monty_core — worker channel cost');
  _line('worker: ${useAot ? 'AOT (dart build cli)' : 'JIT (dart run)'}');
  _line(
    'host:   ${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion}',
  );
  _line('cores:  ${Platform.numberOfProcessors}');
  _line('');

  // --- prewarm ---------------------------------------------------------------
  final spawnMicros = <int>[];
  for (var i = 0; i < _spawnSamples; i++) {
    final sw = Stopwatch()..start();
    final worker = await MontyWorkerHandle.spawn(
      executable: executable,
      arguments: arguments,
    );
    sw.stop();
    spawnMicros.add(sw.elapsedMicroseconds);
    await worker.shutdown();
  }
  _report('prewarm (spawn → ready)', spawnMicros);

  // --- round trips -----------------------------------------------------------
  final worker = await MontyWorkerHandle.spawn(
    executable: executable,
    arguments: arguments,
  );
  await worker.request(const CreateSessionRequest());

  final pingMicros = await _timeRequests(worker, const PingRequest());
  _report('ping (empty round trip)', pingMicros);

  final feedMicros = await _timeRequests(
    worker,
    const FeedRunRequest('2 + 2'),
  );
  _report('feedRun 2+2 (out of process)', feedMicros);

  await worker.shutdown();

  // --- the in-process baseline the tax is measured against -------------------
  final inProcess = <int>[];
  final repl = MontyRepl();
  for (var i = 0; i < _warmup; i++) {
    await repl.feedRun('2 + 2');
  }
  for (var i = 0; i < _samples; i++) {
    final sw = Stopwatch()..start();
    await repl.feedRun('2 + 2');
    sw.stop();
    inProcess.add(sw.elapsedMicroseconds);
  }
  await repl.dispose();
  _report('feedRun 2+2 (in process, FFI)', inProcess);

  _line('');
  final tax = _median(feedMicros) - _median(inProcess);
  _line('IPC tax on a trivial call: ${_ms(tax)} ms (median out − median in)');
  _line('Empty round trip (floor):  ${_ms(_median(pingMicros))} ms');
  _line('Prewarm, amortised over N calls: ${_ms(_median(spawnMicros))} ms / N');

  if (bundleDir != null) {
    _line('');
    _line('AOT bundle: ${bundleDir.path}');
  }
  exit(0);
}

Future<List<int>> _timeRequests(
  MontyWorkerHandle worker,
  WorkerRequest payload,
) async {
  for (var i = 0; i < _warmup; i++) {
    await worker.request(payload);
  }
  final micros = <int>[];
  for (var i = 0; i < _samples; i++) {
    final sw = Stopwatch()..start();
    await worker.request(payload);
    sw.stop();
    micros.add(sw.elapsedMicroseconds);
  }

  return micros;
}

/// Builds the worker with `dart build cli`, which per the design notes is the
/// only Dart AOT path that produces a runnable binary for this package —
/// `dart compile exe` dies at startup with "No available native assets".
Future<Directory> _buildAotWorker() async {
  final script = await MontyWorkerHandle.resolveWorkerScript();
  final out = Directory.systemTemp.createTempSync('monty_worker_aot');
  _line('building AOT worker into ${out.path} …');
  final result = await Process.run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '-t',
    script,
    '-o',
    out.path,
  ]);
  if (result.exitCode != 0) {
    stderr
      ..writeln('dart build cli failed (${result.exitCode})')
      ..writeln(result.stdout)
      ..writeln(result.stderr);
    exit(1);
  }

  return Directory('${out.path}/bundle');
}

/// Order statistics over a sample, summarised in one line.
///
/// Percentiles are read through [_at], which returns null rather than throwing
/// on an empty sample — a benchmark that crashed on zero samples would report
/// nothing at all about the run that produced them.
void _report(String label, List<int> micros) {
  final sorted = List<int>.from(micros)..sort();
  _line(
    '${label.padRight(30)} '
    'n=${sorted.length}  '
    'median=${_ms(_at(sorted, sorted.length ~/ 2))} ms  '
    'p95=${_ms(_at(sorted, (sorted.length * 0.95).floor()))} ms  '
    'min=${_ms(_at(sorted, 0))} ms  '
    'max=${_ms(_at(sorted, sorted.length - 1))} ms',
  );
}

int _median(List<int> micros) {
  final sorted = List<int>.from(micros)..sort();

  return _at(sorted, sorted.length ~/ 2);
}

/// The [index]th element of [sorted], or 0 when the sample is empty.
int _at(List<int> sorted, int index) => sorted.elementAtOrNull(index) ?? 0;

String _ms(int micros) => (micros / 1000).toStringAsFixed(3);

void _line(String text) {
  // A CLI report; stdout is the only channel it has.
  // ignore: avoid_print
  print(text);
}
