// The session surface against upstream's outcomes: each case of
// _session_oracle.g.dart (pydantic-monty 1.1.0: feed_run / feed_start with
// external_lookup and cwd) run on a real pool, through the public library
// only. The host class `Point` and the host functions mirror
// tool/generate_session_oracle.py. Shared by the VM harness
// (test/integration/worker/monty_snapshot_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show CrashCause, crashedError;
import 'package:test/test.dart';

import '_attribute_cases.dart' show WithSession;
import '_session_oracle.g.dart';

void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// The oracle's `Point`.
final class _Point {
  const _Point(this.x, this.y);

  final int x;
  final int y;
}

/// `Point` as the oracle's dataclass shows it: two fields, built from two
/// ints.
final HostClass<_Point> _pointClass = HostClass(
  'Point',
  isDataclass: true,
  instance: (
    fields: {'x': (p) => MontyInt(p.x), 'y': (p) => MontyInt(p.y)},
    properties: const {},
    methods: const {},
  ),
  construct: (args, kwargs) => switch (args) {
    [MontyInt(value: final x), MontyInt(value: final y)] => _Point(x, y),
    _ => throw const ExternalException('TypeError', 'Point(x, y)'),
  },
);

/// The oracle's `host_function`: its arguments, as `(args, kwargs)`.
MontyValue _hostFunction(List<MontyValue> args, Map<String, MontyValue> kw) =>
    MontyTuple([
      MontyTuple(args),
      MontyDict([for (final e in kw.entries) (MontyString(e.key), e.value)]),
    ]);

/// The oracle's `doubling`, a coroutine.
Future<MontyValue> _doubling(
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 10));

  return switch (args) {
    [MontyInt(:final value)] => MontyInt(value * 2),
    _ => throw const ExternalException('TypeError', 'doubling(x)'),
  };
}

MontyValue _value(Object? v) => switch (v) {
  null => const MontyNone(),
  final int i => MontyInt(i),
  final String s => MontyString(s),
  final List<Object?> l => MontyList([for (final x in l) _value(x)]),
  _ => throw ArgumentError.value(v, 'v', 'no MontyValue form'),
};

/// A list holding itself.
MontyValue _cyclic() {
  final items = <MontyValue>[];
  final list = MontyList(items);
  items.add(list);

  return list;
}

/// The generator's `KINDS`: one value per host type.
final Map<String, MontyValue> _kinds = {
  'big': MontyBigInt(BigInt.two.pow(100)),
  'bool': const MontyBool(true),
  'bytes': const MontyBytes([0x78]),
  'date': const MontyDate(year: 2020, month: 1, day: 2),
  'datetime': const MontyDateTime(
    year: 2020,
    month: 1,
    day: 2,
    hour: 3,
    minute: 4,
    second: 5,
  ),
  'dict': const MontyDict([(MontyInt(1), MontyInt(2))]),
  'ellipsis': const MontyEllipsis(),
  'exception': MontyExceptionValue('ValueError', 'x'),
  'exception_io': MontyExceptionValue('io.UnsupportedOperation', 'x'),
  'exception_json': MontyExceptionValue('json.JSONDecodeError', 'x'),
  'exception_re': MontyExceptionValue('re.PatternError', 'x'),
  'exception_binascii': MontyExceptionValue('binascii.Error', 'x'),
  'exception_incomplete': MontyExceptionValue('binascii.Incomplete', 'x'),
  'float': const MontyFloat(1.5),
  'frozenset': const MontyFrozenSet([MontyInt(1)]),
  'namedtuple': const MontyNamedTuple(
    typeName: 'Pt',
    fieldNames: ['x', 'y'],
    values: [MontyInt(1), MontyInt(2)],
  ),
  'notimplemented': const MontyNotImplemented(),
  'path': MontyPath('/a'),
  'set': const MontySet([MontyInt(1)]),
  'time': const MontyTime(hour: 1, minute: 2, second: 3, microsecond: 0),
  'timedelta': const MontyTimeDelta(days: 1, seconds: 0),
  'timezone': const MontyTimeZone(offsetSeconds: 0),
  'tuple': const MontyTuple([MontyInt(1)]),
};

