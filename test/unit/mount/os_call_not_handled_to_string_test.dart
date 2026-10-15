// `OsCallNotHandledException.toString` renders empty parentheses: the
// exception carries nothing, as the worker knows the declined operation.
//
// A handler that declines an OS call throws this, and the text is what a host
// log shows. The mount-fs corpus adjudicator was the only thing that rendered
// it, via the failure report it builds for a declining handler; this pins the
// shape directly.
//
// Falsifier: change the returned text; the case fails.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('OsCallNotHandledException.toString', () {
    test('without a function name renders empty parentheses', () {
      expect(
        const OsCallNotHandledException().toString(),
        'OsCallNotHandledException()',
      );
    });
  });
}
