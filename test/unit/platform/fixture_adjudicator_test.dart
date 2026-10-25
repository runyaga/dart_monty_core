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

  // Upstream's `Path.scan` — the one OS call behind `os.scandir`, `os.walk`,
  // `Path.walk` and `Path.glob` — as the fixture host must answer it.
  //
  // WHERE THE EXPECTED VALUES COME FROM: upstream's scan contract at monty
  // v1.2.0 (crates/monty-types/src/scan.rs, crates/monty-fs/tests/scan.rs,
  // crates/monty-datatest/src/main.rs:1131). The reply is a sequence of
  // (path, is_dir, is_file, is_symlink) entries whose paths are relative to
  // the root, '' being the root itself; a root that is not there is a
  // FileNotFoundError naming it, spelled as the root was spelled.
  //
  // The fixture host has no scan handler yet, so the call is declined. The
  // stub below answers a declined call with a wrong value rather than
  // letting the decline escape, so this test fails on its first assertion
  // instead of on an exception; once the handler lands, the same call
  // reaches it.
  test(
    'WorkerFixtureOs scans reachable trees and preserves root errors',
    () async {
      /// The five keywords upstream's scan takes, all of them on every call: a
      /// handler that reads them all must find them all.
      Map<String, MontyValue> keywords({
        MontyValue maxDepth = const MontyNone(),
        bool followSymlinks = false,
        MontyValue pattern = const MontyNone(),
        bool caseSensitive = true,
        bool recurseSymlinks = false,
      }) => {
        'max_depth': maxDepth,
        'follow_symlinks': MontyBool(followSymlinks),
        'pattern': pattern,
        'case_sensitive': MontyBool(caseSensitive),
        'recurse_symlinks': MontyBool(recurseSymlinks),
      };

      /// The scan call the worker makes: the root as a `MontyPath`, the five
      /// keywords upstream's `ScanArgs` takes as kwargs.
      ///
      /// The stub: a call the fixture host has no handler for is declined, and
      /// a declined call would fail this test with an exception rather than
      /// with an assertion. So the decline is answered with a wrong value — an
      /// empty reply, where the tree is not empty.
      Future<MontyValue> scan(
        WorkerFixtureOs fixture,
        String root, {
        Map<String, MontyValue> kwargs = const {},
      }) async {
        try {
          return await fixture.call(
            'Path.scan',
            [MontyPath(root)],
            {
              ...keywords(),
              ...kwargs,
            },
          );
        } on OsCallNotHandledException {
          return const MontyList([]);
        }
      }

      /// One of an entry's flags: a boolean, strictly.
      bool boolFlag(MontyValue flagValue, String name) => switch (flagValue) {
        MontyBool(:final value) => value,
        final other => fail(
          'the $name of a scan entry is a boolean, got $other',
        ),
      };

      /// One scan entry, read as upstream encodes it: the path relative to the
      /// root, and what the entry is.
      (String, bool, bool, bool) entry(List<MontyValue> parts) =>
          switch (parts) {
            [final path, final isDir, final isFile, final isSymlink] => (
              switch (path) {
                MontyString(:final value) => value,
                final other => fail(
                  'the path of a scan entry is a string, got $other',
                ),
              },
              boolFlag(isDir, 'is_dir'),
              boolFlag(isFile, 'is_file'),
              boolFlag(isSymlink, 'is_symlink'),
            ),
            final other => fail(
              'a scan entry is (path, is_dir, is_file, is_symlink), got $other',
            ),
          };

      /// The entries of a tree reply.
      List<(String, bool, bool, bool)> entries(MontyValue reply) {
        final replyItems = switch (reply) {
          MontyList(:final items) || MontySet(:final items) => items,
          final other => fail(
            'a scan reply is a sequence of entries, got $other',
          ),
        };

        return [
          for (final item in replyItems)
            switch (item) {
              MontyTuple(:final items) ||
              MontyList(:final items) => entry(items),
              MontyNamedTuple(:final values) => entry(values),
              final other => fail('a scan entry is a tuple, got $other'),
            },
        ];
      }

      /// The paths a reply names: a tree reply names them in its entries, a
      /// glob reply in its matches.
      List<String> paths(MontyValue reply) => switch (reply) {
        MontyDict(:final pairs) => [
          for (final (_, matchList) in pairs)
            if (matchList is MontyList)
              for (final match in matchList.items)
                switch (match) {
                  MontyString(:final value) => value,
                  final other => fail('a glob match is a path, got $other'),
                },
        ],
        _ => [for (final scanned in entries(reply)) scanned.$1],
      };

      // The two trees the fixture host serves: upstream's `/virtual` and the
      // `/mnt` mount. Both have the same shape — four files, and a `subdir`
      // with a file and a `deep` directory holding a file.
      final trees = [
        (root: '/virtual', file: 'file.txt', mounted: false),
        (root: '/mnt', file: 'hello.txt', mounted: true),
      ];

      // The exception a root that is not there raises.
      final fileNotFound = isA<ExternalException>().having(
        (error) => error.excType,
        'excType',
        'FileNotFoundError',
      );

      for (final tree in trees) {
        final root = tree.root;
        final fixture = tree.mounted
            ? WorkerFixtureOs.mounted()
            : WorkerFixtureOs.virtual();

        /// The entries of a scan, sorted by path: the order the reply comes in
        /// is not part of the contract, the entries are.
        Future<List<(String, bool, bool, bool)>> scanned(
          WorkerFixtureOs host,
          String scanRoot, {
          MontyValue maxDepth = const MontyNone(),
          bool followSymlinks = false,
        }) async {
          final reply = await scan(
            host,
            scanRoot,
            kwargs: keywords(
              maxDepth: maxDepth,
              followSymlinks: followSymlinks,
            ),
          );

          return [...entries(reply)]
            ..sort((left, right) => left.$1.compareTo(right.$1));
        }

        void expectEntries(
          String scanRoot,
          List<(String, bool, bool, bool)> actual,
          List<(String, bool, bool, bool)> expected,
        ) => expect(
          actual,
          equals(
            [...expected]..sort((left, right) => left.$1.compareTo(right.$1)),
          ),
          reason: 'the entries the scan of $scanRoot reports',
        );

        // The tree under the root, as upstream reports it: the root itself
        // (the empty path) and every entry below it, relative to the root.
        const rootEntry = ('', true, false, false);
        final files = [
          ('data.bin', false, true, false),
          ('empty.txt', false, true, false),
          (tree.file, false, true, false),
          ('readonly.txt', false, true, false),
        ];
        final children = [...files, ('subdir', true, false, false)];
        const grandchildren = [
          ('subdir/deep', true, false, false),
          ('subdir/nested.txt', false, true, false),
        ];
        const greatGrandchildren = [
          ('subdir/deep/file.txt', false, true, false),
        ];

        // The whole tree, when no depth is asked for.
        expectEntries(
          root,
          await scanned(fixture, root),
          [
            rootEntry,
            ...children,
            ...grandchildren,
            ...greatGrandchildren,
          ],
        );

        // A depth is the depth of the deepest entry: 0 is the root alone, 1
        // its children, 2 their children.
        expectEntries(
          root,
          await scanned(fixture, root, maxDepth: const MontyInt(0)),
          [rootEntry],
        );
        expectEntries(
          root,
          await scanned(fixture, root, maxDepth: const MontyInt(1)),
          [rootEntry, ...children],
        );
        expectEntries(
          root,
          await scanned(fixture, root, maxDepth: const MontyInt(2)),
          [rootEntry, ...children, ...grandchildren],
        );

        // Both values of `follow_symlinks`: the tree has no symlink, so both
        // report the same tree.
        for (final follow in [false, true]) {
          expectEntries(
            root,
            await scanned(fixture, root, followSymlinks: follow),
            [
              rootEntry,
              ...children,
              ...grandchildren,
              ...greatGrandchildren,
            ],
          );
        }

        // A file is described, not listed: the root of the scan is the file
        // itself.
        expectEntries(
          '$root/${tree.file}',
          await scanned(fixture, '$root/${tree.file}'),
          [('', false, true, false)],
        );

        // A newly created empty directory is a root of its own, and its tree
        // is the root alone. A fixture of its own, so the new directory does
        // not change the tree the scans above see.
        final fresh = tree.mounted
            ? WorkerFixtureOs.mounted()
            : WorkerFixtureOs.virtual();
        await fresh.call('Path.mkdir', [MontyPath('$root/fresh')], const {});
        expectEntries(
          '$root/fresh',
          await scanned(fresh, '$root/fresh'),
          [rootEntry],
        );

        // The descendants of a directory that is not there cannot be reached,
        // so the scan does not report them. The subtree is moved under a
        // directory that does not exist: the mounted tree takes its
        // descendants along, the virtual tree leaves them where they are,
        // and neither is reachable from the root any more.
        final moved = tree.mounted
            ? WorkerFixtureOs.mounted()
            : WorkerFixtureOs.virtual();
        await moved.call(
          'Path.rename',
          [MontyPath('$root/subdir'), MontyPath('$root/ghost/subdir')],
          const {},
        );
        expectEntries(
          root,
          await scanned(moved, root),
          [rootEntry, ...files],
        );

        // A root that is not there is a FileNotFoundError naming it, spelled
        // as the root was spelled.
        await expectLater(
          () => scan(fixture, '$root/nope'),
          throwsA(
            fileNotFound.having(
              (error) => error.message,
              'message',
              "[Errno 2] No such file or directory: '$root/nope'",
            ),
          ),
        );

        // The empty root is spelled '.' by the path it arrives as — the
        // spelling it has before the root is normalized — and it is not
        // there either.
        await expectLater(
          () => scan(fixture, ''),
          throwsA(
            fileNotFound.having(
              (error) => error.message,
              'message',
              "[Errno 2] No such file or directory: '.'",
            ),
          ),
        );

        // All five keywords at once, a pattern among them: a pattern is a
        // pruning hint, so the reply must at least name what it matches.
        final globbed = await scan(
          fixture,
          root,
          kwargs: keywords(
            followSymlinks: true,
            pattern: const MontyList([MontyString('*.txt')]),
            recurseSymlinks: true,
          ),
        );
        expect(paths(globbed), contains('empty.txt'));
      }
    },
  );
}
