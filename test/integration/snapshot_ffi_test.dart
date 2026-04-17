@Tags(['integration', 'ffi'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

Monty _make() => Monty();

void main() {
  group('snapshot_ffi', () {
    test('empty snapshot produces non-empty bytes', () async {
      final m = _make();
      addTearDown(m.dispose);
      final bytes = await m.snapshot();
      expect(bytes, isNotEmpty);
    });

    test('empty snapshot restores to a usable session', () async {
      final m = _make();
      addTearDown(m.dispose);
      final snap = await m.snapshot();
      final m2 = _make()..restore(snap);
      addTearDown(m2.dispose);
      expect((await m2.run('42')).value, const MontyInt(42));
    });

    test('int variable survives round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('x = 42');
      final snap = await m.snapshot();
      final m2 = _make()..restore(snap);
      addTearDown(m2.dispose);
      expect((await m2.run('x')).value, const MontyInt(42));
    });

    test('all primitive types survive round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('i=1; s="hi"; b=True; n=None');
      final snap = await m.snapshot();
      final m2 = _make()..restore(snap);
      addTearDown(m2.dispose);
      expect((await m2.run('i')).value, const MontyInt(1));
      expect((await m2.run('s')).value, const MontyString('hi'));
      expect((await m2.run('b')).value, const MontyBool(true));
      expect((await m2.run('n')).value, const MontyNone());
    });

    test('nested collection survives round-trip', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('d = {"a": [1, 2, {"b": 3}]}');
      final snap = await m.snapshot();
      final m2 = _make()..restore(snap);
      addTearDown(m2.dispose);
      expect((await m2.run('d["a"][2]["b"]')).value, const MontyInt(3));
    });

    test('accumulated state from multiple runs survives', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('x = 1');
      await m.run('y = 2');
      final snap = await m.snapshot();
      final m2 = _make()..restore(snap);
      addTearDown(m2.dispose);
      expect((await m2.run('x')).value, const MontyInt(1));
      expect((await m2.run('y')).value, const MontyInt(2));
    });

    test('compile + runPrecompiled round-trip (static)', () async {
      final binary = await Monty.compile('2 ** 8');
      expect(binary, isNotEmpty);
      final result = await Monty.runPrecompiled(binary);
      expect(result.value, const MontyInt(256));
    });

    test('compile syntax error throws MontySyntaxError', () async {
      await expectLater(
        Monty.compile('def ('),
        throwsA(isA<MontySyntaxError>()),
      );
    });

    test('import on first call visible on second call', () async {
      final m = _make();
      addTearDown(m.dispose);
      await m.run('import pathlib');
      final r = await m.run('str(type(pathlib))');
      expect(r.value, const MontyString("<class 'module'>"));
    });

    test('inputs are injected as Python variables', () async {
      final m = _make();
      addTearDown(m.dispose);
      final r = await m.run('x + y', inputs: {'x': 10, 'y': 20});
      expect(r.value, const MontyInt(30));
    });

    test('invalid snapshot bytes throw ArgumentError', () async {
      final m = _make();
      addTearDown(m.dispose);
      expect(
        () => m.restore(Uint8List.fromList([1, 2, 3])),
        throwsArgumentError,
      );
    });

    test('snapshot on disposed session throws StateError', () async {
      final m = _make();
      await m.dispose();
      await expectLater(m.snapshot, throwsStateError);
    });
  });
}
