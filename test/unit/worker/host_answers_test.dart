// OS calls as upstream presents them to a host, and the host's system
// sleeps and coroutines (host_answers.dart).
// Pure Dart: vm, dart2js and dart2wasm.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart'
    show PythonRefusal;
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException, unknownExcType;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

typedef _Parts = (String, List<MontyValue>, Map<String, MontyValue>);

/// Every OS call kind, with what upstream presents for it.
Map<pb.OsCall, _Parts> _cases() {
  final none = pb.Arena(nodeCount: 1, nodes: [pb.MontyNode(str: 'd')]);

  return {
    pb.OsCall(exists: '/a'): (
      'Path.exists',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(isFile: '/a'): (
      'Path.is_file',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(isDir: '/a'): (
      'Path.is_dir',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(isSymlink: '/a'): (
      'Path.is_symlink',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(readText: '/a'): (
      'Path.read_text',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(readBytes: '/a'): (
      'Path.read_bytes',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(stat: '/a'): ('Path.stat', [const MontyPath('/a')], {}),
    pb.OsCall(iterdir: '/a'): (
      'Path.iterdir',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(resolve: '/a'): (
      'Path.resolve',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(absolute: '/a'): (
      'Path.absolute',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(unlink: '/a'): (
      'Path.unlink',
      [const MontyPath('/a')],
      {},
    ),
    pb.OsCall(rmdir: '/a'): ('Path.rmdir', [const MontyPath('/a')], {}),
    pb.OsCall(
      writeText: pb.OsCall_TextWrite(path: '/a', data: 'x'),
    ): (
      'Path.write_text',
      [const MontyPath('/a'), const MontyString('x')],
      {},
    ),
    pb.OsCall(
      appendText: pb.OsCall_TextWrite(path: '/a', data: 'x'),
    ): (
      'Path.append_text',
      [const MontyPath('/a'), const MontyString('x')],
      {},
    ),
    pb.OsCall(
      writeBytes: pb.OsCall_BytesWrite(path: '/a', data: [1]),
    ): (
      'Path.write_bytes',
      [
        const MontyPath('/a'),
        const MontyBytes([1]),
      ],
      {},
    ),
    pb.OsCall(
      appendBytes: pb.OsCall_BytesWrite(path: '/a', data: [1]),
    ): (
      'Path.append_bytes',
      [
        const MontyPath('/a'),
        const MontyBytes([1]),
      ],
      {},
    ),
    pb.OsCall(
      open: pb.OsCall_Open(path: '/a', mode: 'rb'),
    ): (
      'open',
      [const MontyPath('/a'), const MontyString('rb')],
      {},
    ),
    pb.OsCall(mkdir: pb.OsCall_Mkdir(path: '/a', existOk: true)): (
      'Path.mkdir',
      [const MontyPath('/a')],
      {
        'parents': const MontyBool(false),
        'exist_ok': const MontyBool(true),
      },
    ),
    pb.OsCall(
      rename: pb.OsCall_Rename(src: '/a', dst: '/b'),
    ): (
      'Path.rename',
      [const MontyPath('/a'), const MontyPath('/b')],
      {},
    ),
    pb.OsCall(
      getenv: pb.OsCall_Getenv(key: 'K'),
      values: none,
    ): (
      'os.getenv',
      [const MontyString('K'), const MontyString('d')],
      {},
    ),
    pb.OsCall(getEnviron: pb.Unit()): ('os.environ', [], {}),
    pb.OsCall(dateToday: pb.Unit()): ('date.today', [], {}),
    pb.OsCall(dateTimeNow: pb.OsCall_DateTimeNow()): (
      'datetime.now',
      [const MontyNone()],
      {},
    ),
    pb.OsCall(
      dateTimeNow: pb.OsCall_DateTimeNow(
        tz: pb.TimeZone(offsetSeconds: 3600, name: 'X'),
      ),
    ): (
      'datetime.now',
      [const MontyTimeZone(offsetSeconds: 3600, name: 'X')],
      {},
    ),
    pb.OsCall(urandom: pb.OsCall_Urandom(size: Int64(8))): (
      'os.urandom',
      [const MontyInt(8)],
      {},
    ),
    pb.OsCall(time: pb.OsCall_TimeCall(caller: 'time.monotonic')): (
      'time.time',
      [const MontyString('time.monotonic')],
      {},
    ),
    pb.OsCall(sleep: pb.OsCall_Sleep(seconds: 0.5)): (
      'time.sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(systemSleep: pb.OsCall_Sleep(seconds: 0.5)): (
      'system.sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(asyncSleep: pb.OsCall_AsyncSleep(delay: 0.5)): (
      'asyncio.sleep',
      [const MontyFloat(0.5)],
      {},
    ),
    pb.OsCall(asyncSystemSleep: pb.OsCall_AsyncSleep(delay: 0.5)): (
      'system.async_sleep',
      [const MontyFloat(0.5)],
      {},
    ),
  };
}

void main() {
  group('osCallParts', () {
    test('every call, as OsFunctionCall::to_args gives it', () {
      final cases = _cases();
      expect(
        {for (final call in cases.keys) call.whichCall()},
        {...pb.OsCall_Call.values}..remove(pb.OsCall_Call.notSet),
      );
      for (final MapEntry(key: call, value: want) in cases.entries) {
        final (name, args, kwargs) = osCallParts(call);
        final reason = call.whichCall().name;
        expect(name, want.$1, reason: reason);
        expect(args, want.$2, reason: reason);
        expect(kwargs, want.$3, reason: reason);
      }
    });

    test('an OS call with no call is a FormatException', () {
      expect(() => osCallParts(pb.OsCall()), throwsFormatException);
    });

    test('only asyncio.sleep, in either mode, accepts a future', () {
      expect(acceptsFuture('asyncio.sleep'), isTrue);
      expect(acceptsFuture('system.async_sleep'), isTrue);
      expect(acceptsFuture('time.sleep'), isFalse);
      expect(acceptsFuture('Path.read_text'), isFalse);
    });
  });

  group('system sleeps', () {
    pb.OsCall asyncSleep(int id, double delay) => pb.OsCall(
      callId: id,
      asyncSystemSleep: pb.OsCall_AsyncSleep(delay: delay),
    );

    test('a gathered sleep settles only once its delay has passed', () async {
      final host = HostAnswers(systemSleepMax: const Duration(seconds: 10));
      final clock = Stopwatch()..start();
      final answer = await host.osCall(asyncSleep(1, 0.2), parentSleeps: true);
      expect(answer.resumeCall.result.future, 1);
      final settled = await host.settle();
      expect(onlyItem(settled.resumeFutures.results).callId, 1);
      expect(
        clock.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 150)),
      );
    });

    test('gathered sleeps run at once: all are armed before any ends, and '
        'each settles when its timer fires', () async {
      // The timers are held, not run: no wall clock decides the order.
      final held = <Duration, _HeldTimer>{};
      await runZoned(
        () async {
          final host = HostAnswers(
            systemSleepMax: const Duration(seconds: 10),
          );
          for (final (id, delay) in [(1, 0.3), (2, 0.1), (3, 0.2)]) {
            await host.osCall(asyncSleep(id, delay), parentSleeps: true);
          }
          expect(held.keys.toSet(), {
            const Duration(milliseconds: 300),
            const Duration(milliseconds: 100),
            const Duration(milliseconds: 200),
          });
          final order = <int>[];
          for (final ms in [100, 200, 300]) {
            held[Duration(milliseconds: ms)]!.fire();
            final request = await host.settle();
            order.addAll(request.resumeFutures.results.map((r) => r.callId));
          }
          expect(order, [2, 3, 1]);
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              held[duration] = _HeldTimer(callback),
        ),
      );
    });

    test('a decline from a future fails asyncio.sleep with TypeError, as '
        "upstream's coroutine returning NOT_HANDLED does", () async {
      for (final eager in [true, false]) {
        final host = HostAnswers(
          os: (name, args, kwargs) async =>
              throw const OsCallNotHandledException(),
        );
        final call = pb.OsCall(
          callId: 1,
          allowEagerAwait: eager,
          asyncSleep: pb.OsCall_AsyncSleep(delay: 0),
        );
        var answer = await host.osCall(call, parentSleeps: true);
        if (!eager) answer = await host.settle();
        final result = onlyItem(answer.resumeFutures.results).result;
        expect(result.error.excType, 'TypeError', reason: 'eager: $eager');
        expect(result.error.message, AsyncDecline.message);
      }
    });

    test('dispose ends every waiting sleep at once', () async {
      final host = HostAnswers(systemSleepMax: const Duration(seconds: 10));
      await host.osCall(asyncSleep(1, 5), parentSleeps: true);
      final inline = host.osCall(
        pb.OsCall(callId: 2, systemSleep: pb.OsCall_Sleep(seconds: 5)),
        parentSleeps: true,
      );
      final clock = Stopwatch()..start();
      host.dispose();
      await inline;
      await host.settle();
      expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    });
  });

  group('host code: the Python exception a throw raises', () {
    test('any throw but ExternalException raises Exception with its text', () {
      for (final (error, text) in [
        (StateError('x'), 'Bad state: x'),
        (const FormatException('bad'), 'FormatException: bad'),
        (ArgumentError('a'), 'Invalid argument(s): a'),
        ('plain', 'plain'),
        (
          const OsCallException('no', pythonExceptionType: 'KeyError'),
          'OsCallException(no)',
        ),
      ]) {
        final raised = raisedFrom(error);
        expect(raised.excType, 'Exception', reason: '$error');
        expect(raised.message, text, reason: '$error');
        expect(raised.hasData(), isFalse, reason: '$error');
      }
    });

    test("the fallback's text is read as upstream reads an exception's "
        'argument: an unpaired surrogate is replaced', () {
      // PyO3's lossy conversion: the surrogate's three bytes, each replaced.
      expect(
        raisedFrom(StateError('a\uD800b')).message,
        'Bad state: a\uFFFD\uFFFD\uFFFDb',
      );
    });

    test('a thrown ExternalException always carries a message, as a '
        "raised Python exception's argument is", () {
      final raised = raisedFrom(const ExternalException('ValueError'));
      expect(raised.excType, 'ValueError');
      expect(raised.hasMessage(), isTrue);
      expect(raised.message, '');
      expect(raisedFrom(const ExternalException('KeyError', 'k')).message, 'k');
    });

    test('an unknown excType is an ArgumentError, which the sandbox '
        'receives as Exception', () {
      final raised = raisedFrom(const ExternalException('NoSuchError', 'm'));
      expect(raised.excType, 'Exception');
      expect(
        raised.message,
        unknownExcType('NoSuchError').toString(),
      );
      expect(unknownExcType('NoSuchError'), isA<ArgumentError>());
      expect(
        unknownExcType('NoSuchError').message,
        "Unknown exception type: 'NoSuchError'",
      );
    });

    test("a refusal Python makes too keeps Python's error", () {
      final raised = raisedFrom(
        PythonRefusal(const MontyNone(), 'cycle', 'ValueError', 'Circular'),
      );
      expect(raised.excType, 'ValueError');
      expect(raised.message, 'Circular');
    });
  });

  group('OS handler', () {
    final now = pb.OsCall(callId: 3, dateTimeNow: pb.OsCall_DateTimeNow());

    test('a returned None is the answer, not a decline', () async {
      final host = HostAnswers(os: (name, args, kwargs) => const MontyNone());
      final result = (await host.osCall(
        now,
        parentSleeps: true,
      )).resumeCall.result;
      expect(result.hasReturnValue(), isTrue);
      expect(result.hasNotHandled(), isFalse);
    });

    test('OsCallNotHandledException thrown synchronously declines', () async {
      final host = HostAnswers(
        os: (name, args, kwargs) => throw const OsCallNotHandledException(),
      );
      final answer = await host.osCall(now, parentSleeps: true);
      expect(answer.resumeCall.result.hasNotHandled(), isTrue);
    });

    test('from a future it raises TypeError, as a NOT_HANDLED a coroutine '
        'returns does upstream', () async {
      final host = HostAnswers(
        os: (name, args, kwargs) =>
            Future.error(const OsCallNotHandledException()),
      );
      final result = (await host.osCall(
        now,
        parentSleeps: true,
      )).resumeCall.result;
      expect(result.hasNotHandled(), isFalse);
      expect(result.error.excType, 'TypeError');
      expect(result.error.message, AsyncDecline.message);
    });

    test("ExternalException's text names its type and message", () {
      expect(
        const ExternalException('ValueError').toString(),
        'ExternalException(ValueError)',
      );
      expect(
        const ExternalException('ValueError', 'm').toString(),
        'ExternalException(ValueError, m)',
      );
    });

    test(
      'ExternalException raises its type; any other throw Exception',
      () async {
        for (final (thrown, type, message) in <(Exception, String, String)>[
          (
            const ExternalException('FileNotFoundError', 'nope'),
            'FileNotFoundError',
            'nope',
          ),
          (const FormatException('x'), 'Exception', 'FormatException: x'),
        ]) {
          final host = HostAnswers(os: (name, args, kwargs) => throw thrown);
          final error = (await host.osCall(
            now,
            parentSleeps: true,
          )).resumeCall.result.error;
          expect(error.excType, type);
          expect(error.message, message);
        }
      },
    );
  });

  test('a lookup resolving to a host function writes its index, 0, '
      "explicitly, as upstream's oneof encoder does", () {
    final host = HostAnswers(externals: {'f': (a, k) => const MontyNone()});
    final lookup = host.lookup('f').resumeNameLookup;
    expect(lookup.hasValue(), isTrue);
    expect(lookup.value, 0);
    // Field 2 (varint) with value 0: tag 0x10, then 0x00.
    final bytes = lookup.writeToBuffer();
    expect(bytes.sublist(bytes.length - 2), [0x10, 0x00]);
  });

  test('normalizeVirtualPath follows normalize_virtual_path', () {
    const cases = {
      '': '',
      '/': '/',
      '/a/b': '/a/b',
      'a/b': '/a/b',
      '/a/./b/': '/a/b',
      '/a/../../b': '/b',
      '..': '/',
      '//a//b': '/a/b',
      '/a/..': '/',
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(normalizeVirtualPath(key), value, reason: key);
    }
  });
}

/// A timer that runs only when the test fires it.
final class _HeldTimer implements Timer {
  _HeldTimer(this._callback);

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
