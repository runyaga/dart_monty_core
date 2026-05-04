// Shared test body for ffi_print_callback_test.dart and
// wasm_print_callback_test.dart.
//
// printCallback is a batch (not streaming) hook fired once per call with
// the full captured stdout text. The same dispatch site sits inside
// MontyRepl.feedRun, so FFI and WASM share these scenarios verbatim.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runPrintCallbackTests() {
  group('printCallback (batch)', () {
    test('Monty(code).run delivers print output to the callback', () async {
      final captured = <(String, String)>[];
      final program = Monty('print("hello")\nprint("world")');
      final r = await program.run(
        printCallback: (stream, text) => captured.add((stream, text)),
      );

      expect(r.error, isNull);
      expect(captured, [
        ('stdout', 'hello\nworld\n'),
      ]);
      expect(r.printOutput, 'hello\nworld\n');
    });

    test('callback is not invoked when the script prints nothing', () async {
      final captured = <(String, String)>[];
      final r = await Monty('1 + 1').run(
        printCallback: (stream, text) => captured.add((stream, text)),
      );

      expect(r.error, isNull);
      expect(captured, isEmpty);
    });

    test('Monty.exec forwards printCallback', () async {
      final captured = <(String, String)>[];
      await Monty.exec(
        'print("from exec")',
        printCallback: (stream, text) => captured.add((stream, text)),
      );

      expect(captured, [
        ('stdout', 'from exec\n'),
      ]);
    });

    test(
      'MontyRepl.feedRun fires once per call across multiple feeds',
      () async {
        final captured = <(String, String)>[];
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        await repl.feedRun(
          'print("a")',
          printCallback: (stream, text) => captured.add((stream, text)),
        );
        await repl.feedRun(
          'print("b")',
          printCallback: (stream, text) => captured.add((stream, text)),
        );

        expect(captured, [
          ('stdout', 'a\n'),
          ('stdout', 'b\n'),
        ]);
      },
    );

    test('callback fires alongside externalFunctions dispatch', () async {
      final captured = <(String, String)>[];
      final r = await Monty('print(double(value))').run(
        inputs: {'value': 21},
        externalFunctions: {
          'double': (args, _) async => (args[0]! as int) * 2,
        },
        printCallback: (stream, text) => captured.add((stream, text)),
      );

      expect(r.error, isNull);
      expect(captured, [
        ('stdout', '42\n'),
      ]);
    });

    test('stream argument is always "stdout"', () async {
      final streams = <String>{};
      await Monty('print("x")\nprint("y")\nprint("z")').run(
        printCallback: (stream, _) => streams.add(stream),
      );
      expect(streams, {'stdout'});
    });
  });
}
