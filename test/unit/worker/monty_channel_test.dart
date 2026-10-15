// The channel's crash helpers (lib/src/worker/monty_channel.dart). Pure
// Dart: vm, dart2js and dart2wasm.
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:test/test.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;

void main() {
  group('repeatCrash', () {
    test('a repeat is the same crash', () {
      final crash = crashedError(
        CrashCause.fatal,
        detail: 'd',
        exitCode: 2,
        stderrTail: 's',
      );
      final again = repeatCrash(crash);
      expect(again, isNot(same(crash)));
      expect(
        (again.toString(), again.cause, again.detail, again.exitStatus),
        (crash.toString(), crash.cause, crash.detail, crash.exitStatus),
      );
      expect(again.stderrTail, 's');
      expect(again.timedOut, crash.timedOut);
    });

    test('a deadline kill and a context are kept too', () {
      final killed = repeatCrash(
        crashedError(
          CrashCause.killed,
          detail: 'monty worker killed after exceeding request timeout of 1s',
          timedOut: true,
        ),
      );
      expect(killed.timedOut, isTrue);
      expect(
        killed.toString(),
        'monty worker killed after exceeding request timeout of 1s',
      );
      final lost = repeatCrash(
        crashedError(CrashCause.vanished, context: sendingRequest),
      );
      expect(lost.toString(), 'monty worker crashed while sending a request');
    });
  });
}
