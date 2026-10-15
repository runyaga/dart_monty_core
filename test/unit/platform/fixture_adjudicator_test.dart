// The strict fixture adjudicator (S7): message + frames, strict xfail,
// unknown directives fail.
//
// WHERE THE EXPECTED VALUES COME FROM: upstream's own fixture text, verbatim
// (the embedded corpus is a copy of the pinned upstream `test_cases/`), and
// the rules in upstream's `crates/monty-datatest/src/main.rs`. The frames fed
// in are what upstream reports for that source — line and column read off
// the fixture by hand — not anything produced by this package's encoder.
//
// Pure Dart, so it runs on the VM, dart2js and dart2wasm (gate steps
// unit_tests and unit_web).
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:monty_conformance/worker_conformance.dart';
import 'package:test/test.dart';

FixtureOutcome _raised(
  String excType,
  String message, [
  List<FixtureFrame> frames = const [],
]) => FixtureOutcome(excType: excType, message: message, traceback: frames);

FixtureExpectation _parse(String source) {
  final e = parseFixture(
    source,
    skipCallExternal: false,
    skipMountFs: false,
    skipRunAsync: false,
  );
  if (e == null) fail('parseFixture skipped a fixture it was told not to');

  return e;
}

void main() {
  group('# Raise= is matched on type AND message', () {
    // ext_call__exc.py-style directive; upstream compares `py_repr()`.
    final expectation = _parse(
      "raise ValueError('bad')\n# Raise=ValueError('bad')",
    );

    test('the stated exception passes', () {
      expect(
        adjudicateFixture(expectation, _raised('ValueError', 'bad')),
        isNull,
      );
    });

    test('the right type with the WRONG message fails', () {
      expect(
        adjudicateFixture(expectation, _raised('ValueError', 'other')),
        contains("expected ValueError('bad'), got ValueError('other')"),
      );
    });

    test('a message carrying a "Type: " prefix fails', () {
      expect(
        adjudicateFixture(
          expectation,
          _raised('ValueError', 'ValueError: bad'),
        ),
        isNotNull,
      );
    });

    test('quotes are chosen and escaped as CPython repr does', () {
      // Both directives are verbatim from upstream's corpus.
      expect(
        adjudicateFixture(
          _parse("x\n# Raise=TypeError(\"hello 'there'\")"),
          _raised('TypeError', "hello 'there'"),
        ),
        isNull,
      );
      expect(
        adjudicateFixture(
          _parse(
            'x\n'
            "# Raise=TypeError('can only concatenate list (not \"int\") to "
            "list')",
          ),
          _raised('TypeError', 'can only concatenate list (not "int") to list'),
        ),
        isNull,
      );
    });

    test('no message renders as `Type()`, as upstream does for None', () {
      final e = _parse('assert False\n# Raise=AssertionError()');
      expect(adjudicateFixture(e, _raised('AssertionError', '')), isNull);
      expect(
        adjudicateFixture(e, _raised('AssertionError', '[object Object]')),
        isNotNull,
      );
    });

    test('no exception at all fails', () {
      expect(adjudicateFixture(expectation, const FixtureOutcome()), isNotNull);
    });
  });

  group('a TRACEBACK docstring is matched frame by frame', () {
    // builtin__next_stop_iteration.py, verbatim from the corpus.
    final source = fixtureCorpusV1['builtin__next_stop_iteration.py']!;
    final expectation = _parse(source);
    const frame = FixtureFrame(
      filename: 'builtin__next_stop_iteration.py',
      startLine: 2,
      startColumn: 1,
      endLine: 2,
      endColumn: 9,
      previewLine: 'next(it)',
    );

    test('the stated frames and final line pass', () {
      expect(
        adjudicateFixture(expectation, _raised('StopIteration', '', [frame])),
        isNull,
      );
    });

    test('the right exception from the WRONG line fails', () {
      const moved = FixtureFrame(
        filename: 'builtin__next_stop_iteration.py',
        startLine: 3,
        startColumn: 1,
        endLine: 3,
        endColumn: 9,
        previewLine: 'next(it)',
      );
      expect(
        adjudicateFixture(expectation, _raised('StopIteration', '', [moved])),
        contains('traceback mismatch'),
      );
    });

    test('no frames at all fails', () {
      expect(
        adjudicateFixture(expectation, _raised('StopIteration', '')),
        isNotNull,
      );
    });

    test('identical frames collapse after three, as CPython prints them', () {
      // traceback__recursion_error.py: 1 module frame + 50 recurse frames at
      // upstream's TEST_RECURSION_LIMIT, printed as 3 + "repeated 47".
      final recursion = _parse(
        fixtureCorpusV1['traceback__recursion_error.py'] ?? '',
      );
      const module = FixtureFrame(
        filename: 'traceback__recursion_error.py',
        startLine: 5,
        startColumn: 1,
        endLine: 5,
        endColumn: 10,
        previewLine: 'recurse()',
      );
      const recurse = FixtureFrame(
        filename: 'traceback__recursion_error.py',
        startLine: 2,
        startColumn: 5,
        endLine: 2,
        endColumn: 14,
        frameName: 'recurse',
        previewLine: '    recurse()',
      );
      FixtureOutcome depth(int n) => _raised(
        'RecursionError',
        'maximum recursion depth exceeded',
        [module, for (var i = 0; i < n; i++) recurse],
      );
      expect(adjudicateFixture(recursion, depth(50)), isNull);
      expect(adjudicateFixture(recursion, depth(512)), isNotNull);
    });
  });

  group('xfail=monty is strict', () {
    // type_error__list_iadd_int.py: upstream declares monty expected to fail.
    final source = fixtureCorpusV1['type_error__list_iadd_int.py']!;

    test('the fixture is RUN, not skipped', () {
      expect(parseFixture(source), isA<ExpectXfail>());
    });

    test('meeting the expectation is a failure', () {
      final xfail = _parse(source) as ExpectXfail;
      final inner = xfail.expected as ExpectRaise;
      expect(
        adjudicateFixture(xfail, _raised(inner.excType, inner.message)),
        contains('xfail=monty fixture PASSED'),
      );
    });

    test('failing the expectation is the expected outcome', () {
      expect(adjudicateFixture(_parse(source), const FixtureOutcome()), isNull);
    });
  });

  group('an unknown or misplaced directive fails the fixture', () {
    void malformed(String source) {
      final e = parseFixture(source);
      if (e is! MalformedFixture) fail('not malformed: $source');
      expect(adjudicateFixture(e, const FixtureOutcome()), isNotNull);
    }

    test('a typo in an expectation key', () {
      malformed("raise ValueError('x')\n# Raises=ValueError('x')");
    });
    test('a typo in a header directive', () {
      malformed('# call-externals\nx = 1');
    });
    test('an xfail target upstream does not have', () {
      malformed('# xfail=wasm\nx = 1');
    });
    test('an expectation that is not on the last line', () {
      malformed("# Raise=ValueError('x')\nraise ValueError('x')");
    });
    test('upstream vocabulary this adjudicator does not implement', () {
      malformed('1\n# Return.type=int');
    });
    test('a skipped mode does not hide it', () {
      // Without skip flags turned off, call-external would return null.
      malformed('# call-external\nx = 1\n# Rise=ValueError()');
    });
    test('prose comments are not directives', () {
      // Verbatim shapes from the corpus: list__ops.py, ext_call__for.py,
      // collections__namedtuple.py.
      expect(
        parseFixture(
          'x = 1\n# key=None is same as no key\n# membership\ny = 2',
        ),
        isA<ExpectNoException>(),
      );
    });
  });

  test('every fixture in the pinned corpus parses, and one is xfail', () {
    final malformed = <String, String>{};
    var xfail = 0;
    for (final MapEntry(:key, :value) in fixtureCorpusV1.entries) {
      switch (_parse(value)) {
        case MalformedFixture(:final reason):
          malformed[key] = reason;
        case ExpectXfail():
          xfail++;
        default:
      }
    }
    expect(malformed, isEmpty);
    expect(xfail, 1);
  });

  test('# Return.str= compares str() of the result', () {
    final e = _parse(fixtureCorpusV1['refcount__cycle_deep.py']!);
    expect(e, isA<ExpectReturnStr>());
    expect(
      adjudicateFixture(e, const FixtureOutcome(value: MontyString('done'))),
      isNull,
    );
    expect(
      adjudicateFixture(e, const FixtureOutcome(value: MontyString('nope'))),
      isNotNull,
    );
  });

  group('what a worker engine adds', () {
    test('# timezone= and # gc-interval= are known directives, read to the '
        'first space', () {
      const source =
          '# timezone=Europe/London  local time\n'
          '# gc-interval=100  recursive test\n'
          'x = 1\n';
      expect(_parse(source), isA<ExpectNoException>());
      expect(fixtureTimezone(source), 'Europe/London');
      expect(fixtureGcInterval(source), 100);
      expect(fixtureTimezone('x = 1\n'), isNull);
      expect(fixtureGcInterval('x = 1\n'), isNull);
    });

    test('# Return= is compared by repr when the backend renders one', () {
      final e = _parse('x = [1]\nx.append(x)\nx\n# Return=[1, [...]]');
      expect(e, isA<ExpectReturn>());
      expect(
        adjudicateFixture(e, const FixtureOutcome(valueRepr: '[1, [...]]')),
        isNull,
      );
      expect(
        adjudicateFixture(e, const FixtureOutcome(valueRepr: "[1, '[...]']")),
        contains('repr mismatch'),
      );
    });

    test('a traceback the backend rendered is compared as it is', () {
      final e = _parse(
        'x\n"""\nTRACEBACK:\n'
        'Traceback (most recent call last):\n'
        '  File "t.py", line 1, in <module>\n'
        '    x\n'
        '    ~\n'
        "NameError: name 'x' is not defined\n"
        '"""\n',
      );
      const rendered =
          'Traceback (most recent call last):\n'
          '  File "t.py", line 1, in <module>\n'
          '    x\n'
          '    ~\n'
          "NameError: name 'x' is not defined";
      expect(
        adjudicateFixture(
          e,
          const FixtureOutcome(
            excType: 'NameError',
            message: "name 'x' is not defined",
            renderedTraceback: rendered,
          ),
        ),
        isNull,
      );
      expect(
        adjudicateFixture(
          e,
          const FixtureOutcome(
            excType: 'NameError',
            message: "name 'x' is not defined",
            renderedTraceback: 'NameError',
          ),
        ),
        contains('traceback mismatch'),
      );
    });
  });
}
