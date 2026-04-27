// Unit tests for MontyRepl/MontySession/Monty scriptName getter.
//
// scriptName is the filename surfaced in Python tracebacks. Both the REPL
// (low-level) and the Session (high-level) accept it at construction; Monty
// defaults to 'main.py' when unset, mirroring the reference Python class.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('scriptName getter', () {
    test('Monty defaults to main.py when no scriptName given', () {
      final monty = Monty();
      addTearDown(monty.dispose);
      expect(monty.scriptName, 'main.py');
    });

    test('Monty round-trips a custom scriptName', () {
      final monty = Monty(scriptName: 'analysis.py');
      addTearDown(monty.dispose);
      expect(monty.scriptName, 'analysis.py');
    });

    test('MontySession returns null when no scriptName given', () {
      final session = MontySession();
      addTearDown(session.dispose);
      expect(session.scriptName, isNull);
    });

    test('MontySession round-trips a custom scriptName', () {
      final session = MontySession(scriptName: 'job.py');
      addTearDown(session.dispose);
      expect(session.scriptName, 'job.py');
    });

    test('MontyRepl returns null when no scriptName given', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);
      expect(repl.scriptName, isNull);
    });

    test('MontyRepl round-trips a custom scriptName', () async {
      final repl = MontyRepl(scriptName: 'task.py');
      addTearDown(repl.dispose);
      expect(repl.scriptName, 'task.py');
    });
  });
}
