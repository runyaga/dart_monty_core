// Unit tests for the scriptName getter on Monty and MontyRepl.
//
// scriptName is the filename surfaced in Python tracebacks. Monty
// defaults to 'main.py' when unset, mirroring the reference Python
// class; MontyRepl returns `null` so the engine's own fallback applies.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('scriptName getter', () {
    test('Monty defaults to main.py when no scriptName given', () {
      final monty = Monty('pass');
      expect(monty.scriptName, 'main.py');
    });

    test('Monty round-trips a custom scriptName', () {
      final monty = Monty('pass', scriptName: 'analysis.py');
      expect(monty.scriptName, 'analysis.py');
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
