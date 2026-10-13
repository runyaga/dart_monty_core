// The native default print sink (lib/src/worker/default_print_io.dart) in
// process, and the stub for platforms with no worker channel. What reaches
// a real process's streams is checked end to end by
// test/integration/worker/pool_session_io_test.dart; here each delivery
// writes nothing visible (the empty string), so the test runner's own
// output is untouched.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'package:dart_monty_core/src/worker/default_print_io.dart' as io;
import 'package:dart_monty_core/src/worker/default_print_stub.dart' as stub;
import 'package:test/test.dart';

void main() {
  test('deliveries on both streams complete once flushed, in order', () async {
    final done = <String>[];
    Future<void> deliver(int i, String stream) async {
      await io.defaultPrint(stream, '');
      done.add('$i');
    }

    await Future.wait([
      for (final (i, stream) in ['stdout', 'stderr', 'stdout'].indexed)
        deliver(i, stream),
    ]);
    // Per stream, a later delivery never completes before an earlier one.
    expect(done.indexOf('0'), lessThan(done.indexOf('2')));
    expect(done, hasLength(3));
  });

  test('the stub refuses: no session can print there', () {
    expect(
      () => stub.defaultPrint('stdout', 'x'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
