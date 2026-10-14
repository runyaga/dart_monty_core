// `OsCallNotHandledException.toString` names the operation when it has one.
//
// A handler that declines an OS call throws this, and the text is what a host
// log shows. The mount-fs corpus adjudicator was the only thing that rendered
// it, via the failure report it builds for a declining handler; this pins the
// two shapes directly.
//
// Falsifier: swap the branches of the `fnName == null` test; both cases fail.
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

    test('with a function name renders it', () {
      expect(
        const OsCallNotHandledException('Path.read_text').toString(),
        'OsCallNotHandledException(Path.read_text)',
      );
    });
  });
}
