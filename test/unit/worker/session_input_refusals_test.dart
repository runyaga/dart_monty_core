// Tests for what the writer refuses when a value reaches a session: an input or
// a manual answer holding a byte outside 0..255, a date or time outside
// Python's range, a negative file position, or a cyclic attribute container.
// The call throws before a frame is sent, the session stays usable and a
// manual-resume snapshot stays pending for a retry. Pure Dart over a scripted
// worker: vm, dart2js and dart2wasm.
import 'dart:collection';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyComplete, MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show montyClassProxy, montyClassTypeProxy;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';

Future<Monty> _pool(ScriptedChannel channel) {
  final next = Queue.of([channel]);

  return startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => next.removeFirst()),
  );
}

/// A session over a worker that accepts `Configure`, then answers [script].
Future<(MontySession, ScriptedChannel)> _session(List<Reply> script) async {
  final ch = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    ...script,
  ]);
  final pool = await _pool(ch);
  addTearDown(pool.close);
  final session = await pool.checkoutWith(
    const SessionConfig(scriptName: 'job.py'),
  );
  addTearDown(session.close);

  return (session, ch);
}

/// A call to the host function [name] with no arguments.
pb.ChildEvent _call(String name, int id) => pb.ChildEvent(
  functionCall: pb.FunctionCall(
    functionName: name,
    callId: id,
    values: ArenaWriter().arena,
  ),
);

pb.ChildEvent _int(int n) => complete([intNode(n)]);

pb.ChildEvent _lookup(String name) =>
    pb.ChildEvent(nameLookup: pb.NameLookup(name: name));

pb.ChildEvent _string(String value) => complete([pb.MontyNode(str: value)]);

/// A list that contains itself.
MontyList _cyclic() {
  final items = <MontyValue>[];
  final list = MontyList(items);
  items.add(list);

  return list;
}

MontyClassTypeProxy _cyclicClassType() {
  final loopItems = <MontyValue>[];
  final loop = MontyList(loopItems);
  loopItems.add(loop);

  return montyClassTypeProxy(
    name: 'P',
    id: _classId,
    hostDefined: true,
    isDataclass: true,
    attrs: {'loop': loop},
  );
}

const _classId = '0123abcd-0000-4000-8000-00000000cafe';

/// Values a session must refuse, and the reason.
final Map<String, MontyValue> _refused = {
  'a byte above 255': const MontyBytes([1, 256]),
  'a negative byte': const MontyBytes([-1]),
  'a byte inside a list': const MontyList([
    MontyBytes([1000]),
  ]),
  'a date past year 9999': const MontyDate(year: 10000, month: 1, day: 1),
  'a month 13': const MontyDate(year: 2026, month: 13, day: 1),
  'a day 31 of April': const MontyDate(year: 2026, month: 4, day: 31),
  'an hour 24': const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0),
  'a time offset of a day': const MontyTime(
    hour: 1,
    minute: 0,
    second: 0,
    microsecond: 0,
    offsetSeconds: 86400,
  ),
  'a datetime second 60': const MontyDateTime(
    year: 2026,
    month: 1,
    day: 1,
    hour: 0,
    minute: 0,
    second: 60,
  ),
};

const _surrogateMessage =
    "'utf-8' codec can't encode character "
    r"'\ud800' in position 0: surrogates not allowed";

const _surrogateDiagnostic = 'UnicodeEncodeError: $_surrogateMessage';

/// Checks the error that an automatic host answer sends back to Python.
Reply _automaticRefusal(String type, String text, List<pb.ChildEvent> reply) =>
    (request) {
      expect(request.whichKind(), pb.ParentRequest_Kind.resumeCall);
      final result = request.resumeCall.result;
      expect(result.whichKind(), pb.ExtFunctionResult_Kind.error);
      expect(result.error.excType, type);
      expect(result.error.message, text);

      return reply;
    };

