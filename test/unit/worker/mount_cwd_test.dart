@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';

final TypeMatcher<MontyRuntimeError> _runtimeError = isA<MontyRuntimeError>();
final pb.ChildEvent _ok = ok();
final pb.ChildEvent _none = completeNone();

// session-mount.md: ready/pending -> cwd validation -> mount table -> Feed.
// Wire assertions distinguish an unset cwd from the worker merely staying at /.
void main() {
  late Directory dir;
  late MountDir first;
  late MountDir second;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('f2-cwd-');
    first = MountDir(hostPath: dir.path, virtualPath: '/first');
    second = MountDir(hostPath: dir.path, virtualPath: '/second');
  });
  tearDown(() {
    first.close();
    second.close();
    dir.deleteSync();
  });

  Future<(MontySession, ScriptedChannel)> open(List<Reply> replies) async {
    final channel = ScriptedChannel([
      expecting(pb.ParentRequest_Kind.configure, [_ok]),
      ...replies,
      expecting(pb.ParentRequest_Kind.reset, [_ok]),
    ]);
    final pool = await startMonty(
      const PoolOptions(minProcesses: 0, maxProcesses: 1),
      open: () => PendingSpawn((_) async => channel),
    );
    addTearDown(pool.close);
    final session = await pool.checkout();
    addTearDown(session.close);

    return (session, channel);
  }

  for (final start in [false, true]) {
    test(
      'invalid cwd precedes overlap and sends no Feed start=$start',
      () async {
        final (session, channel) = await open([
          expecting(pb.ParentRequest_Kind.feed, [_none]),
        ]);
        Future<Object> feed(String? cwd, List<MountDir> mounts) => start
            ? session.feedStart('code', cwd: cwd, mount: mounts)
            : session.feedRun('code', cwd: cwd, mount: mounts);
        await expectLater(
          feed('relative', [first, first]),
          throwsA(
            _runtimeError.having(
              (e) => e.exception.message,
              'message',
              'cwd must be an absolute POSIX path: "relative"',
            ),
          ),
        );
        expect(channel.requests.map((r) => r.whichKind()), [
          pb.ParentRequest_Kind.configure,
        ]);
        await expectLater(
          feed('/valid', [first, first]),
          throwsA(
            _runtimeError.having(
              (e) => e.exception.message,
              'message',
              contains('overlaps'),
            ),
          ),
        );
        expect(channel.requests, hasLength(1));
        await feed(null, [second]);
        expect(channel.requests.lastOrNull?.feed.cwd, '/second');
      },
    );

    test(
      'Fake invalid cwd precedes overlap without consuming script start=$start',
      () async {
        final fake = FakeMontySession()..willReturn(const MontyInt(42));
        addTearDown(fake.close);
        Future<Object> feed(String? cwd, List<MountDir> mounts) => start
            ? fake.feedStart('code', cwd: cwd, mount: mounts)
            : fake.feedRun('code', cwd: cwd, mount: mounts);
        await expectLater(
          feed('relative', [first, first]),
          throwsA(
            _runtimeError.having(
              (e) => e.exception.message,
              'message',
              startsWith('cwd must'),
            ),
          ),
        );
        expect(fake.feeds, isEmpty);
        await expectLater(
          feed('/valid', [first, first]),
          throwsA(
            _runtimeError.having(
              (e) => e.exception.message,
              'message',
              contains('overlaps'),
            ),
          ),
        );
        expect(fake.feeds, isEmpty);
        final result = await feed(null, [second]);
        expect(
          result,
          start
              ? isA<MontyComplete>().having(
                  (s) => s.output,
                  'output',
                  const MontyInt(42),
                )
              : const MontyInt(42),
        );
        expect(fake.feeds, ['code']);
      },
    );

    test(
      'pending snapshot wins over invalid cwd and overlap start=$start',
      () async {
        final fake = FakeMontySession()
          ..willCallOs('os.getenv', args: [const MontyString('WAIT')])
          ..willReturn(const MontyInt(42));
        addTearDown(fake.close);
        final snapshot = await fake.feedStart('pending') as FunctionSnapshot;
        await expectLater(
          start
              ? fake.feedStart(
                  'refused',
                  cwd: 'relative',
                  mount: [first, first],
                )
              : fake.feedRun('refused', cwd: 'relative', mount: [first, first]),
          throwsStateError,
        );
        expect(fake.feeds, ['pending']);
        expect(
          await snapshot.resume(const ExternalReturnValue(MontyNone())),
          isA<MontyComplete>().having(
            (s) => s.output,
            'output',
            const MontyInt(42),
          ),
        );
      },
    );
  }

  for (final mounted in [false, true]) {
    test('typing rejection retries default on wire mounted=$mounted', () async {
      final (session, channel) = await open([
        expecting(pb.ParentRequest_Kind.feed, [
          pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'bad type')),
        ]),
        expecting(pb.ParentRequest_Kind.feed, [_none]),
        expecting(pb.ParentRequest_Kind.feed, [_none]),
      ]);
      await expectLater(
        session.feedRun(
          'bad',
          cwd: '/explicit',
          mount: mounted ? [first] : null,
        ),
        throwsA(isA<MontyTypingError>()),
      );
      await session.feedRun('good', mount: mounted ? [second] : null);
      await session.feedRun('later', mount: mounted ? [first] : null);
      expect(
        channel.requests.where((r) => r.hasFeed()).map((r) => r.feed.cwd),
        ['/explicit', if (mounted) '/second' else '/', ''],
      );
    });
  }

  test('restored session sends empty cwd on first feed', () async {
    final (session, channel) = await open([
      expecting(pb.ParentRequest_Kind.load, [_ok]),
      expecting(pb.ParentRequest_Kind.feed, [_none]),
    ]);
    await session.loadSession(Uint8List.fromList([1]));
    await session.feedRun('code', mount: [second]);
    expect(channel.requests.lastOrNull?.feed.cwd, isEmpty);
  });
}
