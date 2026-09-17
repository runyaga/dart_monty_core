// Unit tests for the MontyProgress sealed hierarchy.
//
// This file covered ONLY `MontyComplete.output` -- 3 tests over a 406-line
// file, measured at 6.2% line coverage (7/113). Everything else here is the
// wire boundary: every pause the engine can hand back to a host arrives as one
// of these five subtypes, decoded from JSON by `MontyProgress.fromJson`. A
// decoder that silently defaults the wrong way, or a `toJson` that drops a
// field the encoder needs, is a whole class of bug that no FFI or WASM test
// would localise -- it would surface as "the host resumed with the wrong
// value" three layers up.
//
// The tests below are written against the CONTRACTS the doc comments state,
// not against the current implementation's shape, so they fail if the
// behaviour changes rather than if the code is merely rearranged.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

void main() {
  group('MontyComplete.output', () {
    test('output equals result.value', () {
      const complete = MontyComplete(
        result: MontyResult(value: MontyInt(42), usage: _zeroUsage),
      );
      expect(complete.output, equals(complete.result.value));
    });

    test('output returns the MontyValue directly', () {
      const complete = MontyComplete(
        result: MontyResult(value: MontyString('hello'), usage: _zeroUsage),
      );
      expect(complete.output, const MontyString('hello'));
    });

    test('output works with MontyNone', () {
      const complete = MontyComplete(
        result: MontyResult(value: MontyNone(), usage: _zeroUsage),
      );
      expect(complete.output, const MontyNone());
    });
  });

  // ---------------------------------------------------------------------
  // The discriminator. `MontyProgress.fromJson` is the only entry point the
  // backends use, so a type it cannot route is an execution that stalls.
  // ---------------------------------------------------------------------
  group('MontyProgress.fromJson dispatch', () {
    test('routes each of the five discriminators to its subtype', () {
      expect(
        MontyProgress.fromJson({
          'type': 'complete',
          'result': const MontyResult(
            value: MontyInt(1),
            usage: _zeroUsage,
          ).toJson(),
        }),
        isA<MontyComplete>(),
      );
      expect(
        MontyProgress.fromJson({
          'type': 'pending',
          'function_name': 'f',
          'arguments': <Object?>[],
        }),
        isA<MontyPending>(),
      );
      expect(
        MontyProgress.fromJson({
          'type': 'os_call',
          'operation_name': 'os.getenv',
          'arguments': <Object?>[],
        }),
        isA<MontyOsCall>(),
      );
      expect(
        MontyProgress.fromJson({
          'type': 'resolve_futures',
          'pending_call_ids': <Object?>[1],
        }),
        isA<MontyResolveFutures>(),
      );
      expect(
        MontyProgress.fromJson({
          'type': 'name_lookup',
          'variable_name': 'x',
        }),
        isA<MontyNameLookup>(),
      );
    });

    test('an unknown type throws ArgumentError rather than returning null', () {
      // The failure has to be LOUD. A decoder that returned null here would
      // turn "this engine speaks a newer protocol" into a null-dereference
      // somewhere else entirely.
      expect(
        () => MontyProgress.fromJson({'type': 'teleport'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  // ---------------------------------------------------------------------
  // MontyPending. The kwargs three-state is the subtle one and is stated
  // explicitly in the doc comment: null means "no keyword arguments were
  // used", {} means "kwargs were explicitly empty (e.g. fn(**{}))". Those
  // are different Python call sites and must not collapse into each other.
  // ---------------------------------------------------------------------
  group('MontyPending', () {
    test('fromJson applies the documented defaults', () {
      final p = MontyPending.fromJson(const {
        'type': 'pending',
        'function_name': 'fetch',
        'arguments': <Object?>[1, 'two'],
      });

      expect(p.functionName, 'fetch');
      expect(p.args, [const MontyInt(1), const MontyString('two')]);
      expect(p.kwargs, isNull, reason: 'absent kwargs is null, not {}');
      expect(p.callId, 0);
      expect(p.methodCall, isFalse);
    });

    test('absent `arguments` decodes to an empty list, not null', () {
      final p = MontyPending.fromJson(const {
        'type': 'pending',
        'function_name': 'noargs',
      });
      expect(p.args, isEmpty);
    });

    test('null kwargs and empty kwargs are DIFFERENT, and survive a '
        'round-trip', () {
      const noKwargs = MontyPending(functionName: 'f', args: []);
      const emptyKwargs = MontyPending(
        functionName: 'f',
        args: [],
        kwargs: {},
      );

      expect(noKwargs, isNot(equals(emptyKwargs)));

      // The wire form is where the distinction is actually at risk: the key
      // is omitted for null and present-but-empty for {}.
      expect(noKwargs.toJson().containsKey('kwargs'), isFalse);
      expect(emptyKwargs.toJson().containsKey('kwargs'), isTrue);

      // And it must come back the same way.
      expect(MontyProgress.fromJson(noKwargs.toJson()), noKwargs);
      expect(MontyProgress.fromJson(emptyKwargs.toJson()), emptyKwargs);
    });

    test('toJson omits callId 0 and methodCall false, and they round-trip '
        'back to those defaults', () {
      const p = MontyPending(functionName: 'f', args: []);
      final json = p.toJson();

      expect(json.containsKey('call_id'), isFalse);
      expect(json.containsKey('method_call'), isFalse);
      expect(MontyProgress.fromJson(json), p);
    });

    test('toJson emits callId and methodCall when they are not the '
        'defaults', () {
      const p = MontyPending(
        functionName: 'obj.method',
        args: [MontyInt(7)],
        callId: 42,
        methodCall: true,
      );
      final json = p.toJson();

      expect(json['call_id'], 42);
      expect(json['method_call'], isTrue);
      expect(MontyProgress.fromJson(json), p);
    });

    test('equality is DEEP over args and kwargs, and hashCode agrees', () {
      // Distinct list/map instances with equal contents. A shallow `==` here
      // would make two decodings of the same wire message compare unequal.
      // `List.of` / `Map.of` ON PURPOSE. A const literal here would be
      // CANONICALISED -- `a.args` and `b.args` would become the same object
      // and `identical` below would pass for the wrong reason, testing
      // nothing. This is also why the lint is not simply silenced.
      final a = MontyPending(
        functionName: 'f',
        args: List.of([const MontyInt(1), const MontyString('x')]),
        kwargs: Map.of({'k': const MontyBool(true)}),
      );
      final b = MontyPending(
        functionName: 'f',
        args: List.of([const MontyInt(1), const MontyString('x')]),
        kwargs: Map.of({'k': const MontyBool(true)}),
      );

      expect(identical(a.args, b.args), isFalse, reason: 'distinct instances');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing callId or methodCall breaks equality', () {
      const base = MontyPending(functionName: 'f', args: []);
      expect(
        base,
        isNot(
          equals(const MontyPending(functionName: 'f', args: [], callId: 1)),
        ),
      );
      expect(
        base,
        isNot(
          equals(
            const MontyPending(
              functionName: 'f',
              args: [],
              methodCall: true,
            ),
          ),
        ),
      );
    });

    test('toString names the function and args', () {
      const p = MontyPending(functionName: 'fetch', args: [MontyInt(1)]);
      final text = p.toString();
      expect(text, contains('fetch'));
      expect(text, startsWith('MontyPending('));
    });
  });

  // ---------------------------------------------------------------------
  // MontyOsCall carries the same kwargs/callId contract as MontyPending but
  // has NO methodCall, so it gets its own coverage rather than being assumed
  // equivalent.
  // ---------------------------------------------------------------------
  group('MontyOsCall', () {
    test('fromJson applies the documented defaults', () {
      final c = MontyOsCall.fromJson(const {
        'type': 'os_call',
        'operation_name': 'Path.read_text',
        'arguments': <Object?>['/tmp/x'],
      });

      expect(c.operationName, 'Path.read_text');
      expect(c.args, [const MontyString('/tmp/x')]);
      expect(c.kwargs, isNull);
      expect(c.callId, 0);
    });

    test('absent `arguments` decodes to an empty list', () {
      final c = MontyOsCall.fromJson(const {
        'type': 'os_call',
        'operation_name': 'os.getcwd',
      });
      expect(c.args, isEmpty);
    });

    test('null vs empty kwargs is preserved across a round-trip', () {
      const none = MontyOsCall(operationName: 'op', args: []);
      const empty = MontyOsCall(operationName: 'op', args: [], kwargs: {});

      expect(none, isNot(equals(empty)));
      expect(none.toJson().containsKey('kwargs'), isFalse);
      expect(empty.toJson().containsKey('kwargs'), isTrue);
      expect(MontyProgress.fromJson(none.toJson()), none);
      expect(MontyProgress.fromJson(empty.toJson()), empty);
    });

    test('toJson omits callId 0 and emits it otherwise', () {
      const zero = MontyOsCall(operationName: 'op', args: []);
      const nonZero = MontyOsCall(operationName: 'op', args: [], callId: 9);

      expect(zero.toJson().containsKey('call_id'), isFalse);
      expect(nonZero.toJson()['call_id'], 9);
      expect(MontyProgress.fromJson(nonZero.toJson()), nonZero);
    });

    test('equality is deep and hashCode agrees', () {
      // Distinct instances -- see the note in the MontyPending case.
      final a = MontyOsCall(
        operationName: 'op',
        args: List.of([const MontyInt(1)]),
        kwargs: Map.of({'k': const MontyNone()}),
      );
      final b = MontyOsCall(
        operationName: 'op',
        args: List.of([const MontyInt(1)]),
        kwargs: Map.of({'k': const MontyNone()}),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(equals(const MontyOsCall(operationName: 'other', args: []))),
      );
    });

    test('toString names the operation', () {
      const c = MontyOsCall(operationName: 'os.getenv', args: []);
      final text = c.toString();
      expect(text, startsWith('MontyOsCall('));
      expect(text, contains('os.getenv'));
    });
  });

  group('MontyResolveFutures', () {
    test('round-trips its call ids', () {
      const r = MontyResolveFutures(pendingCallIds: [1, 2, 3]);
      expect(r.toJson(), {
        'type': 'resolve_futures',
        'pending_call_ids': [1, 2, 3],
      });
      expect(MontyProgress.fromJson(r.toJson()), r);
    });

    test('decodes an empty id list', () {
      final r = MontyResolveFutures.fromJson(const {
        'type': 'resolve_futures',
        'pending_call_ids': <Object?>[],
      });
      expect(r.pendingCallIds, isEmpty);
    });

    test('equality is deep over the id list, and hashCode agrees', () {
      // Distinct instances -- see the note in the MontyPending case.
      final a = MontyResolveFutures(pendingCallIds: List.of([1, 2]));
      final b = MontyResolveFutures(pendingCallIds: List.of([1, 2]));

      expect(identical(a.pendingCallIds, b.pendingCallIds), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(equals(const MontyResolveFutures(pendingCallIds: [2, 1]))),
      );
    });

    test('toString names the ids', () {
      const r = MontyResolveFutures(pendingCallIds: [7]);
      final text = r.toString();
      expect(text, startsWith('MontyResolveFutures('));
      expect(text, contains('7'));
    });
  });

  group('MontyNameLookup', () {
    test('round-trips the variable name', () {
      const n = MontyNameLookup(variableName: 'PI');
      expect(n.toJson(), {'type': 'name_lookup', 'variable_name': 'PI'});
      expect(MontyProgress.fromJson(n.toJson()), n);
    });

    test('a missing variable_name decodes to the empty string, not null', () {
      // Documented default. It matters because the host switches on this
      // name; a null would crash the lookup instead of missing it.
      final n = MontyNameLookup.fromJson(const {'type': 'name_lookup'});
      expect(n.variableName, '');
    });

    test('equality and hashCode follow the name', () {
      const a = MontyNameLookup(variableName: 'x');
      const b = MontyNameLookup(variableName: 'x');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(const MontyNameLookup(variableName: 'y'))));
    });

    test('toString names the variable', () {
      const n = MontyNameLookup(variableName: 'total');
      final text = n.toString();
      expect(text, startsWith('MontyNameLookup('));
      expect(text, contains('total'));
    });
  });

  group('MontyComplete wire form', () {
    test('round-trips through MontyProgress.fromJson', () {
      const c = MontyComplete(
        result: MontyResult(value: MontyString('done'), usage: _zeroUsage),
      );
      final decoded = MontyProgress.fromJson(c.toJson());

      expect(decoded, isA<MontyComplete>());
      expect(decoded, equals(c));
    });

    test('toJson carries the complete discriminator', () {
      const c = MontyComplete(
        result: MontyResult(value: MontyNone(), usage: _zeroUsage),
      );
      expect(c.toJson()['type'], 'complete');
    });

    test('equality follows the result, and hashCode agrees', () {
      const a = MontyComplete(
        result: MontyResult(value: MontyInt(1), usage: _zeroUsage),
      );
      const b = MontyComplete(
        result: MontyResult(value: MontyInt(1), usage: _zeroUsage),
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(
        a,
        isNot(
          equals(
            const MontyComplete(
              result: MontyResult(value: MontyInt(2), usage: _zeroUsage),
            ),
          ),
        ),
      );
    });

    test('toString names the result', () {
      const c = MontyComplete(
        result: MontyResult(value: MontyInt(5), usage: _zeroUsage),
      );
      expect(c.toString(), startsWith('MontyComplete('));
    });
  });
}