void main() {
  group('an input is refused before a frame is sent', () {
    for (final MapEntry(key: what, :value) in _refused.entries) {
      test(what, () async {
        final (s, ch) = await _session([
          answer([_int(7)]),
        ]);
        await expectLater(
          s.feedRun('x', inputs: {'x': value}),
          throwsArgumentError,
        );
        // Only Configure was sent, and the session is still usable.
        expect(ch.requests, hasLength(1));
        expect(await s.feedRun('7'), const MontyInt(7));
      });
    }

    test('a byte outside 0..255 in an input', () async {
      final (s, ch) = await _session([
        answer([_int(1)]),
      ]);
      for (final bytes in [
        const MontyBytes([256]),
        const MontyBytes([0, 1, 300]),
        const MontyBytes([-1]),
        const MontyBytes([-128]),
      ]) {
        await expectLater(
          s.feedRun('x', inputs: {'x': bytes}),
          throwsA(
            isA<ArgumentError>().having(
              (e) => '${e.message}',
              'message',
              contains('is outside 0..255'),
            ),
          ),
        );
      }
      expect(ch.requests, hasLength(1));
      // 0 and 255 are bytes.
      expect(
        await s.feedRun(
          'x',
          inputs: {
            'x': const MontyBytes([0, 255]),
          },
        ),
        const MontyInt(1),
      );
    });

    test(
      'a refused input leaves the session usable',
      () async {
        final (s, ch) = await _session([
          answer([_int(5)]),
        ]);
        for (final value in _refused.values) {
          await expectLater(
            s.feedRun('x', inputs: {'x': value}),
            throwsArgumentError,
          );
        }
        expect(ch.requests, hasLength(1));
        expect(await s.feedRun('5'), const MontyInt(5));
        expect(ch.requests, hasLength(2));
      },
    );

    test('a negative file position', () {
      expect(
        () => MontyFileHandle('/f', 'r', position: BigInt.from(-1)),
        throwsArgumentError,
      );
      expect(
        () => MontyFileHandle('/f', 'r', position: BigInt.one << 64),
        throwsArgumentError,
      );
      expect(
        MontyFileHandle(
          '/f',
          'r',
          position: (BigInt.one << 64) - BigInt.one,
        ).position,
        (BigInt.one << 64) - BigInt.one,
      );
    });

    test('invalid byte and calendar inputs are ArgumentErrors', () async {
      final (s, ch) = await _session([]);
      for (final value in [
        const MontyBytes([256]),
        const MontyDate(year: 0, month: 1, day: 1),
        const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0),
      ]) {
        await expectLater(
          s.feedRun('x', inputs: {'x': value}),
          throwsArgumentError,
        );
      }
      expect(
        () => MontyFileHandle('/f', 'r', position: BigInt.from(-1)),
        throwsArgumentError,
      );
      expect(ch.requests, hasLength(1));
    });

    test(
      'an unpaired string sends no request and leaves the session usable',
      () async {
        final (s, ch) = await _session([
          answer([_int(3)]),
        ]);
        await expectLater(
          s.feedRun('x', inputs: {'x': const MontyString('\uD800')}),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.toString(),
              'diagnostic',
              _surrogateDiagnostic,
            ),
          ),
        );
        expect(ch.requests, hasLength(1));
        expect(await s.feedRun('3'), const MontyInt(3));
      },
    );

    test('a self-referential list sends no request and leaves the session '
        'usable', () async {
      final (s, ch) = await _session([
        answer([_int(4)]),
      ]);
      await expectLater(
        s.feedRun('x', inputs: {'x': _cyclic()}),
        throwsA(
          isA<MontyRuntimeError>()
              .having(
                (e) => e.exception.excType,
                'exception type',
                'ValueError',
              )
              .having(
                (e) => e.toString(),
                'diagnostic',
                'ValueError: Circular reference detected',
              ),
        ),
      );
      expect(ch.requests, hasLength(1));
      expect(await s.feedRun('4'), const MontyInt(4));
    });
  });

  group('a manual answer is refused, the snapshot stays pending', () {
    for (final MapEntry(key: what, :value) in _refused.entries) {
      test(what, () async {
        final (s, ch) = await _session([
          answer([_call('f', 1)]),
          answer([_int(1)]),
        ]);
        final snap = await s.feedStart('f()') as FunctionSnapshot;
        final sent = ch.requests.length;
        expect(
          () => snap.resume(ExternalReturnValue(value)),
          throwsArgumentError,
        );
        expect(ch.requests, hasLength(sent));
        expect(snap.isSpent, isFalse);
        // A retry with a good value completes the run.
        await snap.resume(const ExternalReturnValue(MontyInt(1)));
        expect(ch.requests, hasLength(sent + 1));
      });
    }

    test('a manual answer holding a bad byte', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        answer([_int(1)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      final sent = ch.requests.length;
      expect(
        () => snap.resume(const ExternalReturnValue(MontyBytes([256]))),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            'byte 256 at index 0 is outside 0..255',
          ),
        ),
      );
      expect(ch.requests, hasLength(sent));
      expect(snap.isSpent, isFalse);
      await snap.resume(const ExternalReturnValue(MontyBytes([255])));
    });

    test(
      'the pending snapshot is kept for a retry',
      () async {
        final (s, ch) = await _session([
          answer([_call('f', 1)]),
          answer([_int(2)]),
        ]);
        final snap = await s.feedStart('f()') as FunctionSnapshot;
        for (final value in [
          const MontyBytes([999]),
          const MontyDate(year: 0, month: 1, day: 1),
          const MontyTime(hour: 0, minute: 60, second: 0, microsecond: 0),
        ]) {
          expect(
            () => snap.resume(ExternalReturnValue(value)),
            throwsArgumentError,
          );
          expect(snap.isSpent, isFalse);
        }
        expect(ch.requests, hasLength(2));
        await snap.resume(const ExternalReturnValue(MontyInt(2)));
      },
    );

    test('a circular result leaves the snapshot pending for a corrected '
        'retry', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        answer([_int(5)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      final sent = ch.requests.length;
      expect(
        () => snap.resume(ExternalReturnValue(_cyclic())),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.toString(),
            'diagnostic',
            'ValueError: Circular reference detected',
          ),
        ),
      );
      expect(snap.isSpent, isFalse);
      expect(ch.requests, hasLength(sent));
      await snap.resume(const ExternalReturnValue(MontyInt(5)));
    });
  });

  group('an automatic answer refusal is sent as the call error', () {
    test(
      'an unpaired string is catchable and an uncaught one ends the feed',
      () async {
        final (s, ch) = await _session([
          answer([_call('f', 1)]),
          _automaticRefusal('UnicodeEncodeError', _surrogateMessage, [
            _int(1),
          ]),
          answer([_call('f', 2)]),
          _automaticRefusal('UnicodeEncodeError', _surrogateMessage, [
            raised('UnicodeEncodeError', _surrogateMessage),
          ]),
          answer([_int(2)]),
        ]);
        final host = {
          'f': MontyHostFunction(
            'f',
            (_, _) => const MontyString('\uD800'),
          ),
        };
        expect(
          await s.feedRun(
            'try:\n  f()\nexcept UnicodeEncodeError:\n  r = 1\nr',
            externalLookup: host,
          ),
          const MontyInt(1),
        );
        await expectLater(
          s.feedRun('f()', externalLookup: host),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.toString(),
              'diagnostic',
              _surrogateDiagnostic,
            ),
          ),
        );
        expect(await s.feedRun('2'), const MontyInt(2));
        expect(ch.requests, hasLength(6));
      },
    );

    test('a circular value is catchable as ValueError', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        _automaticRefusal('ValueError', 'Circular reference detected', [
          _int(1),
        ]),
      ]);
      expect(
        await s.feedRun(
          'try:\n  f()\nexcept ValueError:\n  r = 1\nr',
          externalLookup: {
            'f': MontyHostFunction('f', (_, _) => _cyclic()),
          },
        ),
        const MontyInt(1),
      );
    });

    for (final (value, text) in [
      (
        const MontyBytes([256]),
        'Invalid argument (value): byte 256 at index 0 is outside 0..255: '
            "Instance of 'MontyBytes'",
      ),
      (
        const MontyDate(year: 0, month: 1, day: 1),
        'Invalid argument (value): invalid value for Date.year: 0 is outside '
            "the range 1..=9999: Instance of 'MontyDate'",
      ),
      (
        const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0),
        'Invalid argument (value): invalid value for Time.hour: 24 is outside '
            "the range 0..=23: Instance of 'MontyTime'",
      ),
    ]) {
      test('a $value is raised as its host throw', () async {
        final (s, _) = await _session([
          answer([_call('f', 1)]),
          _automaticRefusal('Exception', text, [_string(text)]),
        ]);
        expect(
          await s.feedRun(
            'try:\n  f()\nexcept Exception as e:\n  r = str(e)\nr',
            externalLookup: {
              'f': MontyHostFunction('f', (_, _) => value),
            },
          ),
          MontyString(text),
        );
      });
    }
  });

  group('a cyclic attribute container', () {
    final loop = _cyclic();
    final type = montyClassTypeProxy(
      name: 'P',
      id: _classId,
      hostDefined: true,
      isDataclass: true,
      attrs: {'loop': loop},
    );
    final instance = montyClassProxy(
      classType: montyClassTypeProxy(
        name: 'P',
        id: _classId,
        hostDefined: true,
        isDataclass: true,
        attrs: const {},
      ),
      instanceId: '00000000-0000-4000-8000-000000000001',
      attrs: {'loop': loop},
    );

    final circular = throwsA(
      isA<MontyRuntimeError>()
          .having(
            (e) => e.toString(),
            'message',
            'ValueError: Circular reference detected',
          )
          .having((e) => e.exception.excType, 'excType', 'ValueError'),
    );

    test('a cyclic proxy input leaves its session usable', () async {
      final (s, ch) = await _session([
        answer([_int(1)]),
      ]);
      await expectLater(s.feedRun('x', inputs: {'x': instance}), circular);
      await expectLater(s.feedRun('x', inputs: {'x': type}), circular);
      await expectLater(
        s.feedRun(
          'x',
          inputs: {
            'x': MontyList([instance]),
          },
        ),
        circular,
      );
      expect(ch.requests, hasLength(1));
      expect(await s.feedRun('1'), const MontyInt(1));
    });

    test(
      'a cyclic proxy manual answer leaves its snapshot retryable',
      () async {
        final (s, ch) = await _session([
          answer([_call('f', 1)]),
          answer([_int(1)]),
        ]);
        final snap = await s.feedStart('f()') as FunctionSnapshot;
        final sent = ch.requests.length;
        expect(() => snap.resume(ExternalReturnValue(instance)), circular);
        expect(() => snap.resume(ExternalReturnValue(type)), circular);
        expect(ch.requests, hasLength(sent));
        expect(snap.isSpent, isFalse);
        await snap.resume(const ExternalReturnValue(MontyInt(1)));
      },
    );

    test(
      'the class itself in its own attribute is fine',
      () {
        final attrs = <String, MontyValue>{};
        final self = montyClassTypeProxy(
          name: 'P',
          id: _classId,
          hostDefined: true,
          isDataclass: true,
          attrs: attrs,
        );
        attrs['me'] = self;
        expect(() => ArenaWriter().add(self), returnsNormally);
      },
    );

    test(
      'a cyclic class type refuses inputs and manual answers locally',
      () async {
        final (s, ch) = await _session([
          answer([_call('f', 1)]),
          answer([_int(1)]),
          answer([_int(2)]),
        ]);
        final classCycleError = throwsA(
          isA<MontyRuntimeError>()
              .having(
                (e) => e.exception.excType,
                'exception type',
                'ValueError',
              )
              .having(
                (e) => e.exception.message,
                'exception message',
                'Circular reference detected',
              ),
        );

        await expectLater(
          s.feedRun('x', inputs: {'x': _cyclicClassType()}),
          classCycleError,
        );
        final snapshot = await s.feedStart('f()') as FunctionSnapshot;
        expect(
          () => snapshot.resume(ExternalReturnValue(_cyclicClassType())),
          classCycleError,
        );
        expect(snapshot.isSpent, isFalse);
        await snapshot.resume(const ExternalReturnValue(MontyInt(1)));
        expect(await s.feedRun('2'), const MontyInt(2));
        expect(ch.requests, hasLength(4));
      },
    );

    test(
      'a cyclic class type in an automatic lookup ends the session',
      () async {
        final (s, ch) = await _session([
          answer([_lookup('type')]),
        ]);

        await expectLater(
          s.feedRun('type', externalLookup: {'type': _cyclicClassType()}),
          throwsA(
            isA<MontyRuntimeError>()
                .having(
                  (e) => e.exception.excType,
                  'exception type',
                  'ValueError',
                )
                .having(
                  (e) => e.exception.message,
                  'exception message',
                  'Circular reference detected',
                ),
          ),
        );
        expect(ch.requests, hasLength(2));
        await expectLater(s.feedRun('1'), throwsStateError);
      },
    );
  });
}
