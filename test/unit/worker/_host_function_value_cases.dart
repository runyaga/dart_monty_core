// Host functions through each value channel, shared by native and browser
// runners.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

typedef WithHostFunctionSession =
    Future<void> Function(Future<void> Function(MontySession session) body);

MontyHostFunction _function(String name) =>
    MontyHostFunction(name, (_, _) => const MontyNone());

Matcher _namedFunction(String name) => isA<FunctionSnapshot>().having(
  (snapshot) => snapshot.functionName,
  'function name',
  name,
);

void hostFunctionValueTests(
  String label,
  WithHostFunctionSession withSession,
) {
  group('host function values ($label)', () {
    test(
      'a function supplied as an input keeps its name',
      () async {
        await withSession((session) async {
          final snapshot = await session.feedStart(
            'value()',
            inputs: {'value': _function('input_function')},
          );
          expect(snapshot, _namedFunction('input_function'));
          final call = snapshot as FunctionSnapshot;
          final done = await call.resume(
            const ExternalReturnValue(MontyInt(42)),
          );

          expect((done as MontyComplete).output, const MontyInt(42));
        });
      },
    );

    test(
      'a manually resumed function keeps its name',
      () async {
        await withSession((session) async {
          final lookup =
              await session.feedStart('selected = provided')
                  as NameLookupSnapshot;
          final assigned = await lookup.resume(
            value: _function('lookup_function'),
          );
          expect(assigned, isA<MontyComplete>());

          final snapshot = await session.feedStart('selected()');
          expect(snapshot, _namedFunction('lookup_function'));
          final call = snapshot as FunctionSnapshot;
          final done = await call.resume(
            const ExternalReturnValue(MontyInt(42)),
          );

          expect((done as MontyComplete).output, const MontyInt(42));
        });
      },
    );

    test('an external return value can hold a function', () async {
      await withSession((session) async {
        final firstCall =
            await session.feedStart('outer_function()()') as FunctionSnapshot;
        final secondCall =
            await firstCall.resume(ExternalReturnValue(_function('returned')))
                as FunctionSnapshot;
        expect(secondCall, _namedFunction('returned'));
        final done = await secondCall.resume(
          const ExternalReturnValue(MontyInt(42)),
        );

        expect((done as MontyComplete).output, const MontyInt(42));
      });
    });

    test(
      'a function in nested containers keeps its name',
      () async {
        await withSession((session) async {
          final snapshot = await session.feedStart(
            'value[0][0]()',
            inputs: {
              'value': MontyTuple([
                MontyList([_function('nested_function')]),
              ]),
            },
          );
          expect(snapshot, _namedFunction('nested_function'));
          final call = snapshot as FunctionSnapshot;
          final done = await call.resume(
            const ExternalReturnValue(MontyInt(42)),
          );

          expect((done as MontyComplete).output, const MontyInt(42));
        });
      },
    );
  });
}
