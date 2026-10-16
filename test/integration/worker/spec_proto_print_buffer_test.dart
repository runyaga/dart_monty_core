// Raw print-event boundaries from the pinned worker, independent of collectors.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart'
    show Monty, MontyCrashedError;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

const pb.PrintStream _out = pb.PrintStream.PRINT_STREAM_STDOUT;
const pb.PrintStream _err = pb.PrintStream.PRINT_STREAM_STDERR;
typedef _Segments = List<(pb.PrintStream, String)>;

Future<ProcessChannel> _channel({int interval = 86400000}) async {
  final channel = await ProcessChannel.spawn(await realWorker());
  addTearDown(channel.close);
  final configured = await channel.turn(
    pb.ParentRequest(
      configure: pb.Configure(
        protocolVersion: 5,
        scriptName: 'spec.py',
        limits: pb.ResourceLimits(maxMemoryBytes: Int64(64 * 1024 * 1024)),
        printFlushIntervalMs: interval,
      ),
    ),
  );
  expect(configured.whichKind(), pb.ChildEvent_Kind.ok);

  return channel;
}

Future<List<_Segments>> _prints(
  ProcessChannel channel,
  String code, {
  pb.ChildEvent_Kind ending = pb.ChildEvent_Kind.complete,
}) async {
  final events = <_Segments>[];
  final result = await channel.turn(
    pb.ParentRequest(feed: pb.Feed(code: code)),
    onPrint: (p) =>
        events.add([for (final s in p.segments) (s.stream, s.text)]),
  );
  expect(result.whichKind(), ending);

  return events;
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test('adjacent writes batch at 8192 bytes', () async {
    final channel = await _channel();
    expect(
      await _prints(
        channel,
        "print('a' * 4096, end='')\nprint('b' * 4097, end='')",
      ),
      [
        [(_out, '${'a' * 4096}${'b' * 4096}')],
        [(_out, 'b')],
      ],
    );
  });
  test(
    'interpreter polls flush an aged partial line',
    () async {
      final channel = await _channel(interval: 1);
      final events = <_Segments>[];
      final run = channel.turn(
        pb.ParentRequest(
          feed: pb.Feed(
            code: "print('pending', end='')\nwhile True:\n    pass",
          ),
        ),
        onPrint: (p) {
          events.add([for (final s in p.segments) (s.stream, s.text)]);
          channel.kill();
        },
      );
      await expectLater(run, throwsA(isA<MontyCrashedError>()));
      expect(events, [
        [(_out, 'pending')],
      ]);
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
  test(
    'omitted flush interval delivers a live partial line',
    () async {
      final pool = await Monty.start(maxProcesses: 1);
      addTearDown(pool.close);
      final session = await pool.checkout();
      addTearDown(session.close);
      final delivered = Completer<String>();
      final run = session.feedRun(
        "import time\nprint('pending', end='')\nstart = time.process_time()\n"
        'while time.process_time() - start < 0.025:\n    pass\n'
        'while True:\n    pass',
        printCallback: (_, text) => delivered.complete(text),
      );
      final stopped = expectLater(run, throwsA(isA<MontyCrashedError>()));
      try {
        expect(
          await delivered.future.timeout(const Duration(seconds: 20)),
          'pending',
        );
      } finally {
        await session.close();
      }
      await stopped;
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
  test(
    'streams share capacity across a stream change',
    () async {
      final channel = await _channel();
      expect(
        await _prints(
          channel,
          "import sys\nprint('a' * 4096, end='')\n"
          "print('b' * 4097, end='', file=sys.stderr)",
        ),
        [
          [(_out, 'a' * 4096), (_err, 'b' * 4096)],
          [(_err, 'b')],
        ],
      );
    },
  );
  test(
    'UTF-8 characters fit whole within the threshold',
    () async {
      final channel = await _channel();
      expect(
        await _prints(
          channel,
          "print('a' * 8191, end='')\nprint('é😀', end='')",
        ),
        [
          [(_out, 'a' * 8191)],
          [(_out, 'é😀')],
        ],
      );
    },
  );
  test(
    'zero interval retains partial lines',
    () async {
      final channel = await _channel(interval: 0);
      expect(
        await _prints(
          channel,
          "print('a\\nb\\ntail', end='')\nprint('end', end='')",
        ),
        [
          [(_out, 'a\n')],
          [(_out, 'b\n')],
          [(_out, 'tailend')],
        ],
      );
      expect(await _prints(channel, "print('é' * 4097, end='')"), [
        [(_out, 'é' * 4096)],
        [(_out, 'é')],
      ]);
    },
  );
  test(
    'one line has one event and separate callbacks',
    () async {
      final channel = await _channel(interval: 0);
      expect(
        await _prints(
          channel,
          "import sys\nprint('left', end='')\nprint('right', file=sys.stderr)",
        ),
        [
          [(_out, 'left'), (_err, 'right\n')],
        ],
      );
      // ProtoSession preserves the two segment boundaries in callback delivery.
      final fresh = await ProcessChannel.spawn(await realWorker());
      addTearDown(fresh.close);
      final session = await ProtoSession.open(
        fresh,
        const SessionConfig(printFlushInterval: Duration.zero),
      );
      final fragments = <(String, String)>[];
      await session.feed(
        "import sys\nprint('left', end='')\nprint('right', file=sys.stderr)",
        onPrint: (stream, text) => fragments.add((stream, text)),
      );
      expect(fragments, [('stdout', 'left'), ('stderr', 'right\n')]);
    },
  );
  test(
    'flush True does not force partial output delivery',
    () async {
      final channel = await _channel();
      expect(
        await _prints(
          channel,
          "print('a', end='', flush=True)\nprint('b', end='')",
        ),
        [
          [(_out, 'ab')],
        ],
      );
    },
  );
}
