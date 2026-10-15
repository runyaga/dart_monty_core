// OS handlers against upstream's outcomes: each case of
// _os_handler_oracle.g.dart (pydantic-monty 1.1.0) run on a real pool with
// the same handler, built from the case's description
// (tool/generate_os_handler_oracle.py says what each means). A decline is
// only a synchronous throw; a Future that fails with the decline raises
// TypeError, for a sleep too, as upstream's coroutine returning NOT_HANDLED
// does. Shared by the VM harness
// (test/integration/worker/pool_session_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart'
    show OsCallNotHandledException;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_os_handler_oracle.g.dart';

/// Starts a pool with [options].
typedef StartOsHandlerPool = Future<MontyPool> Function(PoolOptions options);

/// Upstream's Python class names in a conversion failure, and the Dart
/// names core gives in their place.
const Map<String, String> _names = {
  'pydantic_monty._NotHandledSentinel': 'OsCallNotHandledException',
  'pydantic_monty.ClassInstance': 'ClassInstance',
};

/// The handler a case names.
OsHandler _handler(String name) => switch (name) {
  'decline' => (n, a, k) => throw const OsCallNotHandledException(),
  'async_decline' => (n, a, k) async => throw const OsCallNotHandledException(),
  'async_value' => (n, a, k) async => const MontyString('v'),
  'async_raise' => (n, a, k) async => throw const ExternalException(
    'ValueError',
    'x',
  ),
  _ => throw StateError('unknown handler $name'),
};

/// The oracle's text for [value]: the cases return str, None and lists.
String _repr(MontyValue value) => switch (value) {
  MontyNone() => 'None',
  MontyString(:final value) => pythonRepr(value),
  MontyList(:final items) => '[${items.map(_repr).join(', ')}]',
  _ => throw StateError('unexpected value $value'),
};

/// [outcome] with upstream's class names replaced by core's.
String _dartNames(String outcome) =>
    _names.entries.fold(outcome, (s, e) => s.replaceAll(e.key, e.value));

void _ignore(String stream, String text) {}

/// Every OS-handler case, each its own test labelled with [label].
void osHandlerOracleTests(String label, StartOsHandlerPool start) {
  test('the OS-handler oracle is complete ($label)', () {
    expect(osHandlerOracle.length, greaterThanOrEqualTo(24));
  });

  for (final MapEntry(key: id, value: (:handler, :code, :outcome))
      in osHandlerOracle.entries) {
    test(
      'OS handler $id matches upstream ($label)',
      () async {
        final pool = await start(const PoolOptions(maxProcesses: 1));
        try {
          final session = await pool.checkout(
            options: const SessionConfig(
              osPolicy: OsPolicy(datetime: 'call_host', sleep: 'call_host'),
            ),
          );
          String actual;
          try {
            actual =
                'value: ${_repr(
                  await session.feedRun(
                    osHandlerCodes[code]!,
                    os: _handler(handler),
                    printCallback: _ignore,
                  ),
                )}';
          } on MontyRuntimeError catch (e) {
            actual = 'MontyRuntimeError: ${e.display('type-msg')}';
          } finally {
            await session.close();
          }
          expect(actual, _dartNames(outcome));
        } finally {
          await pool.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
