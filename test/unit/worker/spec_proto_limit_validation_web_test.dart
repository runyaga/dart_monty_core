// dart2js can represent integers and durations beyond Rust's u64 range.
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:math' as math;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';

const _durationError =
    'cannot convert float seconds to Duration: '
    'value is either too big or NaN';

List<ResourceLimits> _integerLimits(int value) => [
  ResourceLimits(maxMemory: value),
  ResourceLimits(gcInterval: value),
  ResourceLimits(maxRecursionDepth: value),
  ResourceLimits(maxSuspensions: value),
];

List<ResourceLimits> _durationLimits(Duration value) => [
  ResourceLimits(maxFeedDuration: value),
  ResourceLimits(maxTurnDuration: value),
  ResourceLimits(maxTotalSleep: value),
];

Future<void> _refused(SessionConfig config, String message) async {
  final channel = ScriptedChannel([]);
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  addTearDown(pool.close);
  await expectLater(
    pool.checkoutWith(config),
    throwsA(
      isA<ArgumentError>().having((e) => e.message, 'message', message),
    ),
  );
  expect(channel.requests, isEmpty);
}

void main() {
  // Unlike dart2js, the VM and dart2wasm clamp the conversion below 2^64.
  const skip = identical(1, 1.0) ? false : 'Requires dart2js integer range.';
  test(
    'all oversized integer limits fail before Configure',
    () async {
      for (final limits in _integerLimits(math.pow(2, 64).toInt())) {
        await _refused(SessionConfig(limits: limits), 'int too big to convert');
      }
    },
    skip: skip,
  );

  test(
    'all oversized durations fail before Configure',
    () async {
      final huge = Duration(seconds: math.pow(2, 64).toInt());
      for (final limits in _durationLimits(huge)) {
        await _refused(SessionConfig(limits: limits), _durationError);
      }
    },
    skip: skip,
  );

  test(
    'oversized sleepSystemMax preserves the error prefix',
    () async {
      await _refused(
        SessionConfig(
          osPolicy: OsPolicy(
            sleepSystemMax: Duration(seconds: math.pow(2, 64).toInt()),
          ),
        ),
        'invalid sleep_system_max: $_durationError',
      );
    },
    skip: skip,
  );

  test(
    'negative and oversized limits use ArgumentError',
    () async {
      for (final limits in _integerLimits(-1)) {
        await _refused(
          SessionConfig(limits: limits),
          "can't convert negative int to unsigned",
        );
      }
      for (final limits in _durationLimits(const Duration(microseconds: -1))) {
        await _refused(
          SessionConfig(limits: limits),
          'cannot convert float seconds to Duration: value is negative',
        );
      }
      for (final limits in _integerLimits(math.pow(2, 64).toInt())) {
        await _refused(SessionConfig(limits: limits), 'int too big to convert');
      }
      for (final limits in _durationLimits(
        Duration(seconds: math.pow(2, 64).toInt()),
      )) {
        await _refused(SessionConfig(limits: limits), _durationError);
      }
      await _refused(
        SessionConfig(
          osPolicy: OsPolicy(
            sleepSystemMax: Duration(seconds: math.pow(2, 64).toInt()),
          ),
        ),
        'invalid sleep_system_max: $_durationError',
      );
    },
    skip: skip,
  );
}
