// Unit tests for MontySession.run() with the `inputs` parameter.
//
// Uses MockMontyPlatform — no native dylib required.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/mock_monty_platform.dart';
import 'package:test/test.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

const _nullResult = MontyResult(value: MontyNone(), usage: _zeroUsage);

/// Enqueues the three progress items consumed by a simple MontySession run:
/// 1. __restore_state__ pending
/// 2. __persist_state__ pending (returns empty dict)
/// 3. MontyComplete with [result]
void _enqueueSimpleRun(
  MockMontyPlatform mock, {
  MontyResult result = _nullResult,
}) {
  mock
    ..enqueueProgress(
      const MontyPending(
        functionName: '__restore_state__',
        arguments: [],
      ),
    )
    ..enqueueProgress(
      const MontyPending(
        functionName: '__persist_state__',
        arguments: [MontyDict({})],
      ),
    )
    ..enqueueProgress(MontyComplete(result: result));
}

void main() {
  // -------------------------------------------------------------------------
  group('MontySession inputs injection', () {
    test('int input appears in start code', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'x': 42});

      expect(mock.history.lastStartCode, contains('x = 42'));
    });

    test('bool input uses Python capitalisation', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'flag': true});

      expect(mock.history.lastStartCode, contains('flag = True'));
    });

    test('string input is quoted', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'name': 'Alice'});

      expect(mock.history.lastStartCode, contains("name = 'Alice'"));
    });

    test('list input', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run(
        'pass',
        inputs: {
          'lst': [1, 2, 3],
        },
      );

      expect(mock.history.lastStartCode, contains('lst = [1, 2, 3]'));
    });

    test('dict input', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run(
        'pass',
        inputs: {
          'd': {'a': 1},
        },
      );

      expect(mock.history.lastStartCode, contains("d = {'a': 1}"));
    });

    test('null input', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'x': null});

      expect(mock.history.lastStartCode, contains('x = None'));
    });

    test('nan input', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'f': double.nan});

      expect(mock.history.lastStartCode, contains("f = float('nan')"));
    });

    test('infinity input', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'f': double.infinity});

      expect(mock.history.lastStartCode, contains("f = float('inf')"));
    });

    test('empty inputs map — same code as no inputs', () async {
      final mockA = MockMontyPlatform();
      _enqueueSimpleRun(mockA);
      final mockB = MockMontyPlatform();
      _enqueueSimpleRun(mockB);

      await MontySession(platform: mockA).run('pass');
      await MontySession(platform: mockB).run('pass', inputs: {});

      expect(
        mockB.history.lastStartCode,
        equals(mockA.history.lastStartCode),
        reason: 'empty inputs must not change the generated code',
      );
    });

    test('null inputs — same code as no inputs', () async {
      final mockA = MockMontyPlatform();
      _enqueueSimpleRun(mockA);
      final mockB = MockMontyPlatform();
      _enqueueSimpleRun(mockB);

      await MontySession(platform: mockA).run('pass');
      // Explicit null to verify null produces the same code as the default.
      // ignore: avoid_redundant_argument_values
      await MontySession(platform: mockB).run('pass', inputs: null);

      expect(
        mockB.history.lastStartCode,
        equals(mockA.history.lastStartCode),
        reason: 'null inputs must not change the generated code',
      );
    });

    test('input code follows restore section in start code', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'x': 99});

      final code = mock.history.lastStartCode!;
      final restoreIdx = code.indexOf('__restore_state__');
      final inputIdx = code.indexOf('x = 99');
      expect(
        restoreIdx,
        lessThan(inputIdx),
        reason: 'input must come after __restore_state__',
      );
    });

    test('inputs are not persisted for new variables', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock); // persist returns empty dict

      final session = MontySession(platform: mock);
      await session.run('pass', inputs: {'newVar': 99});

      expect(
        session.state.containsKey('newVar'),
        isFalse,
        reason: 'input-only variables must not appear in persisted state',
      );
    });

    test('unsupported input type throws ArgumentError', () async {
      final session = MontySession(platform: MockMontyPlatform());

      await expectLater(
        () => session.run('pass', inputs: {'bad': Object()}),
        throwsArgumentError,
      );
    });
  });
}