MontyValue _entry(List<Object?> spec) => switch (spec) {
  ['v', final v] => _value(v),
  ['k', final String kind] => _kinds[kind]!,
  ['f'] => const MontyHostFunction('f', _hostFunction),
  ['c'] => MontyHostFunction('c', coroutine(_doubling)),
  ['cyclic'] => _cyclic(),
  ['I'] => ClassInstance(
    const _Point(1, 2),
    classType: ClassType(_pointClass),
    policies: (eagerAttrs: 'all', lazyAttrs: null, allowedMethods: null),
  ),
  ['T'] => ClassType(_pointClass, init: true),
  _ => throw ArgumentError.value(spec, 'spec', 'unknown entry'),
};

Map<String, MontyValue>? _built(Object? values) => switch (values) {
  null => null,
  final Map<String, Object?> m => {
    for (final MapEntry(:key, :value) in m.entries)
      if (!_isReturned(value))
        key: value is List<Object?> ? _entry(value) : _value(value),
  },
  _ => throw ArgumentError.value(values, 'values'),
};

/// Whether [spec] is a `['from', code]` entry, built by [_withReturned].
bool _isReturned(Object? spec) => switch (spec) {
  ['from', _] => true,
  _ => false,
};

/// [lookup] built, with each `['from', code]` entry the value [s] returns
/// for `code`, fed first, as the generator does.
Future<Map<String, MontyValue>?> _withReturned(
  MontySession s,
  Object? lookup,
) async {
  final built = _built(lookup);
  if (built == null || lookup is! Map<String, Object?>) return built;
  for (final MapEntry(:key, :value) in lookup.entries) {
    if (value case ['from', final String code]) {
      built[key] = await s.feedRun(code, printCallback: _ignore);
    }
  }

  return built;
}

/// [error] as the oracle shows upstream's: a refused `cwd` argument or
/// requirement is upstream's `UnicodeEncodeError`, raised as the binding
/// reads it.
String _errorText(Object error) => switch (error) {
  StateError(message: 'the session is finished') => 'finished',
  ArgumentError(name: 'cwd' || 'requirements', :final message) =>
    'UnicodeEncodeError: $message',
  MontyRuntimeError() => "MontyRuntimeError: ${error.display('type-msg')}",
  _ => '${error.runtimeType}: $error',
};

String _shown(MontyValue shown) => switch (shown) {
  MontyString(:final value) => 'value: $value',
  _ => 'nonstr: $shown',
};

Future<String> _step(MontySession s, List<Object?> step) async {
  final [op as String, code, lookup, cwd as String?, inputs] = step;
  if (code is List<Object?>) {
    await s.installDependencies([...code.cast<String>()]);

    return 'ok';
  }
  final source = code is String ? code : throw ArgumentError.value(code);
  final externalLookup = await _withReturned(s, lookup);
  if (op == 'run') {
    return _shown(
      await s.feedRun(
        source,
        inputs: _built(inputs),
        externalLookup: externalLookup,
        printCallback: _ignore,
        cwd: cwd,
      ),
    );
  }
  final passed = <String>[];
  try {
    var snap = await s.feedStart(
      source,
      inputs: _built(inputs),
      externalLookup: externalLookup,
      printCallback: _ignore,
      cwd: cwd,
    );
    for (;;) {
      switch (snap) {
        case MontyComplete(:final output):
          passed.add(_shown(output));

          return passed.join(' > ');
        case NameLookupSnapshot(:final variableName):
          passed.add('lookup:$variableName');
          snap = await snap.resumeAuto();
        case FunctionSnapshot(:final functionName):
          passed.add('call:$functionName');
          snap = await snap.resumeAuto();
        default:
          fail('unexpected snapshot $snap');
      }
    }
  } on Object catch (e) {
    if (e is TestFailure) rethrow;
    passed.add(_errorText(e));
  }

  return passed.join(' > ');
}

