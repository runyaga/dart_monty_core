// Integration pressure tests: snapshot/restore, compile/runPrecompiled,
// OsCall+VFS — all backed by real MontyFfi (no mock).
//
// Run: dart test test/integration/snapshot_ffi_test.dart -p vm --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  // -------------------------------------------------------------------------
  // A — MontySession snapshot round-trip
  // -------------------------------------------------------------------------

  group('A — snapshot round-trip', () {
    test('A1: empty session snapshot restores to empty state', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      expect(m2.state, equals(<String, Object?>{}));
      final r = await m2.run('1 + 1');
      expect(r.value, equals(const MontyInt(2)));
    });

    test('A2: single int survives round-trip', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('x = 42');
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      final r = await m2.run('x');
      expect(r.value, equals(const MontyInt(42)));
    });

    test('A3: all primitive types survive round-trip', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('i=1; f=1.5; s="hi"; b=True; n=None');
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      expect(m2.state['i'], equals(1));
      expect(m2.state['f'], equals(1.5));
      expect(m2.state['s'], equals('hi'));
      expect(m2.state['b'], equals(true));
      expect(m2.state['n'], isNull);
    });

    test('A4: nested collection survives round-trip', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('d = {"a": [1, 2, {"b": 3}]}');
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      final r = await m2.run('d["a"][2]["b"]');
      expect(r.value, equals(const MontyInt(3)));
    });

    test('A5: accumulated state from multiple runs survives', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('x = 1');
      await m1.run('y = 2');
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      expect(m2.state['x'], equals(1));
      expect(m2.state['y'], equals(2));
    });

    test('A6: restoring into B does not share state with A', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('x = 10');
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      // Mutate A after taking snapshot.
      await m1.run('x = 99');

      expect(m2.state['x'], equals(10));
    });

    test('A7: double round-trip preserves state', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('x = 7');
      final snap1 = m1.snapshot();

      final m2 = Monty()..restore(snap1);
      addTearDown(m2.dispose);
      final snap2 = m2.snapshot();

      final m3 = Monty()..restore(snap2);
      addTearDown(m3.dispose);

      expect(m3.state['x'], equals(7));
    });

    test('A8: clearState before snapshot produces empty restore', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('x = 1');
      m1.clearState();
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      expect(m2.state, equals(<String, Object?>{}));
    });
  });

  // -------------------------------------------------------------------------
  // B — compile / runPrecompiled
  // -------------------------------------------------------------------------

  group('B — compile / runPrecompiled', () {
    test(
      'B1: compile returns non-empty bytes; runPrecompiled executes',
      () async {
        final binary = await Monty.compile('1 + 1');
        expect(binary, isNotEmpty);

        final m = Monty();
        addTearDown(m.dispose);

        final r = await m.runPrecompiled(binary);
        expect(r.value, equals(const MontyInt(2)));
      },
    );

    test(
      'B2: same binary reused across 3 instances gives same result',
      () async {
        final binary = await Monty.compile('2 * 3');

        for (var i = 0; i < 3; i++) {
          final m = Monty();
          addTearDown(m.dispose);

          final r = await m.runPrecompiled(binary);
          expect(r.value, equals(const MontyInt(6)));
        }
      },
    );

    test('B3: runPrecompiled does not update session state', () async {
      final m = Monty();
      addTearDown(m.dispose);
      await m.run('x = 7');

      final binary = await Monty.compile('y = 100');
      await m.runPrecompiled(binary);

      expect(m.state['x'], equals(7));
      expect(m.state.containsKey('y'), isFalse);
    });

    test('B4: compile syntax error throws MontySyntaxError', () async {
      await expectLater(
        Monty.compile('def ('),
        throwsA(isA<MontySyntaxError>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // C — OsCall + snapshot
  // -------------------------------------------------------------------------

  group('C — OsCall + snapshot', () {
    test('C1: VFS string result captured in state survives restore', () async {
      final vfs = <String, String>{'/config.txt': 'version=1.0'};

      Future<Object?> osHandler(
        String op,
        List<Object?> args,
        Map<String, Object?>? kw,
      ) async {
        if (op != 'Path.read_text') {
          throw OsCallException('$op not supported');
        }

        return switch (args.first) {
          final String p => vfs[p] ?? '',
          _ => '',
        };
      }

      final m1 = Monty(osHandler: osHandler);
      addTearDown(m1.dispose);
      await m1.run(
        'import pathlib\n'
        'content = pathlib.Path("/config.txt").read_text()',
      );
      final snap = m1.snapshot();

      final m2 = Monty(osHandler: osHandler)..restore(snap);
      addTearDown(m2.dispose);

      final r = await m2.run('content');
      expect(r.value, equals(const MontyString('version=1.0')));
    });

    test('C2: OsCallHandler still dispatches after restore', () async {
      final vfs = <String, String>{'/config.txt': 'hello'};

      Future<Object?> osHandler(
        String op,
        List<Object?> args,
        Map<String, Object?>? kw,
      ) async {
        if (op != 'Path.read_text') {
          throw OsCallException('$op not supported');
        }

        return switch (args.first) {
          final String p => vfs[p] ?? '',
          _ => '',
        };
      }

      final m1 = Monty(osHandler: osHandler);
      addTearDown(m1.dispose);
      await m1.run('import pathlib');
      final snap = m1.snapshot();

      final m2 = Monty(osHandler: osHandler)..restore(snap);
      addTearDown(m2.dispose);

      final r = await m2.run(
        'import pathlib\npathlib.Path("/config.txt").read_text()',
      );
      expect(r.value, equals(const MontyString('hello')));
    });

    test(
      'C3: missing OsCallHandler returns Python error, no Dart throw',
      () async {
        final m = Monty();
        addTearDown(m.dispose);

        final r = await m.run(
          'import pathlib\npathlib.Path("/x").read_text()',
        );
        expect(r.error, isNotNull);
      },
    );

    test('C4: Dart-side VFS tree is NOT captured in snapshot', () async {
      final vfsA = <String, String>{};

      Future<Object?> vfsAHandler(
        String op,
        List<Object?> args,
        Map<String, Object?>? kw,
      ) async {
        if (op == 'Path.read_text') {
          return switch (args.first) {
            final String p => vfsA[p] ?? '',
            _ => '',
          };
        }

        if (op == 'Path.write_text') {
          if (args case [final String p, final String t, ...]) {
            vfsA[p] = t;
          }

          return null;
        }

        throw OsCallException('$op not supported');
      }

      final m1 = Monty(osHandler: vfsAHandler);
      addTearDown(m1.dispose);
      await m1.run(
        "import pathlib\npathlib.Path('/new.txt').write_text('data')",
      );
      final snap = m1.snapshot();

      // Session B: empty VFS — '/new.txt' was not written here.
      final vfsB = <String, String>{};
      Future<Object?> vfsBHandler(
        String op,
        List<Object?> args,
        Map<String, Object?>? kw,
      ) async {
        if (op != 'Path.read_text') {
          throw OsCallException('$op not supported');
        }

        return switch (args.first) {
          final String p => vfsB[p] ?? '',
          _ => '',
        };
      }

      final m2 = Monty(osHandler: vfsBHandler)..restore(snap);
      addTearDown(m2.dispose);

      await m2.run(
        "import pathlib\ncontent = pathlib.Path('/new.txt').read_text()",
      );
      // VFS B has no '/new.txt' — content is empty string.
      expect(m2.state['content'], equals(''));
    });
  });

  // -------------------------------------------------------------------------
  // D — Edge cases
  // -------------------------------------------------------------------------

  group('D — edge cases', () {
    test(
      'D1: 50 variables across 5 runs all survive snapshot/restore',
      () async {
        final m1 = Monty();
        addTearDown(m1.dispose);

        for (var batch = 0; batch < 5; batch++) {
          final assignments = Iterable.generate(
            10,
            (j) => 'x${batch * 10 + j} = ${batch * 10 + j}',
          ).join('\n');
          await m1.run(assignments);
        }
        final snap = m1.snapshot();

        final m2 = Monty()..restore(snap);
        addTearDown(m2.dispose);

        for (var i = 0; i < 50; i++) {
          expect(m2.state['x$i'], equals(i), reason: 'x$i mismatch');
        }
      },
    );

    test('D2: snapshot bytes are valid JSON with v==1 and dartState', () async {
      final m = Monty();
      addTearDown(m.dispose);
      await m.run('answer = 42');
      final snap = m.snapshot();

      final envelope = jsonDecode(utf8.decode(snap)) as Map<String, dynamic>;
      expect(envelope['v'], equals(1));
      expect(envelope['dartState'], isA<Map<String, dynamic>>());

      final dartState = envelope['dartState'] as Map<String, dynamic>;
      expect(dartState['answer'], equals(42));
    });

    test(
      'D3: invalid bytes throw ArgumentError; session still usable',
      () async {
        final m = Monty();
        addTearDown(m.dispose);

        expect(
          () => m.restore(Uint8List.fromList([0, 1, 2, 3])),
          throwsArgumentError,
        );

        final r = await m.run('1 + 1');
        expect(r.value, equals(const MontyInt(2)));
      },
    );
  });
}
