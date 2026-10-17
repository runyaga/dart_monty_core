// Typed-value round trips against the real native worker.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '../../unit/worker/_typed_value_round_trip_cases.dart';
import '_worker_harness.dart';

Future<void> _withSession(
  Future<void> Function(MontySession session) body,
) async {
  final session = await protoRealSession();
  await body(session);
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  typedValueRoundTripTests('vm', _withSession);
}