/// Every case of [sessionOracle], each in a fresh session from
/// [withSession], labelled with [label].
void sessionSurfaceTests(String label, WithSession withSession) {
  group('session surface: externalLookup, cwd ($label)', () {
    for (final MapEntry(key: id, value: steps) in sessionOracle.entries) {
      test(id, () async {
        await withSession((s) async {
          for (final (:step, :outcome) in steps) {
            String got;
            try {
              got = await _step(s, step);
            } on Object catch (e) {
              got = _errorText(e);
            }
            expect(got, outcome, reason: '$id: $step');
          }
        });
      });
    }

    test(
      'feedRun, feedStart and loadSnapshot take inputs and '
      'externalLookup as Map<String, MontyValue> (REQ MontySession-2); '
      'installDependencies takes the requirements as one positional list '
      '(upstream install_dependencies(requirements), TGT1 B)',
      () async {
        await withSession((s) async {
          expect(
            s.feedRun,
            isA<
              Future<MontyValue> Function(
                String code, {
                Map<String, MontyValue>? inputs,
                Map<String, MontyValue>? externalLookup,
                String? cwd,
                OsHandler? os,
                bool skipTypeCheck,
              })
            >(),
          );
          expect(
            s.feedStart,
            isA<
              Future<MontySnapshot> Function(
                String code, {
                Map<String, MontyValue>? inputs,
                Map<String, MontyValue>? externalLookup,
                String? cwd,
                OsHandler? os,
                bool skipTypeCheck,
              })
            >(),
          );
          expect(
            s.loadSnapshot,
            isA<
              Future<MontySnapshot> Function(
                Uint8List state, {
                Map<String, MontyValue>? externalLookup,
                OsHandler? os,
              })
            >(),
          );
          expect(
            s.installDependencies,
            isA<Future<void> Function(List<String> requirements)>(),
          );
          // Narrowed, not widened: an Object-valued map is a compile error.
          expect(
            s.feedRun,
            isNot(
              isA<
                Future<MontyValue> Function(
                  String code, {
                  Map<String, Object>? externalLookup,
                })
              >(),
            ),
          );
          expect(
            s.feedRun,
            isNot(
              isA<
                Future<MontyValue> Function(
                  String code, {
                  Map<String, Object>? inputs,
                })
              >(),
            ),
          );
          expect(
            s.feedStart,
            isNot(
              isA<
                Future<MontySnapshot> Function(
                  String code, {
                  Map<String, Object>? externalLookup,
                })
              >(),
            ),
          );
          expect(
            s.loadSnapshot,
            isNot(
              isA<
                Future<MontySnapshot> Function(
                  Uint8List state, {
                  Map<String, Object>? externalLookup,
                })
              >(),
            ),
          );
        });
      },
    );
  });
}

/// A call on a finished session (upstream: "this checkout has already been
/// finished").
final Matcher _finished = throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    'the session is finished',
  ),
);

/// Runs a body with a one-worker pool.
typedef WithPool = Future<void> Function(Future<void> Function(Monty pool));

