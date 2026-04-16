// Unit tests for MontyProgress.fromJson — sealed subtype dispatch,
// default values, and unknown-type error handling.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// Shared zero-usage sub-map for MontyComplete result payloads.
const _zeroUsage = {
  'memory_bytes_used': 0,
  'time_elapsed_ms': 0,
  'stack_depth_used': 0,
};

void main() {
  group('MontyProgress.fromJson', () {
    // -----------------------------------------------------------------------
    group('MontyComplete', () {
      test('dispatches on type=complete', () {
        final p = MontyProgress.fromJson({
          'type': 'complete',
          'result': {
            'value': 42,
            'error': null,
            'usage': {
              'memory_bytes_used': 1024,
              'time_elapsed_ms': 10,
              'stack_depth_used': 5,
            },
          },
        });
        expect(p, isA<MontyComplete>());
      });

      test('result value is deserialized', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'complete',
                  'result': {
                    'value': 'hello',
                    'error': null,
                    'usage': _zeroUsage,
                  },
                })
                as MontyComplete;
        expect(p.result.value, equals(const MontyString('hello')));
      });

      test('isError false when no error', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'complete',
                  'result': {
                    'value': null,
                    'error': null,
                    'usage': _zeroUsage,
                  },
                })
                as MontyComplete;
        expect(p.result.isError, isFalse);
      });

      test('isError true when error present', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'complete',
                  'result': {
                    'value': null,
                    'error': {'message': 'oops', 'exc_type': 'ValueError'},
                    'usage': _zeroUsage,
                  },
                })
                as MontyComplete;
        expect(p.result.isError, isTrue);
      });
    });

    // -----------------------------------------------------------------------
    group('MontyPending', () {
      test('dispatches on type=pending', () {
        final p = MontyProgress.fromJson({
          'type': 'pending',
          'function_name': 'my_fn',
          'arguments': <dynamic>[],
        });
        expect(p, isA<MontyPending>());
      });

      test('functionName extracted', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'fetch_data',
                  'arguments': <dynamic>[],
                })
                as MontyPending;
        expect(p.functionName, 'fetch_data');
      });

      test('arguments deserialized', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': [1, 'x'],
                })
                as MontyPending;
        expect(p.arguments, [
          const MontyInt(1),
          const MontyString('x'),
        ]);
      });

      test('callId defaults to 0 when absent', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': <dynamic>[],
                })
                as MontyPending;
        expect(p.callId, 0);
      });

      test('callId parsed when present', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': <dynamic>[],
                  'call_id': 7,
                })
                as MontyPending;
        expect(p.callId, 7);
      });

      test('kwargs parsed when present', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': <dynamic>[],
                  'kwargs': {'key': 99},
                })
                as MontyPending;
        expect(p.kwargs?['key'], const MontyInt(99));
      });

      test('kwargs null when absent', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': <dynamic>[],
                })
                as MontyPending;
        expect(p.kwargs, isNull);
      });

      test('methodCall defaults to false', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': <dynamic>[],
                })
                as MontyPending;
        expect(p.methodCall, isFalse);
      });

      test('methodCall parsed when true', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'pending',
                  'function_name': 'f',
                  'arguments': <dynamic>[],
                  'method_call': true,
                })
                as MontyPending;
        expect(p.methodCall, isTrue);
      });
    });

    // -----------------------------------------------------------------------
    group('MontyOsCall', () {
      test('dispatches on type=os_call', () {
        final p = MontyProgress.fromJson({
          'type': 'os_call',
          'operation_name': 'Path.read_text',
          'arguments': <dynamic>[],
        });
        expect(p, isA<MontyOsCall>());
      });

      test('operationName extracted', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'os_call',
                  'operation_name': 'os.getenv',
                  'arguments': <dynamic>[],
                })
                as MontyOsCall;
        expect(p.operationName, 'os.getenv');
      });

      test('arguments and kwargs', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'os_call',
                  'operation_name': 'op',
                  'arguments': ['HOME'],
                  'kwargs': {'default': 'none'},
                })
                as MontyOsCall;
        expect(p.arguments, [const MontyString('HOME')]);
        expect(p.kwargs?['default'], const MontyString('none'));
      });
    });

    // -----------------------------------------------------------------------
    group('MontyResolveFutures', () {
      test('dispatches on type=resolve_futures', () {
        final p = MontyProgress.fromJson({
          'type': 'resolve_futures',
          'pending_call_ids': [1, 2, 3],
        });
        expect(p, isA<MontyResolveFutures>());
      });

      test('pendingCallIds extracted', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'resolve_futures',
                  'pending_call_ids': [10, 20],
                })
                as MontyResolveFutures;
        expect(p.pendingCallIds, [10, 20]);
      });
    });

    // -----------------------------------------------------------------------
    group('MontyNameLookup', () {
      test('dispatches on type=name_lookup', () {
        final p = MontyProgress.fromJson({
          'type': 'name_lookup',
          'variable_name': 'MY_VAR',
        });
        expect(p, isA<MontyNameLookup>());
      });

      test('variableName extracted', () {
        final p =
            MontyProgress.fromJson({
                  'type': 'name_lookup',
                  'variable_name': 'PATH',
                })
                as MontyNameLookup;
        expect(p.variableName, 'PATH');
      });
    });

    // -----------------------------------------------------------------------
    group('unknown type', () {
      test('throws ArgumentError', () {
        expect(
          () => MontyProgress.fromJson({'type': 'unknown_future_type'}),
          throwsArgumentError,
        );
      });
    });
  });
}
