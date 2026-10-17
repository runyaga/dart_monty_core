// An independent supervisor observes real process exits with kqueue/pidfd.
// It owns neither worker pipe: killing the Dart parent really closes stdin.
@Tags(['worker'])
@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

const _path = 'test/integration/worker/process_channel_parent_exit_test.dart';

Future<void> main([List<String> args = const []]) async {
  if (args.isNotEmpty) {
    await _parent(args.single);

    return;
  }
  for (final (mode, result) in [
    (
      'keepalive',
      'parent retained until worker exit',
    ),
    (
      'idle',
      'idle worker exited after parent death',
    ),
    (
      'busy',
      'busy native session survived until duration limit',
    ),
  ]) {
    test(result, () async {
      final probe = await _probe(mode);
      expect(probe.exitCode, 0, reason: '${probe.stdout}\n${probe.stderr}');
      expect(probe.stdout, '$result\n');
    });
  }
}

Future<ProcessResult> _probe(String mode) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    final result = await Process.run('python3', [
      '-c',
      _supervisor,
      Platform.resolvedExecutable,
      _path,
      mode,
    ]);
    // A delayed running notification leaves no useful observation window.
    // Retry with a fresh worker rather than assert it outlives its budget.
    if (result.exitCode != 75 || attempt == 2) return result;
  }
  throw StateError('unreachable');
}

Future<void> _parent(String mode) async {
  if (mode == 'busy') {
    await _busyParent();

    return;
  }
  final channel = await ProcessChannel.spawn(await locateWorker());
  final configured = await channel.turn(
    pb.ParentRequest(
      configure: pb.Configure(
        protocolVersion: workerProtocolVersion,
        scriptName: 'parent.py',
        printFlushIntervalMs: 0,
        limits: pb.ResourceLimits(
          maxMemoryBytes: Int64(64 * 1024 * 1024),
          maxFeedDurationMicros: Int64(5000000),
        ),
      ),
    ),
  );
  if (configured.whichKind() != pb.ChildEvent_Kind.ok) exit(2);
  stdout.writeln(channel.pid);

  return;
}

Future<void> _busyParent() async {
  final launch = await locateWorker();
  if (launch is! WorkerExecutable) exit(2);
  final pool = await Monty.start(
    minProcesses: 0,
    maxProcesses: 1,
    feedDurationLimitGrace: null,
    workerLocation: launch.path,
  );
  final session = await pool.checkout(
    limits: const ResourceLimits(
      maxMemory: 64 * 1024 * 1024,
      maxFeedDuration: Duration(seconds: 5),
    ),
  );
  final pid = session.workerPid;
  if (pid == null) exit(2);
  stdout.writeln(pid);
  await stdout.flush();
  if (stdin.readByteSync() != 1) exit(2);
  await session.feedRun(
    'print("running")\nwhile True:\n    pass',
    printCallback: (stream, text) => stdout.write(text),
  );
  exit(3);
}

const _supervisor = r'''
import os, select, signal, subprocess, sys, time
parent = subprocess.Popen(sys.argv[1:3] + [sys.argv[3]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
worker = None
watch = None
try:
    line = parent.stdout.readline()
    assert line.strip().isdigit(), (line, parent.stderr.read())
    worker = int(line)
    if hasattr(select, 'kqueue'):
        watch = select.kqueue()
        watch.control([select.kevent(worker, filter=select.KQ_FILTER_PROC,
            flags=select.KQ_EV_ADD, fflags=select.KQ_NOTE_EXIT)], 0, 0)
        def exited(timeout):
            return bool(watch.control(None, 1, timeout))
    else:
        descriptor = os.pidfd_open(worker)
        watch = select.poll()
        watch.register(descriptor, select.POLLIN)
        def exited(timeout):
            return bool(watch.poll(int(timeout * 1000)))
    mode = sys.argv[3]
    if mode == 'keepalive':
        # A bounded wait for an exit event, not a sleep before polling.
        try:
            parent.wait(timeout=0.25)
            raise AssertionError('VM exited while its worker was alive')
        except subprocess.TimeoutExpired:
            pass
        os.kill(worker, signal.SIGKILL)
        assert exited(5), 'worker did not exit'
        assert parent.wait(timeout=5) == 0, parent.stderr.read()
        print('parent retained until worker exit')
    else:
        if mode == 'busy':
            # Register the exit watch before releasing the feed. This time is
            # a lower bound on execution startup, not print delivery time.
            started = time.monotonic()
            parent.stdin.write('\x01')
            parent.stdin.flush()
            assert parent.stdout.readline() == 'running\n'
            remaining = started + 4 - time.monotonic()
            if remaining < 1:
                print('startup consumed the observation window', file=sys.stderr)
                sys.exit(75)
        parent.kill()
        assert exited(10), 'orphan worker did not exit'
        if mode == 'busy':
            assert time.monotonic() - started >= 4, 'execution ended before its budget'
            print('busy native session survived until duration limit')
        else:
            print('idle worker exited after parent death')
        parent.wait(timeout=5)
finally:
    if parent.poll() is None:
        parent.kill()
    parent.wait(timeout=5)
    if worker is not None:
        try:
            os.kill(worker, signal.SIGKILL)
        except ProcessLookupError:
            pass
''';
