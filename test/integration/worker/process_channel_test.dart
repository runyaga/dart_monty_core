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

import '../../_accessors.dart';
import '_worker_harness.dart';
import 'fake_worker.dart'
    show
        bigFramePrefixPrints,
        bigFrameSuffixPrints,
        bigPrintLength,
        fatalMessage,
        floodPrintLength,
        floodPrints,
        stderrLastLine;

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

  test('a request the worker cannot read is a crash, not a hang', () async {
    // A "worker" that closes its stdin at once and keeps stdout open.
    final channel = await ProcessChannel.spawn(
      const WorkerExecutable(
        '/bin/sh',
        args: ['-c', 'exec 0<&-; exec /bin/sleep 30'],
      ),
    );
    addTearDown(channel.close);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await expectLater(
      channel.turn(_configure).timeout(const Duration(seconds: 15)),
      throwsA(isA<MontyCrashedError>()),
    );
  }, testOn: '!windows');

  group('bounded read-ahead', () {
    const limit = ProcessChannel.readAheadLimit;

    /// Waits until [channel]'s read-ahead has not changed for 300 ms, so a
    /// reader that keeps reading has had the time to show it.
    Future<int> settled(ProcessChannel channel) async {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      var last = -1;
      var stableSince = DateTime.now();
      while (DateTime.now().isBefore(deadline)) {
        final now = channel.readAhead.now;
        if (now != last) {
          last = now;
          stableSince = DateTime.now();
        } else if (now > 0 &&
            DateTime.now().difference(stableSince) >
                const Duration(milliseconds: 300)) {
          return now;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      return fail('the read-ahead never settled (last: $last bytes)');
    }

    /// The `#<n>:` numbers of [texts], in order.
    List<int> numbers(List<String> texts) => [
      for (final t in texts) int.parse(t.substring(1, t.indexOf(':'))),
    ];

    test('a flood no turn reads stays bounded and is kept for the next '
        'turn', () async {
      final channel = await _spawn('flood');
      expect(
        (await channel.turn(_configure)).whichKind(),
        pb.ChildEvent_Kind.ok,
      );
      // 32 MiB arrive with no turn reading them.
      final held = await settled(channel);
      expect(held, greaterThanOrEqualTo(limit));
      final bounded = lessThan(limit + (1 << 20));
      expect(channel.readAhead.peak, bounded);

      // Nothing was dropped: the next turn reads every Print, in order,
      // then the Complete.
      final texts = <String>[];
      final end = await channel.turn(
        _feed('ignored'),
        onPrint: (print) => texts.addAll([
          for (final s in print.segments) s.text,
        ]),
      );
      expect(end.whichKind(), pb.ChildEvent_Kind.complete);
      expect(numbers(texts), List.generate(floodPrints, (i) => i));
      expect(texts.every((t) => t.length == floodPrintLength), isTrue);
      final afterward = channel.readAhead;
      expect(afterward.now, 0);
      expect(afterward.peak, bounded);
    });

    test(
      'a request larger than the pipe is sent while stdout is paused',
      () async {
        final channel = await _spawn('flood');
        expect(
          (await channel.turn(_configure)).whichKind(),
          pb.ChildEvent_Kind.ok,
        );
        // Paused at the limit: the worker is blocked writing, so it reads no
        // stdin until the parent reads stdout again.
        expect(await settled(channel), greaterThanOrEqualTo(limit));
        final printed = <pb.Print>[];
        final end = await channel
            .turn(_feed('#' * (2 << 20)), onPrint: printed.add)
            .timeout(const Duration(seconds: 20));
        expect(end.whichKind(), pb.ChildEvent_Kind.complete);
        expect(printed, hasLength(floodPrints));
      },
    );

    test('a descendant writing after the worker exits stays bounded', () async {
      final channel = await _spawn('exit-leaving-writer');
      expect(
        (await channel.turn(_configure)).whichKind(),
        pb.ChildEvent_Kind.ok,
      );
      await channel.exitCode;
      // Draining after the exit reads what the pipe held, no more.
      await settled(channel);
      expect(
        channel.readAhead.peak,
        lessThan(limit + ProcessChannel.drainAllowance + (1 << 20)),
      );
    });

    test('a frame larger than the limit completes; later ones wait', () async {
      final channel = await _spawn('big-frame');
      expect(
        (await channel.turn(_configure)).whichKind(),
        pb.ChildEvent_Kind.ok,
      );
      // 3 MiB, then an 8 MiB frame in 64 KiB pieces: it must finish, not
      // stall half-read; the 2 MiB after it wait.
      const before = bigFramePrefixPrints * (floodPrintLength + 8);
      final held = await settled(channel);
      expect(held, greaterThan(before + bigPrintLength));
      expect(
        channel.readAhead.peak,
        lessThan(before + bigPrintLength + (1 << 20)),
      );

      final texts = <String>[];
      final end = await channel.turn(
        _feed('ignored'),
        onPrint: (print) => texts.addAll([
          for (final s in print.segments) s.text,
        ]),
      );
      expect(end.whichKind(), pb.ChildEvent_Kind.complete);
      expect(
        numbers(texts),
        List.generate(
          bigFramePrefixPrints + 1 + bigFrameSuffixPrints,
          (i) => i,
        ),
      );
      expect(itemAt(texts, bigFramePrefixPrints).length, bigPrintLength);
    });
  });

  group('EventQueue, with chosen chunk boundaries', () {
    const limit = 1000;

    /// A frame carrying a stdout Print of [text].
    List<int> frame(String text) => Frame.encode(
      pb.ChildEvent(
        print: pb.Print(
          segments: [
            pb.PrintSegment(
              stream: pb.PrintStream.PRINT_STREAM_STDOUT,
              text: text,
            ),
          ],
        ),
      ),
    );

    late StreamController<List<int>> bytes;
    late EventQueue queue;

    var desyncs = 0;

    setUp(() {
      desyncs = 0;
      bytes = StreamController();
      queue = EventQueue(bytes.stream, limit: limit, onDesync: () => desyncs++);
      addTearDown(queue.cancel);
      addTearDown(() => expect(desyncs, 0));
    });

    /// Lets the subscription deliver what was added.
    Future<void> pump() => Future.delayed(Duration.zero);

    /// Reads one event per entry of [texts] and checks its Print's text.
    Future<void> expectTexts(List<String> texts) async {
      for (final text in texts) {
        final event = await queue.next() ?? fail('the queue ended');
        expect(onlyItem(event.print.segments).text, text);
      }
    }

    test(
      'draining past an oversized queue still reads the last frames',
      () async {
        final pipe = StreamController<List<int>>();
        final drained = EventQueue(
          pipe.stream,
          limit: limit,
          onDesync: () => desyncs++,
          drainAllowance: 100,
        );
        addTearDown(drained.cancel);
        // Oversized and unread: paused well past the limit plus allowance.
        pipe.add(frame('c' * 5000));
        await pump();
        expect(pipe.isPaused, isTrue);
        // The worker's last frame waits in the pipe, then the worker exits.
        pipe.add(frame('fatal'));
        final ending = drained.endWithin(const Duration(milliseconds: 500));
        await pump();
        unawaited(pipe.close());
        await ending;
        for (final text in ['c' * 5000, 'fatal']) {
          final event = await drained.next() ?? fail('lost the frame $text');
          expect(onlyItem(event.print.segments).text, text);
        }
      },
    );

    test('draining with a large frame half-received still reads the last '
        'frames', () async {
      final pipe = StreamController<List<int>>();
      final drained = EventQueue(
        pipe.stream,
        limit: limit,
        onDesync: () => desyncs++,
        drainAllowance: 100,
      );
      addTearDown(drained.cancel);
      final big = frame('c' * 5000);
      // Over the limit, with the large frame only begun.
      pipe.add([...frame('a' * 600), ...frame('b' * 600), ...big.take(100)]);
      await pump();
      final ending = drained.endWithin(const Duration(milliseconds: 500));
      // The worker had written the rest, then its last frame, then exited.
      pipe.add(big.skip(100).toList());
      await pump();
      pipe.add(frame('fatal'));
      await pump();
      unawaited(pipe.close());
      await ending;
      for (final text in ['a' * 600, 'b' * 600, 'c' * 5000, 'fatal']) {
        final event = await drained.next() ?? fail('lost the frame $text');
        expect(onlyItem(event.print.segments).text, text);
      }
    });

    test('pauses at the limit when no frame is part-received', () async {
      bytes.add(frame('a' * 600));
      await pump();
      expect(bytes.isPaused, isFalse);
      bytes.add(frame('b' * 600));
      await pump();
      expect(queue.readAhead, greaterThanOrEqualTo(limit));
      expect(bytes.isPaused, isTrue);
      await expectTexts(['a' * 600]);
      expect(bytes.isPaused, isFalse, reason: 'under the limit again');
    });

    test(
      'the frame in flight at the limit completes, then it pauses',
      () async {
        final big = frame('c' * 5000);
        final next = frame('d');
        // One chunk: two frames, over the limit, then the first 100 bytes of
        // a large frame.
        bytes.add([...frame('a' * 600), ...frame('b' * 600), ...big.take(100)]);
        await pump();
        expect(queue.readAhead, greaterThanOrEqualTo(limit));
        expect(bytes.isPaused, isFalse, reason: 'a frame is in flight');
        // The rest of it in pieces; the last piece also starts the next frame.
        for (var at = 100; at < big.length - 700; at += 700) {
          bytes.add(big.sublist(at, at + 700));
          await pump();
          expect(bytes.isPaused, isFalse, reason: 'still in flight at $at');
        }
        final done = (big.length - 100) ~/ 700 * 700 + 100;
        bytes.add([...big.sublist(done), ...next.take(3)]);
        await pump();
        expect(queue.readAhead, greaterThan(limit + 5000));
        expect(bytes.isPaused, isTrue, reason: 'paused once it ended');
        await expectTexts(['a' * 600, 'b' * 600]);
        expect(bytes.isPaused, isTrue, reason: 'still over the limit');
        await expectTexts(['c' * 5000]);
        expect(bytes.isPaused, isFalse);
        bytes.add(next.skip(3).toList());
        await expectTexts(['d']);
      },
    );
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
