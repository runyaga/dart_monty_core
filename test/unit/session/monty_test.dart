// Unit tests for Monty class — scriptName constructor parameter (M4b).
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

const _noneResult = MontyResult(value: MontyNone(), usage: _zeroUsage);

/// Enqueues the three progress items consumed by a simple MontySession run.
void _enqueueSimpleRun(MockMontyPlatform mock) {
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
    ..enqueueProgress(const MontyComplete(result: _noneResult));
}

void main() {
  group('Monty scriptName constructor parameter', () {
    test('constructor scriptName is propagated to run()', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final monty = Monty.withPlatform(mock, scriptName: 'analytics.py');
      await monty.run('pass');

      expect(mock.history.lastStartScriptName, 'analytics.py');
    });

    test('per-run scriptName overrides constructor default', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final monty = Monty.withPlatform(mock, scriptName: 'default.py');
      await monty.run('pass', scriptName: 'debug.py');

      expect(mock.history.lastStartScriptName, 'debug.py');
    });

    test('default scriptName is main.py when not specified', () async {
      final mock = MockMontyPlatform();
      _enqueueSimpleRun(mock);

      final monty = Monty.withPlatform(mock);
      await monty.run('pass');

      expect(mock.history.lastStartScriptName, 'main.py');
    });
  });
}
