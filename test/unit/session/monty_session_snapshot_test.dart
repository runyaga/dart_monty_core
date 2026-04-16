// Unit tests for MontySession.snapshot() and MontySession.restore().
//
// Uses MockMontyPlatform — no native dylib required.
@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/mock_monty_platform.dart';
import 'package:test/test.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

const _nullResult = MontyResult(value: MontyNone(), usage: _zeroUsage);

/// Enqueues the three progress items consumed by a simple MontySession run
/// with the given [persistedState] dict returned by __persist_state__.
void _enqueueSimpleRun(
  MockMontyPlatform mock, {
  MontyResult result = _nullResult,
  Map<String, MontyValue> persistedState = const {},
}) {
  mock
    ..enqueueProgress(
      const MontyPending(
        functionName: '__restore_state__',
        arguments: [],
      ),
    )
    ..enqueueProgress(
      MontyPending(
        functionName: '__persist_state__',
        arguments: [MontyDict(persistedState)],
      ),
    )
    ..enqueueProgress(MontyComplete(result: result));
}

MontySession _makeSession() => MontySession(platform: MockMontyPlatform());

void main() {
  group('MontySession.snapshot / restore', () {
    test('snapshot of empty session produces valid envelope', () {
      final session = _makeSession();
      final bytes = session.snapshot();
      expect(bytes, isNotEmpty);

      final envelope = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(envelope['v'], equals(1));
      expect(envelope['dartState'], equals({}));
    });

    test(
      'round-trip: variable defined in run survives snapshot/restore',
      () async {
        final mock = MockMontyPlatform();
        final session = MontySession(platform: mock);

        _enqueueSimpleRun(
          mock,
          persistedState: {'x': const MontyInt(42)},
        );
        await session.run('x = 42');

        final bytes = session.snapshot();

        // Restore into a new session backed by a fresh mock.
        final session2 = MontySession(platform: MockMontyPlatform())
          ..restore(bytes);

        expect(session2.state, equals({'x': 42}));
      },
    );

    test('round-trip: multiple variables all restored', () async {
      final mock = MockMontyPlatform();
      final session = MontySession(platform: mock);

      _enqueueSimpleRun(
        mock,
        persistedState: {
          'x': const MontyInt(1),
          'y': const MontyInt(2),
          'name': const MontyString('Alice'),
        },
      );
      await session.run('x = 1\ny = 2\nname = "Alice"');

      final bytes = session.snapshot();

      final session2 = MontySession(platform: MockMontyPlatform())
        ..restore(bytes);

      expect(session2.state, equals({'x': 1, 'y': 2, 'name': 'Alice'}));
    });

    test('restore replaces existing state', () async {
      final mock = MockMontyPlatform();
      final session = MontySession(platform: mock);

      _enqueueSimpleRun(
        mock,
        persistedState: {'x': const MontyInt(1)},
      );
      await session.run('x = 1');
      final snapshot1 = session.snapshot();

      _enqueueSimpleRun(
        mock,
        persistedState: {'x': const MontyInt(99)},
      );
      await session.run('x = 99');
      expect(session.state['x'], equals(99));

      // Restore back to snapshot1
      session.restore(snapshot1);
      expect(session.state['x'], equals(1));
    });

    test('after restore the next run injects the restored state', () async {
      final mock = MockMontyPlatform();
      final session = MontySession(platform: mock);

      _enqueueSimpleRun(
        mock,
        persistedState: {'x': const MontyInt(7)},
      );
      await session.run('x = 7');
      final bytes = session.snapshot();

      // Create a new session, restore, then run.
      final mock2 = MockMontyPlatform();
      final session2 = MontySession(platform: mock2)..restore(bytes);

      _enqueueSimpleRun(
        mock2,
        persistedState: {'x': const MontyInt(7)},
        result: const MontyResult(value: MontyInt(7), usage: _zeroUsage),
      );
      await session2.run('x');

      // The start code passed to the mock should include the restore section.
      final startCode = mock2.history.startCodes.first;
      expect(startCode, contains('__restore_state__'));
      expect(startCode, contains('x = __d["x"]'));
    });

    test('invalid bytes throw ArgumentError', () {
      final session = _makeSession();
      expect(
        () => session.restore(Uint8List.fromList([1, 2, 3])),
        throwsArgumentError,
      );
    });

    test('wrong version throws ArgumentError', () {
      final session = _makeSession();
      final badEnvelope = utf8.encode(
        jsonEncode(<String, Object?>{
          'v': 99,
          'dartState': <String, Object?>{},
        }),
      );
      expect(
        () => session.restore(Uint8List.fromList(badEnvelope)),
        throwsArgumentError,
      );
    });

    test('snapshot on disposed session throws StateError', () {
      final session = _makeSession()..dispose();
      expect(session.snapshot, throwsStateError);
    });

    test('restore on disposed session throws StateError', () {
      final session = _makeSession();
      final bytes = session.snapshot();
      session.dispose();
      expect(() => session.restore(bytes), throwsStateError);
    });
  });

  group('Monty.snapshot / restore', () {
    test('round-trip preserves state', () async {
      final mock = MockMontyPlatform();
      final monty = Monty.withPlatform(mock);

      _enqueueSimpleRun(
        mock,
        persistedState: {'answer': const MontyInt(42)},
      );
      await monty.run('answer = 42');

      final bytes = monty.snapshot();

      final monty2 = Monty.withPlatform(MockMontyPlatform())..restore(bytes);

      expect(monty2.state, equals(<String, Object?>{'answer': 42}));
    });
  });
}
