@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('ffi_multi_repl', () {
    test('two concurrent REPLs have independent state', () async {
      final repl1 = MontyRepl();
      final repl2 = MontyRepl();
      addTearDown(repl1.dispose);
      addTearDown(repl2.dispose);

      await repl1.feed('x = 10');
      await repl2.feed('x = 99');

      expect((await repl1.feed('x')).value, const MontyInt(10));
      expect((await repl2.feed('x')).value, const MontyInt(99));
    });

    test('disposing one REPL does not affect the other', () async {
      final repl1 = MontyRepl();
      final repl2 = MontyRepl();
      addTearDown(repl2.dispose);

      await repl1.feed('msg = "repl1"');
      await repl2.feed('msg = "repl2"');
      await repl1.dispose();

      expect((await repl2.feed('msg')).value, const MontyString('repl2'));
    });

    test('three concurrent REPLs remain isolated', () async {
      final repls = [MontyRepl(), MontyRepl(), MontyRepl()];
      addTearDown(() async {
        for (final r in repls) {
          await r.dispose();
        }
      });

      for (var i = 0; i < repls.length; i++) {
        await repls[i].feed('n = $i');
      }
      for (var i = 0; i < repls.length; i++) {
        expect((await repls[i].feed('n')).value, MontyInt(i));
      }
    });
  });
}
