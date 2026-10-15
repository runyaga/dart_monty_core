// Snapshots, futures, OS calls and the budgets against the real worker
// executable (tool/build_worker.sh, or the CI artefact): the expected values
// are upstream's (pydantic-monty 1.1.0) for the same code.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyComplete, MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../unit/worker/_attribute_cases.dart';
import '../../unit/worker/_cwd_cases.dart';
import '../../unit/worker/_host_code_cases.dart';
import '_worker_harness.dart';

/// Every session's memory is bounded.
const _limits = SessionConfig(
  limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
);

/// Prints the test does not look at, dropped.
void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// Runs [body] with a session on a one-worker pool of the real worker.
Future<void> _withSession(
  Future<void> Function(PoolSession s) body, {
  SessionConfig options = _limits,
}) async {
  final location = await realWorker() as WorkerExecutable;
  await MontyPool.withPool(
    (pool) => pool.withSession(body, options: options),
    options: PoolOptions(maxProcesses: 1, workerLocation: location.path),
  );
}

Matcher _raised(String excType, [Object? message]) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'excType', excType)
    .having((e) => e.exception.message, 'message', message ?? anything);

void main() {
  expectNoWorkersLeftAfterEachTest();
  attributeSessionTests('vm', _withSession);
  cwdSessionTests('vm', _withSession);
  hostCodeSessionTests(
    'vm',
    (config, body) => _withSession(body, options: config),
  );

  test('a host call: name, arguments, position; resumed', () async {
    await _withSession((s) async {
      final snap =
          await s.feedStart("g = 1\ny = f(2, k='é')\ny", printCallback: _ignore)
              as FunctionSnapshot;
      expect(snap.functionName, 'f');
      expect(snap.args, [const MontyInt(2)]);
      expect(snap.kwargs, {'k': const MontyString('é')});
      // Upstream's (pydantic-monty 1.1.0) range, in UTF-8 bytes.
      expect(
        snap.position,
        SourceRange(filename: '<python-input-0>', start: 10, end: 22),
      );
      expect(snap.scriptName, 'main.py');
      final done = await snap.resume(const ExternalReturnValue(MontyInt(5)));
      expect((done as SessionComplete).output, const MontyInt(5));
    });
  });

  test('futures settled one at a time (upstream api_futures_gather)', () async {
    await _withSession((s) async {
      var snap = await s.feedStart(
        'import asyncio\nr = await asyncio.gather(f(1), f(2))\nr',
        printCallback: _ignore,
      );
      final ids = <int>[];
      while (snap is FunctionSnapshot) {
        ids.add(snap.callId);
        snap = await snap.resume(const ExternalFuture());
      }
      final futures = snap as FutureSnapshot;
      expect(futures.pendingCallIds, unorderedEquals(ids));
      final rest =
          await futures.resume({
                itemAt(ids, 1): const ExternalReturnValue(MontyInt(20)),
              })
              as FutureSnapshot;
      expect(rest.pendingCallIds, [firstItem(ids)]);
      final done = await rest.resume({
        firstItem(ids): const ExternalReturnValue(MontyInt(10)),
      });
      expect(
        (done as SessionComplete).output,
        const MontyList([MontyInt(10), MontyInt(20)]),
      );
    });
  });

  test('a future settled with an exception is caught in the sandbox', () async {
    await _withSession((s) async {
      final call =
          await s.feedStart(
                'try:\n    r = await f(1)\nexcept ValueError as e:\n'
                '    r = "caught ValueError: " + str(e)\nr',
                printCallback: _ignore,
              )
              as FunctionSnapshot;
      final futures =
          await call.resume(const ExternalFuture()) as FutureSnapshot;
      final done = await futures.resume({
        call.callId: const ExternalException('ValueError', 'boom'),
      });
      expect(
        (done as SessionComplete).output,
        const MontyString('caught ValueError: boom'),
      );
    });
  });

  test('asyncio.sleep in feedRun: gathered tasks overlap', () async {
    await _withSession((s) async {
      // The three sleeps' timers are held, not run: all three are armed
      // before any ends only if the sleeps overlap (sleeps waited one after
      // another would arm one at a time, and the second never). Then they
      // are fired in deadline order, and each task, ending, sees all three
      // started. No wall clock involved; the timeout only bounds a hang.
      final held = <_HeldTimer>[];
      final armed = Completer<void>();
      final run = runZoned(
        () => s.feedRun(
          'import asyncio\nstarted = []\nasync def a(n):\n'
          '    started.append(n)\n    await asyncio.sleep(0.4 * n)\n'
          '    return list(started)\nawait asyncio.gather(a(3), a(1), a(2))',
          printCallback: _ignore,
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (!_gatheredSleeps.contains(duration)) {
              return parent.createTimer(zone, duration, callback);
            }
            final timer = _HeldTimer(duration, callback);
            held.add(timer);
            if (held.length == _gatheredSleeps.length) armed.complete();

            return timer;
          },
        ),
      );
      await armed.future.timeout(const Duration(seconds: 20));
      held.sort((a, b) => a.duration.compareTo(b.duration));
      for (final timer in held) {
        timer.fire();
      }
      const all = MontyList([MontyInt(3), MontyInt(1), MontyInt(2)]);
      expect(await run, const MontyList([all, all, all]));
      expect(
        await s.feedRun(
          'import asyncio\nawait asyncio.sleep(0.01, result=7)',
          printCallback: _ignore,
        ),
        const MontyInt(7),
      );
    });
  });

  test('host coroutines gathered, delivered as they finish', () async {
    await _withSession((s) async {
      final value = await s.feedRun(
        'import asyncio\nawait asyncio.gather(af(1), af(2))',
        printCallback: _ignore,
        externals: {
          'af': coroutine((args, kwargs) async {
            final n = (firstItem(args) as MontyInt).value;
            await Future<void>.delayed(Duration(milliseconds: (3 - n) * 10));

            return MontyInt(n * 10);
          }),
        },
      );
      expect(value, const MontyList([MontyInt(10), MontyInt(20)]));
    });
  });

  test('OS calls answered as values by the handler', () async {
    await _withSession((s) async {
      final calls = <String>[];
      final value = await s.feedRun(
        "from pathlib import Path\nimport os\nn = Path('/a.txt').write_text('hi')\n"
        "Path('/d/e').mkdir(parents=True, exist_ok=True)\n"
        "b = Path('/a.txt').rename('/b.txt')\n"
        "h = os.getenv('HOME', 'none')\n(n, str(b), h)",
        printCallback: _ignore,
        os: (name, args, kwargs) async {
          calls.add('$name $args $kwargs');

          return switch (name) {
            'Path.write_text' => const MontyInt(2),
            'Path.rename' => const MontyPath('/b.txt'),
            'os.getenv' => const MontyString('/home/u'),
            _ => const MontyNone(),
          };
        },
      );
      expect(
        value,
        const MontyTuple([
          MontyInt(2),
          MontyString('/b.txt'),
          MontyString('/home/u'),
        ]),
      );
      expect(calls, hasLength(4));
      final mkdir = itemAt(calls, 1);
      expect(mkdir, contains('Path.mkdir'));
      expect(mkdir, contains('parents'));
    });
  });

  test('the sleep budget: charged before waiting, uncatchable, refused '
      'sleeps uncharged', () async {
    await _withSession(
      (s) async {
        final over = throwsA(
          _raised('TimeoutError', 'sleep limit exceeded: 300ms > 250ms'),
        );
        expect(
          await s.feedRun(
            'import time\ntime.sleep(0.2)\n1',
            printCallback: _ignore,
          ),
          const MontyInt(1),
        );
        await expectLater(
          s.feedRun('time.sleep(0.1)\n2', printCallback: _ignore),
          over,
        );
        await expectLater(
          s.feedRun(
            'try:\n    time.sleep(0.1)\nexcept BaseException:\n    pass\n3',
            printCallback: _ignore,
          ),
          over,
        );
        expect(
          await s.feedRun(
            'import asyncio\nawait asyncio.sleep(0.04)\n4',
            printCallback: _ignore,
          ),
          const MontyInt(4),
        );
        await expectLater(
          s.feedRun('await asyncio.sleep(0.02)\n5', printCallback: _ignore),
          throwsA(
            _raised('TimeoutError', 'sleep limit exceeded: 260ms > 250ms'),
          ),
        );
      },
      options: const SessionConfig(
        limits: ResourceLimits(
          maxMemory: 64 * 1024 * 1024,
          maxTotalSleep: Duration(milliseconds: 250),
        ),
      ),
    );
  });

  test('a function value comes back as its name (input-only)', () async {
    await _withSession((s) async {
      final value = await s.feedRun(
        'fetch',
        printCallback: _ignore,
        externals: {'fetch': (args, kwargs) => const MontyNone()},
      );
      expect(value, const MontyString('fetch'));
    });
  });

  test('an oversized manual resume fails; the snapshot is spent and the '
      'feed refused', () async {
    await _withSession((s) async {
      final snap =
          await s.feedStart('f()', printCallback: _ignore) as FunctionSnapshot;
      await expectLater(
        snap.resume(
          ExternalReturnValue(MontyBytes(Uint8List(256 * 1024 * 1024 + 1))),
        ),
        throwsA(
          _raised(
            'RuntimeError',
            'request frame of 268435487 bytes exceeds the maximum of '
                '268435456 bytes',
          ),
        ),
      );
      expect(
        () => snap.resume(const ExternalReturnValue(MontyInt(1))),
        throwsStateError,
      );
      await expectLater(
        s.feedRun('3', printCallback: _ignore),
        throwsStateError,
      );
    });
  });
}

/// The delays the gathered-sleeps test holds: `asyncio.sleep(0.4 * n)` for
/// n in 1..3, as the session waits them.
final Set<Duration> _gatheredSleeps = {
  const Duration(milliseconds: 400),
  const Duration(milliseconds: 800),
  const Duration(milliseconds: 1200),
};

/// A timer that runs only when the test fires it.
final class _HeldTimer implements Timer {
  _HeldTimer(this.duration, this._callback);

  /// The delay it was created with.
  final Duration duration;
  final void Function() _callback;
  bool _isActive = true;

  /// Runs the callback now, unless cancelled or already run.
  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  @override
  void cancel() => _isActive = false;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _isActive ? 0 : 1;
}
