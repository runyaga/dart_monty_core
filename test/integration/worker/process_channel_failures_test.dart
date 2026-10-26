// Native transport failures through the public session lifecycle.
//
// The worker that fails is a standalone Dart program written to a temporary
// file while the suite runs: it imports only dart: libraries, so it starts
// without compiling a package or the test framework, and it exits as soon
// as it has answered. How quickly the operating system schedules it is not
// promised here.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/frame.dart' as wire;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show CrashCause, MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

const _fatalText = 'cannot announce the suspension';
const _memoryText = 'the worker exceeded its memory limit and was terminated';

/// The reply the worker sends for the configure request.
final List<int> _ok = wire.Frame.encode(pb.ChildEvent(ok: pb.Ok()));

/// The reply that announces the fatal failure.
final List<int> _fatal = wire.Frame.encode(
  pb.ChildEvent(fatalError: pb.FatalError(message: _fatalText)),
);

/// The directory the fixture program is written into, and the program
/// itself. Both are created once, while the suite runs, and removed once
/// it is over.
Directory? _fixtureDir;
String? _fixturePath;

/// The fixture program: a standalone worker that answers one request per
/// reply and then exits with the given code.
///
/// It imports only dart: libraries, so it starts without compiling a
/// package or the test framework, and it leaves as soon as its last reply
/// is written. It reads whole request frames, so a request split across
/// reads, or several requests in one read, are both handled.
const _workerProgram = '''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final code = int.parse(args[0]);
  final replies = <List<int>>[
    for (var index = 1; index < args.length; index++)
      base64Decode(args[index]),
  ];
  final pending = <int>[];
  final requests = StreamIterator<List<int>>(stdin);
  for (final reply in replies) {
    await _readFrame(requests, pending);
    if (reply.isNotEmpty) {
      stdout.add(reply);
      await stdout.flush();
    }
  }
  exit(code);
}

// Reads one whole request frame: a four-byte little-endian body length and
// then that many body bytes.
Future<void> _readFrame(
  StreamIterator<List<int>> requests,
  List<int> pending,
) async {
  final prefix = await _read(requests, pending, 4);
  final length =
      prefix[0] | (prefix[1] << 8) | (prefix[2] << 16) | (prefix[3] << 24);
  if (length > 0) await _read(requests, pending, length);
}

// Reads count bytes, keeping the surplus for the next read.
Future<List<int>> _read(
  StreamIterator<List<int>> requests,
  List<int> pending,
  int count,
) async {
  while (pending.length < count) {
    if (!await requests.moveNext()) exit(9);
    pending.addAll(requests.current);
  }
  final out = pending.sublist(0, count);
  pending.removeRange(0, count);

  return out;
}
''';

void main() {
  setUpAll(_createFixture);
  tearDownAll(_removeFixture);
  for (final run in [1, 2, 3, 4, 5]) {
    test('FatalError wins over exit 65 (run $run)', _fatalWinsOverExit65);
  }
  for (final run in [1, 2]) {
    test(
      'EOF with exit 65 reports the exact MemoryError (run $run)',
      _memoryErrorOnExit65,
    );
  }
  for (final scenario in ['oversize', 'torn']) {
    test(
      '$scenario discards the worker and session',
      () => _discards(scenario),
    );
  }
}

/// The replies the fixture sends and the code it exits with.
///
/// The first reply answers the configure request; a second one answers the
/// request that follows it. The worker leaves as soon as it has answered
/// them all.
({List<List<int>> replies, int code}) _script(String scenario) {
  return switch (scenario) {
    'fatal' => (replies: [_ok, _fatal], code: 65),
    // The worker leaves as soon as it has answered the configure request,
    // and never answers the request that follows it: its exit status is
    // settled before the turn that reads the end of its output, so the
    // crash that turn reports cannot depend on the order in which the end
    // of the output and the exit status arrive.
    'oom' => (replies: [_ok], code: 65),
    // 268435457, one byte above the independent 256 MiB contract.
    'oversize' => (
      replies: [
        _ok,
        [1, 0, 0, 16],
      ],
      code: 0,
    ),
    // Ten promised body bytes, only two delivered.
    'torn' => (
      replies: [
        _ok,
        [10, 0, 0, 0, 0, 0],
      ],
      code: 0,
    ),
    _ => throw StateError('unknown fixture scenario: $scenario'),
  };
}

