// The red half of the M1 spike, as a program rather than an assertion.
//
// It runs the overflow in the CALLER'S OWN PROCESS. It cannot be a normal test
// because it does not fail — it dies, and a dead process reports nothing to a
// test runner. So `ffi_pool_spike_test.dart` spawns this and reads its
// exit code, which is the only channel a process abort leaves open.
//
// If this ever prints `SURVIVED`, the premise of
// `docs/adr/0001-ffi-crash-isolation.md` has changed and the ADR must be
// revisited — do not quietly relax the test.
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final result = await Monty('''
def f(n):
    return f(n + 1)
f(0)
''').run(limits: const MontyLimits(stackDepth: 100000));

  // A standalone probe binary spawned by a test: its exit code and stdout are
  // the only channels the test can observe, so printing is the mechanism, not
  // a debugging leftover.
  // ignore: avoid_print
  print('SURVIVED error=${result.error}');
}
