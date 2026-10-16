// An independent supervisor observes real process exits with kqueue/pidfd.
// It owns neither worker pipe: killing the Dart parent really closes stdin.
@Tags(['worker'])
@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

const _path = 'test/integration/worker/spec_channel_parent_test.dart';

Future<void> main([List<String> args = const []]) async {
  if (args.isNotEmpty) {
    await _parent(args.single);

    return;
  }
  for (final (req, mode, result) in [
    (
      'REQ-pool-and-lifetimes-87',
      'keepalive',
      'parent retained until worker exit',
    ),
    (
      'REQ-pool-and-lifetimes-88',
      'idle',
      'idle worker exited after parent death',
    ),
    (
      'REQ-pool-and-lifetimes-89',
      'busy',
      'busy worker survived until duration limit',
    ),
  ]) {
    test('$req: $result', () async {
      final probe = await Process.run('python3', [
        '-c',
        _supervisor,
        Platform.resolvedExecutable,
        _path,
        mode,
      ]);
      expect(probe.exitCode, 0, reason: '${probe.stdout}\n${probe.stderr}');
      expect(probe.stdout, '$result\n');
    });
  }
}

Future<void> _parent(String mode) async {
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
  if (mode != 'busy') return;
  await channel.turn(
    pb.ParentRequest(
      feed: pb.Feed(
        code: 'print("running")\nwhile True:\n    pass',
        cwd: '/',
      ),
    ),
    onPrint: (event) {
      for (final segment in event.segments) {
        stdout.write(segment.text);
      }
    },
  );
  exit(3);
}

const _supervisor = r'''
import os, select, signal, subprocess, sys, time
parent = subprocess.Popen(sys.argv[1:3] + [sys.argv[3]],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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
            assert parent.stdout.readline() == 'running\n'
        started = time.monotonic()
        parent.kill()
        parent.wait(timeout=5)
        if mode == 'busy':
            assert not exited(0), 'busy worker died with parent'
        assert exited(10), 'orphan worker did not exit'
        if mode == 'busy':
            assert time.monotonic() - started >= 4, 'execution ended before its budget'
            print('busy worker survived until duration limit')
        else:
            print('idle worker exited after parent death')
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