/// The session-surface cases that need the pool, labelled with [label],
/// each on a one-worker pool from [withPool].
void sessionSurfacePoolTests(String label, WithPool withPool) {
  group('session surface: the pool ($label)', () {
    test('a refused lookup value finishes the session and frees its slot '
        '(upstream discards the checkout)', () async {
      await withPool((pool) async {
        final s = await pool.checkout();
        await expectLater(
          s.feedRun(
            'x',
            externalLookup: {'x': _cyclic()},
            printCallback: _ignore,
          ),
          throwsA(isA<MontyRuntimeError>()),
        );
        await expectLater(s.feedRun('1'), _finished);
        // The one worker's slot is free for the next checkout.
        final next = await pool.checkout(scriptName: 'next.py');
        expect(await next.feedRun('1 + 1'), const MontyInt(2));
        await next.close();
        await s.close();
      });
    });

    test('any failure converting a lookup value frees the slot, a '
        'crash-typed one from host code included', () async {
      await withPool((pool) async {
        final s = await pool.checkout();
        // An eager getter rethrowing a crash it captured elsewhere.
        final failing = HostClass<_Point>(
          'Point',
          instance: (
            fields: {
              'x': (_) => throw crashedError(CrashCause.killed, detail: 'x'),
            },
            properties: const {},
            methods: const {},
          ),
        );
        await expectLater(
          s.feedRun(
            'p',
            externalLookup: {
              'p': ClassInstance(
                const _Point(1, 2),
                classType: ClassType(failing),
                policies: (
                  eagerAttrs: 'all',
                  lazyAttrs: null,
                  allowedMethods: null,
                ),
              ),
            },
            printCallback: _ignore,
          ),
          throwsA(isA<MontyCrashedError>()),
        );
        await expectLater(s.feedRun('1'), _finished);
        final next = await pool.checkout(scriptName: 'next.py');
        expect(await next.feedRun('2'), const MontyInt(2));
        await next.close();
        await s.close();
      });
    });

    test('a lookup value the writer refuses with ArgumentError finishes the '
        'session too', () async {
      await withPool((pool) async {
        final s = await pool.checkout();
        await expectLater(
          s.feedRun(
            'try:\n    x\nexcept Exception:\n    pass',
            externalLookup: {'x': MontyExceptionValue('NoSuchError')},
            printCallback: _ignore,
          ),
          throwsArgumentError,
        );
        await expectLater(s.feedRun('1'), _finished);
        final next = await pool.checkout(scriptName: 'next.py');
        expect(await next.feedRun('4'), const MontyInt(4));
        await next.close();
        await s.close();
      });
    });

    // Measured on pydantic-monty 1.1.0: a pending lookup dumped and loaded
    // into a fresh checkout with external_lookup={'x': 41} resumes to 42;
    // with a cyclic value resume_auto() raises ValueError: Circular
    // reference detected, and the checkout is finished.
    Future<Uint8List> pendingLookup(Monty pool) async {
      final source = await pool.checkout(scriptName: 'source.py');
      final snap = await source.feedStart(
        'repr(x + 1)',
        printCallback: _ignore,
      );
      final dumped = await (snap as NameLookupSnapshot).dump();
      await source.close();

      return dumped;
    }

    test('loadSnapshot answers a restored lookup from its '
        'externalLookup', () async {
      await withPool((pool) async {
        final dumped = await pendingLookup(pool);
        final s = await pool.checkout();
        final snap = await s.loadSnapshot(
          dumped,
          externalLookup: {'x': const MontyInt(41)},
          printCallback: _ignore,
        );
        final done = await (snap as NameLookupSnapshot).resumeAuto();
        expect((done as MontyComplete).output, const MontyString('42'));
        await s.close();
      });
    });

    test('a refused value in a restored lookup finishes the session and '
        'frees its slot', () async {
      await withPool((pool) async {
        final dumped = await pendingLookup(pool);
        final s = await pool.checkout();
        final snap = await s.loadSnapshot(
          dumped,
          externalLookup: {'x': _cyclic()},
          printCallback: _ignore,
        );
        await expectLater(
          (snap as NameLookupSnapshot).resumeAuto(),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.display('type-msg'),
              'display',
              'ValueError: Circular reference detected',
            ),
          ),
        );
        await expectLater(s.feedRun('1'), _finished);
        final next = await pool.checkout(scriptName: 'next.py');
        expect(await next.feedRun('3'), const MontyInt(3));
        await next.close();
        await s.close();
      });
    });

    // The recorded divergence `builtin-type-call-by-name`. Upstream 1.1.0
    // decodes the proxy to the Python type and calls it on the host:
    // `p("42")` gives 42 there.
    test(
      'divergence builtin-type-call-by-name: a builtin type called by name '
      'from externalLookup raises TypeError (upstream runs the type on the '
      'host); read first, it runs in the sandbox',
      () async {
        await withPool((pool) async {
          final s = await pool.checkout();
          final type = await s.feedRun('int');
          expect(type, isA<MontyStdTypeProxy>());
          await expectLater(
            s.feedRun('p("42")', externalLookup: {'p': type}),
            throwsA(
              isA<MontyRuntimeError>()
                  .having((e) => e.exception.excType, 'excType', 'TypeError')
                  .having(
                    (e) => e.exception.message,
                    'message',
                    "builtin type 'int' cannot be called from externalLookup "
                        'by name; read the name first',
                  ),
            ),
          );
          expect(
            await s.feedRun('q = p\nq("42")', externalLookup: {'p': type}),
            const MontyInt(42),
          );
          await s.close();
        });
      },
    );

    test('a feed the type check rejects does not adopt its cwd '
        '(upstream: / then /a)', () async {
      await withPool((pool) async {
        final s = await pool.checkout(typeCheck: true);
        final rejected = throwsA(isA<MontyTypingError>());
        await expectLater(
          s.feedRun('x: int = "a"', cwd: '/q', printCallback: _ignore),
          rejected,
        );
        expect(
          await s.feedRun('import os\nos.getcwd()', printCallback: _ignore),
          const MontyString('/'),
        );
        // A directory a feed adopted is kept past a rejected one.
        await s.feedRun('1', cwd: '/a', printCallback: _ignore);
        await expectLater(
          s.feedRun('x: int = "b"', cwd: '/b', printCallback: _ignore),
          rejected,
        );
        expect(
          await s.feedRun('import os as o\no.getcwd()', printCallback: _ignore),
          const MontyString('/a'),
        );
        await s.close();
      });
    });
  });
}
