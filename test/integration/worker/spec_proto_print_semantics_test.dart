// Python print validation, suspension flushing and host-only failures.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const _deep =
    'class Bad:\n    def __str__(self):\n'
    '        raise ValueError("render")\nv = Bad()\n';

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'partial text flushes before turn endings',
    () async {
      final session = await protoBoundedSession();
      final sink = CollectStreams();
      final lookup =
          await session.feedStart(
                "print('a', end='')\nx = missing\n"
                "print('b', end='')\nf()\nprint('c', end='')\n42",
                printCallback: sink.call,
              )
              as NameLookupSnapshot;
      expect(sink.output, [('stdout', 'a')]);
      final call =
          await lookup.resume(value: const MontyInt(1)) as FunctionSnapshot;
      expect(sink.output, [('stdout', 'a'), ('stdout', 'b')]);
      expect(
        (await call.resume(const ExternalReturnValue(MontyNone()))
                as MontyComplete)
            .output,
        const MontyInt(42),
      );
      expect(sink.output, [('stdout', 'a'), ('stdout', 'b'), ('stdout', 'c')]);
    },
  );

  test(
    'OS, future and error endings flush partial text',
    () async {
      final session = await protoBoundedSession();
      final sink = CollectString();
      final os =
          await session.feedStart(
                "import os\nprint('os', end='')\nos.getenv('X')",
                printCallback: sink.call,
              )
              as FunctionSnapshot;
      expect(os.isOsFunction, isTrue);
      expect(sink.output, 'os');
      await os.resume(const ExternalReturnValue(MontyNone()));
      final call =
          await session.feedStart(
                "pending = f()\nprint('future', end='')\nawait pending",
                printCallback: sink.call,
              )
              as FunctionSnapshot;
      final future =
          await call.resume(const ExternalFuture()) as FutureSnapshot;
      expect(sink.output, 'osfuture');
      await future.resume({
        call.callId: const ExternalReturnValue(MontyNone()),
      });
      await expectLater(
        session.feedRun(
          "print('error', end='')\nraise ValueError('boom')",
          printCallback: sink.call,
        ),
        throwsA(protoRuntime('ValueError', 'boom')),
      );
      expect(sink.output, 'osfutureerror');
    },
  );

  test(
    'sep, end and file precede rendering',
    () async {
      final session = await protoBoundedSession();
      final sink = CollectString();
      for (final (args, message) in [
        ('sep=1, end=2, file=3', 'sep must be None or a string, not int'),
        ('sep="|", end=2, file=3', 'end must be None or a string, not int'),
        (
          'sep="|", end="!", file=3',
          "print() 'file' argument must be sys.stdout or sys.stderr, not int",
        ),
      ]) {
        await expectLater(
          session.feedRun('${_deep}print(v, $args)', printCallback: sink.call),
          throwsA(protoRuntime('TypeError', message)),
        );
        expect(sink.output, '');
      }
    },
  );

  test(
    'only None and system streams are valid print files',
    () async {
      final session = await protoBoundedSession();
      final sink = CollectStreams();
      await session.feedRun(
        "import sys\nprint('a', file=None)\n"
        "print('b', file=sys.stdout)\nprint('c', file=sys.stderr)",
        printCallback: sink.call,
      );
      expect(sink.output, [('stdout', 'a\nb\n'), ('stderr', 'c\n')]);
      await expectLater(
        session.feedRun("print('bad', file=123)", printCallback: sink.call),
        throwsA(
          protoRuntime(
            'TypeError',
            "print() 'file' argument must be sys.stdout or sys.stderr, not int",
          ),
        ),
      );
      expect(sink.output, [('stdout', 'a\nb\n'), ('stderr', 'c\n')]);
    },
  );

  test(
    'failed rendering retains text and separator',
    () async {
      final session = await protoBoundedSession();
      final sink = CollectString();
      await expectLater(
        session.feedRun(
          '${_deep}print("before", v, sep="|", end="END")',
          printCallback: sink.call,
        ),
        throwsA(
          protoRuntime('ValueError', 'render'),
        ),
      );
      expect(sink.output, 'before|');
    },
  );

  for (final kind in ['callback', 'string', 'streams']) {
    test(
      'Python cannot catch a $kind delivery failure',
      () async {
        final session = await protoBoundedSession(
          printFlushInterval: Duration.zero,
        );
        final strings = CollectString(maxBytes: 0);
        final streams = CollectStreams(maxBytes: 64);
        void callback(String stream, String text) {
          switch (kind) {
            case 'string':
              strings(stream, text);
            case 'streams':
              streams(stream, text);
            default:
              throw const ExternalException('ValueError', 'host failure');
          }
        }

        final matcher = kind == 'callback'
            ? protoRuntime('ValueError', 'host failure')
            : protoRuntime(
                'MemoryError',
                kind == 'string'
                    ? 'memory limit exceeded: 2 bytes > 0 bytes'
                    : 'memory limit exceeded: 66 bytes > 64 bytes',
              );
        await expectLater(
          session.feedRun(
            'caught = False\ntry:\n    print("x")\n'
            'except BaseException:\n    caught = True\ncaught',
            printCallback: callback,
          ),
          throwsA(matcher),
        );
        expect(await session.feedRun('caught'), const MontyBool(false));
        expect(strings.output, '');
        expect(streams.output, isEmpty);
      },
    );
  }
}
