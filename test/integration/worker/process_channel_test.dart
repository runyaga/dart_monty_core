// ProcessChannel against the scripted fake worker: every way a worker can end
// a turn, and the typed error each one must become.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_worker_harness.dart';
import 'fake_worker.dart' show fatalMessage, stderrLastLine;

pb.ParentRequest _feed(String code) =>
    pb.ParentRequest(feed: pb.Feed(code: code));

final _configure = pb.ParentRequest(configure: pb.Configure());

/// The [MontyCrashedError] that [future] fails with.
///
/// Captured through the matcher: catching an Error is what the analyzer's
/// avoid_catching_errors forbids, and the matcher also fails the test if
/// the future completes or throws anything else.
Future<MontyCrashedError> _crashOf(Future<Object?> future) async {
  MontyCrashedError? seen;
  await expectLater(
    future,
    throwsA(
      isA<MontyCrashedError>().having((e) => seen = e, 'error', isNotNull),
    ),
  );

  return seen ?? fail('the matcher saw no MontyCrashedError');
}

Future<ProcessChannel> _spawn(String scenario) async {
  final channel = await ProcessChannel.spawn(fakeWorker(scenario));
  addTearDown(channel.close);

  return channel;
}

void main() {
  expectNoWorkersLeftAfterEachTest();

  group('a turn that ends normally', () {
    test('streams Prints in order, then returns the turn end', () async {
      final channel = await _spawn('serve');
      expect(channel.pid, isPositive);
      final ok = await channel.turn(_configure);
      expect(ok.whichKind(), pb.ChildEvent_Kind.ok);

      final prints = <(pb.PrintStream, String)>[];
      final end = await channel.turn(
        _feed('1 + 1'),
        onPrint: (print) => prints.addAll([
          for (final s in print.segments) (s.stream, s.text),
        ]),
      );
      expect(end.whichKind(), pb.ChildEvent_Kind.complete);
      expect(prints, [
        (pb.PrintStream.PRINT_STREAM_STDOUT, 'out:1 + 1'),
        (pb.PrintStream.PRINT_STREAM_STDERR, 'err:1 + 1'),
      ]);
      expect(channel.isAlive, isTrue);
    });

    test('an onPrint that throws keeps the stream in sync', () async {
      final channel = await _spawn('serve');
      await expectLater(
        channel.turn(_feed('a'), onPrint: (_) => throw StateError('print')),
        throwsA(isA<StateError>()),
      );
      // The next turn reads its own events, not the rest of the last one.
      final prints = <String>[];
      final end = await channel.turn(
        _feed('b'),
        onPrint: (print) =>
            prints.add(print.segments.map((s) => s.text).join()),
      );
      expect(end.whichKind(), pb.ChildEvent_Kind.complete);
      expect(prints, ['out:b', 'err:b']);
    });

    test('one turn at a time', () async {
      final channel = await _spawn('serve');
      final first = channel.turn(_feed('a'));
      await expectLater(channel.turn(_feed('b')), throwsStateError);
      await first;
    });

    test('an oversized request is refused before a byte is written; the '
        'worker stays in sync', () async {
      final channel = await _spawn('serve');
      final node = pb.MontyNode(str: 'x' * (1 << 20));
      final huge = pb.ParentRequest(
        feed: pb.Feed(values: pb.Arena(nodes: List.filled(300, node))),
      );
      await expectLater(
        channel.turn(huge),
        throwsA(isA<FrameTooLargeException>()),
      );
      expect(channel.isAlive, isTrue);
      final prints = <String>[];
      final end = await channel.turn(
        _feed('c'),
        onPrint: (print) =>
            prints.add(print.segments.map((s) => s.text).join()),
      );
      expect(end.whichKind(), pb.ChildEvent_Kind.complete);
      expect(prints, ['out:c', 'err:c']);
    });
  });

  group('crashes are typed', () {
    test('exit 65 is outOfMemory', () async {
      final channel = await _spawn('oom');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.outOfMemory);
      expect(crash.exitCode, workerOomExitCode);
      expect(channel.isAlive, isFalse);
    });

    test('a FatalError then exit 4 is fatal, with its message', () async {
      final channel = await _spawn('fatal');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.fatal);
      expect(crash.exitCode, 4);
      expect(crash.message, fatalMessage);
    });

    test('a FatalError without an exit is killed after the grace', () async {
      final channel = await _spawn('fatal-hang');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.fatal);
      expect(crash.message, fatalMessage);
      if (!Platform.isWindows) {
        expect(crash.exitCode, -ProcessSignal.sigkill.signalNumber);
      }
    });

    test('EOF before the turn ends is vanished', () async {
      final channel = await _spawn('eof');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.vanished);
      expect(crash.exitCode, 0);
      expect(crash.message, 'worker exited without ending the turn');
    });

    test('a torn frame is vanished, naming the truncation', () async {
      final channel = await _spawn('torn');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.vanished);
      expect(crash.message, contains('FrameTruncatedException'));
      expect(crash.message, contains('14 bytes'));
    });

    test('an oversize length prefix desynchronises: worker killed', () async {
      final channel = await _spawn('oversize');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.vanished);
      expect(crash.message, contains('FrameTooLargeException'));
    });

    test('a frame that is not a ChildEvent desynchronises', () async {
      final channel = await _spawn('garbage');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.vanished);
      expect(crash.message, contains('worker output unreadable'));
    });

    test('a frame upstream rejects desynchronises: worker killed', () async {
      // The scenario's frame, which package:protobuf alone accepts.
      expect(
        pb.ChildEvent.fromBuffer([
          0x32, 8, 0x12, 6, 0x12, 4, 0x42, 2, 0xc3, 0x28, //
        ]).complete.values.nodes,
        hasLength(1),
      );
      final channel = await _spawn('upstream-rejects');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.vanished);
      expect(crash.message, contains('FrameDecodeException'));
    });

    test('stderr tail: the last 4 KiB, ending with the last line', () async {
      final channel = await _spawn('stderr');
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.vanished);
      expect(crash.exitCode, 134);
      final tail = crash.stderrTail;
      expect(tail, isNotNull);
      expect(tail, endsWith(stderrLastLine));
      final length = tail?.length ?? 0;
      expect(length, lessThanOrEqualTo(4096));
      expect(length, greaterThan(4000));
      expect(crash.toString(), contains(stderrLastLine));
    });

    test(
      'stderr written just before the exit still reaches the tail',
      () async {
        final channel = await _spawn('late-stderr');
        final crash = await _crashOf(channel.turn(_configure));
        expect(crash.stderrTail, stderrLastLine);
      },
      testOn: '!windows',
    );

    test(
      'a pipe held open by a descendant does not keep this process alive',
      () async {
        final watch = Stopwatch()..start();
        final probe = await Process.run(Platform.resolvedExecutable, [
          File('test/integration/worker/exit_probe.dart').absolute.path,
          'hold-stderr',
        ]);
        expect(probe.stdout, contains('crashed'));
        expect(probe.exitCode, 0);
        // The descendant holds stderr for 20 s; the drain gives up after
        // 1 s. The bound leaves room for two JIT start-ups on a loaded
        // runner (measured 5.05 s against a 5 s bound in CI) and still fails
        // well before the descendant lets go.
        expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
      },
      testOn: '!windows',
    );

    test(
      'a worker that exits while a descendant holds stdout still crashes',
      () async {
        final watch = Stopwatch()..start();
        final channel = await _spawn('hold-stdout');
        final crash = await _crashOf(channel.turn(_configure));
        expect(crash.cause, CrashCause.vanished);
        expect(crash.exitCode, 0);
        // The descendant holds stdout for 6 s; the drain gives up after 1 s.
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      },
      testOn: '!windows',
    );

    test('a crash is final: every later turn throws the same error', () async {
      final channel = await _spawn('oom');
      final crashes = [
        for (var i = 0; i < 2; i++) await _crashOf(channel.turn(_configure)),
      ];
      // One object, twice: MontyCrashedError has identity equality.
      expect(crashes.toSet(), hasLength(1));
    });
  });

  group('kill', () {
    test('during a turn: killed', () async {
      final channel = await _spawn('hang');
      final turn = channel.turn(_configure);
      Timer(const Duration(milliseconds: 200), channel.kill);
      final crash = await _crashOf(turn);
      expect(crash.cause, CrashCause.killed);
      expect(crash.message, 'killed by the parent');
      expect(channel.isAlive, isFalse);
    });

    test('before a turn: the turn is killed; kill is idempotent', () async {
      final channel = await _spawn('serve');
      channel
        ..kill()
        ..kill();
      final crash = await _crashOf(channel.turn(_configure));
      expect(crash.cause, CrashCause.killed);
    });
  });

  group('close', () {
    test('Shutdown: the worker exits 0; close is idempotent', () async {
      final channel = await _spawn('serve');
      await channel.turn(_configure);
      await Future.wait([channel.close(), channel.close()]);
      expect(await channel.exitCode, 0);
      expect(channel.isAlive, isFalse);
      await expectLater(channel.turn(_configure), throwsStateError);
    });

    test('a worker that ignores Shutdown is killed after the grace', () async {
      final channel = await _spawn('ignore-shutdown');
      await channel.close();
      if (!Platform.isWindows) {
        expect(await channel.exitCode, -ProcessSignal.sigkill.signalNumber);
      }
    });

    test('during a turn: kills, and the turn reports killed', () async {
      final channel = await _spawn('hang');
      final turn = _crashOf(channel.turn(_configure));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await channel.close();
      expect((await turn).cause, CrashCause.killed);
    });

    test('after a crash: reaps without error', () async {
      final channel = await _spawn('eof');
      await _crashOf(channel.turn(_configure));
      await channel.close();
      expect(ProcessChannel.live, isNot(contains(channel)));
    });
  });

  group('environment', () {
    test('the worker starts with an empty environment', () async {
      final channel = await _spawn('env');
      final crash = await _crashOf(channel.turn(_configure));
      // The fake printed its environment's keys, then exited 0. macOS adds
      // __CF_USER_TEXT_ENCODING to every process it starts, so the check is
      // that nothing of this process's environment was passed on.
      final keys = (crash.stderrTail ?? '').split(',').toSet();
      expect(Platform.environment.keys, containsAll(['PATH', 'HOME']));
      expect(keys.difference({'', '__CF_USER_TEXT_ENCODING'}), isEmpty);
    }, testOn: '!windows');

    test('Windows keeps only SystemRoot', () {
      expect(
        workerEnvironment(
          isWindows: true,
          parent: {
            'SystemRoot': r'C:\Windows',
            'PATH': r'C:\bin',
            'HOME': r'C:\Users\a',
          },
        ),
        {'SystemRoot': r'C:\Windows'},
      );
    });

    test('Windows without SystemRoot: empty', () {
      expect(
        workerEnvironment(
          isWindows: true,
          parent: {'PATH': r'C:\bin'},
        ),
        isEmpty,
      );
    });

    test('elsewhere: empty, even with SystemRoot set', () {
      expect(
        workerEnvironment(
          isWindows: false,
          parent: {'SystemRoot': '/x', 'PATH': '/bin'},
        ),
        isEmpty,
      );
    });
  });

  group('registry', () {
    test('a live worker is registered until it exits', () async {
      final channel = await ProcessChannel.spawn(fakeWorker('serve'));
      expect(ProcessChannel.live, contains(channel));
      await channel.close();
      expect(ProcessChannel.live, isNot(contains(channel)));
    });

    test('a missing executable throws ProcessException', () async {
      await expectLater(
        ProcessChannel.spawn(
          const WorkerExecutable('/nonexistent/dart_monty_worker'),
        ),
        throwsA(isA<ProcessException>()),
      );
    });
  });

  test('WorkerExecutable.toString names the path', () {
    expect(const WorkerExecutable('/w').toString(), 'WorkerExecutable(/w)');
  });
}
