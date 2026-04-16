@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

Monty _make() => Monty();

void main() {
  group('snapshot_ffi', () {
    test('empty snapshot restores to empty state', () {
      final m = _make();
      addTearDown(m.dispose);
      final m2 = _make()..restore(m.snapshot());
      addTearDown(m2.dispose);
      expect(m2.state, isEmpty);
    });

    test('int variable survives round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('x = 42');
      final m2 = _make()..restore(m.snapshot());
      addTearDown(m2.dispose);
      expect((await m2.run('x')).value, const MontyInt(42));
    });

    test('all primitive types survive round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('i=1; f=1.5; s="hi"; b=True; n=None');
      final m2 = _make()..restore(m.snapshot());
      addTearDown(m2.dispose);
      expect(m2.state['i'], 1);
      expect(m2.state['s'], 'hi');
      expect(m2.state['b'], true);
      expect(m2.state['n'], isNull);
    });

    test('nested collection survives round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('d = {"a": [1, 2, {"b": 3}]}');
      final m2 = _make()..restore(m.snapshot());
      addTearDown(m2.dispose);
      expect(
        (await m2.run('d["a"][2]["b"]')).value,
        const MontyInt(3),
      );
    });

    test('accumulated state from multiple runs survives', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('x = 1');
      await m.run('y = 2');
      final m2 = _make()..restore(m.snapshot());
      addTearDown(m2.dispose);
      expect(m2.state['x'], 1);
      expect(m2.state['y'], 2);
    });

    test('compile + runPrecompiled round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      final binary = await Monty.compile('2 ** 8');
      expect(binary, isNotEmpty);
      final result = await m.runPrecompiled(binary);
      expect(result.value, const MontyInt(256));
    });

    test('compile syntax error throws MontySyntaxError', () async {
      await expectLater(
        Monty.compile('def ('),
        throwsA(isA<MontySyntaxError>()),
      );
    });
  });
}