/// Writes the fixture program into a directory of its own.
Future<void> _createFixture() async {
  final dir = await Directory.systemTemp.createTemp('monty_failure_');
  final file = File('${dir.path}/worker.dart');
  await file.writeAsString(_workerProgram);
  _fixtureDir = dir;
  _fixturePath = file.path;
}

/// Removes the fixture program and the directory holding it.
Future<void> _removeFixture() async {
  final dir = _fixtureDir;
  _fixtureDir = null;
  _fixturePath = null;
  if (dir == null) return;
  if (dir.existsSync()) await dir.delete(recursive: true);
}

Future<void> _fatalWinsOverExit65() async {
  final (pool, session, channel) = await _session('fatal');
  await expectLater(
    session.feedRun('1'),
    throwsA(
      isA<MontyCrashedError>()
          .having((e) => e.cause, 'cause', CrashCause.fatal)
          .having((e) => e.detail, 'detail', _fatalText)
          .having((e) => e.exitStatus, 'exitStatus', 65),
    ),
  );
  expect(await channel.exitCode, 65);
  await _finished(pool, session, channel);
}

Future<void> _memoryErrorOnExit65() async {
  final (pool, session, channel) = await _session('oom');
  // The worker has left by now, and its exit status is read before the turn
  // that reads the end of its output. The two arrive in either order, and
  // the channel reads the status within the grace upstream gives a worker
  // that is leaving: on a loaded machine that grace can pass before the
  // status arrives, and the crash the turn reports would name the kill
  // instead of the exit status.
  expect(await channel.exitCode, 65);
  await expectLater(
    session.feedRun('1'),
    throwsA(
      isA<MontyRuntimeError>()
          .having((e) => e.exception.excType, 'excType', 'MemoryError')
          .having((e) => e.exception.message, 'message', _memoryText)
          .having((e) => e.toString(), 'text', 'MemoryError: $_memoryText'),
    ),
  );
  await _finished(pool, session, channel);
}

Future<void> _discards(String scenario) async {
  final (pool, session, channel) = await _session(scenario);
  final crash = isA<MontyCrashedError>()
      .having((e) => e.cause, 'cause', CrashCause.vanished)
      .having((e) => e.timedOut, 'timedOut', isFalse);
  await expectLater(
    session.feedRun('1'),
    throwsA(
      scenario == 'oversize'
          ? crash
          : crash.having((e) => e.exitStatus, 'exitStatus', 0),
    ),
  );
  await _finished(pool, session, channel);
}

Future<(Monty, MontySession, ProcessChannel)> _session(String scenario) async {
  final script = _script(scenario);
  final path = _fixturePath;
  if (path == null) {
    throw StateError('the fixture program was not created');
  }
  final channel = await ProcessChannel.spawn(
    WorkerExecutable(
      Platform.resolvedExecutable,
      args: [
        path,
        script.code.toString(),
        for (final reply in script.replies) base64Encode(reply),
      ],
    ),
  );
  addTearDown(channel.close);
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  addTearDown(pool.close);
  final session = await pool.checkout();
  addTearDown(session.close);

  return (pool, session, channel);
}

Future<void> _finished(
  Monty pool,
  MontySession session,
  ProcessChannel channel,
) async {
  expect(channel.isAlive, isFalse);
  expect(pool.liveWorkers, 0);
  expect(pool.idleWorkers, 0);
  await expectLater(session.feedRun('2'), throwsStateError);
}
