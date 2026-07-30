// AOT smoke probe — compiled with `dart compile exe` and executed by CI.
//
// Why this exists (core#130): the `test-aot` job did not exercise AOT at all.
// It ran `dart test --compiler=kernel`, which is the JIT default, and then a
// step named "Run compiled AOT snapshot" that was a literal `echo` claiming
// success. Nothing could fail.
//
// AOT matters for this package specifically: it links a Rust static library
// through native assets, and AOT and JIT can diverge on exactly the things
// this package does — number representation at the FFI boundary, tree-shaking
// of entry points, and native-asset registration. A package that works under
// JIT and fails under AOT is a real and previously undetectable outcome.
//
// Deliberately small: it proves the package links, the native asset resolves,
// and the interpreter evaluates under AOT. Full conformance stays with the
// integration suites.
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final result = await Monty('2 + 2').run();

  if (result.error != null) {
    throw StateError('AOT probe errored: ${result.error}');
  }
  if (result.value != MontyValue.fromDart(4)) {
    throw StateError('AOT probe got ${result.value}, expected MontyInt(4)');
  }

  // Exercise a value conversion too, so the probe covers more than an int.
  final dict = await Monty('{"b": 1, "a": 2}').run();
  if (dict.error != null) {
    throw StateError('AOT probe dict errored: ${dict.error}');
  }

  // This is a standalone CI probe binary, not library code; stdout is the only
  // channel CI can observe.
  // ignore: avoid_print
  print('AOT probe OK: 2 + 2 = ${result.value}, dict = ${dict.value}');
}
