// The upstream corpus on the worker: one session per fixture on a pool, each
// judged by the strict adjudicator against its own directives.
//
// It follows upstream's datatest runner (`crates/monty-datatest/src/main.rs`):
//
//   * a plain fixture is one `feed`;
//   * a `# call-external` fixture is driven snapshot by snapshot, answering
//     host calls from the registry in `worker_fixture_host.dart`;
//   * a `# mount-fs` fixture gets the upstream directory tree at `/mnt` and
//     the `root` binding, served by a native MountDir on the VM;
//   * every fixture runs under a recursion limit of 50
//     (`TEST_RECURSION_LIMIT`), with `# gc-interval=` and `# timezone=` as
//     its directives say.
//
// A fixture is never skipped. Each one reports a pass or a failure with its
// reason; the caller compares the failing set with its manifest.
//
import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/src/fixture_adjudicator.dart';
import 'package:monty_conformance/src/fixture_corpus_v1.dart';
import 'package:monty_conformance/src/fixture_parser.dart';
import 'package:monty_conformance/src/worker_corpus_run.dart';
import 'package:monty_conformance/src/worker_fixture_host.dart';
import 'package:monty_conformance/src/worker_fixture_mount_web.dart'
    if (dart.library.io) 'package:monty_conformance/src/worker_fixture_mount_io.dart';

/// Upstream's `TEST_RECURSION_LIMIT`, applied to every fixture.
const int workerFixtureRecursionLimit = 50;

/// The memory bound every fixture's session runs under. Upstream sets none;
/// this repository bounds every worker it starts.
const int workerFixtureMaxMemory = 256 * 1024 * 1024;

/// Runs [corpus] (the pinned upstream corpus by default) on [pool], one
/// session per fixture, and logs each outcome as the standalone runner does:
///
///     FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
///     FIXTURE_RESULT:{"name":"<file>","ok":false,"reason":"<msg>"}
///     FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>}
///
/// Returns what ran and what failed. [only] restricts the run to the named
/// files (a debugging aid; the gate runs them all).
Future<WorkerCorpusRun> runWorkerFixtureCorpus({
  required Monty pool,
  required void Function(String) log,
  Map<String, String>? corpus,
  Set<String>? only,
}) async {
  final fixtures = corpus ?? fixtureCorpusV1;
  final failures = <String, String>{};
  final executed = <String>[];
  var passed = 0;

  for (final MapEntry(:key, :value) in fixtures.entries) {
    if (only != null && !only.contains(key)) continue;
    executed.add(key);
    String? reason;
    try {
      reason = await _runOne(pool, key, value);
    } on Object catch (e) {
      // A harness fault is a failure too, never a skip.
      reason = 'harness error: $e';
    }
    if (reason == null) {
      passed++;
      log('FIXTURE_RESULT:{"name":"$key","ok":true}');
    } else {
      failures[key] = reason;
      log(
        'FIXTURE_RESULT:{"name":"$key","ok":false,'
        '"reason":${jsonEncode(reason)}}',
      );
    }
  }
  log(
    'FIXTURE_DONE:{"total":${executed.length},"passed":$passed,'
    '"failed":${failures.length}}',
  );

  return WorkerCorpusRun(executed, failures);
}

/// Runs one fixture; null when it met its expectation, else why not.
Future<String?> _runOne(Monty pool, String name, String source) async {
  final expectation =
      parseFixture(
        source,
        skipCallExternal: false,
        skipMountFs: false,
        skipRunAsync: false,
      ) ??
      (throw StateError('fixture must be adjudicated: $name'));
  final mount = fixtureMountsFs(source);
  final iter = fixtureIsCallExternal(source);
  final timezone = fixtureTimezone(source);
  // One registry per fixture, as upstream resets its fixtures per test, and
  // the host module that answers `import tools`.
  final registry = WorkerFixtureRegistry();
  final tools = WorkerFixtureTools(registry);

  final MontySession session;
  try {
    session = await pool.checkout(
      scriptName: name,
      limits: ResourceLimits(
        maxMemory: workerFixtureMaxMemory,
        maxRecursionDepth: workerFixtureRecursionLimit,
        gcInterval: fixtureGcInterval(source),
      ),
      osPolicy: timezone == null ? null : OsPolicy(timezone: timezone),
      externalModules: {'tools': tools.module},
    );
  } on TimeoutException catch (e) {
    return 'no worker for the fixture: $e';
  }

  try {
    FixtureOutcome outcome;
    try {
      final value = await switch ((mount, iter)) {
        (true, _) => runMountFixture(session, source),
        (false, true) => _drive(session, source, registry, tools),
        (false, false) => session.feedRun(source, printCallback: _discard),
      };
      outcome = FixtureOutcome(value: value, valueRepr: pyValueRepr(value));
    } on MontyCrashedError catch (e) {
      return 'the worker crashed: $e';
    } on MontyError catch (e) {
      outcome = FixtureOutcome(
        excType: e.exception.excType,
        message: e.exception.message,
        renderedTraceback: switch (e) {
          final MontyRuntimeError r => _named(r.display(), name),
          final MontySyntaxError s => _named(s.display(), name),
          _ => null,
        },
      );
    }

    return adjudicateFixture(expectation, outcome);
  } finally {
    await session.close();
  }
}

// Corpus directives adjudicate outcomes, not printed output.
void _discard(String stream, String text) {
  return;
}

/// [traceback] with each fed snippet's frame file named [name].
///
/// A worker names the code of a feed `<python-input-N>` in its frames, where
/// upstream's datatest compiles the fixture under its own file name and the
/// fixtures state that name. The frame's line, function and source text are
/// untouched.
String _named(String traceback, String name) =>
    traceback.replaceAll(RegExp(r'File "<python-input-\d+>"'), 'File "$name"');

/// CPython's `repr()` of [value] for the kinds a `# Return=` directive can
/// name (None, bool, int, float, str, list, tuple, dict), cycles as `[...]`
/// and `{...}`; null for a value with any other kind in it, which is then
/// compared by value instead.
String? pyValueRepr(MontyValue value) {
  try {
    return _repr(value, []);
  } on FormatException {
    return null;
  }
}

String _repr(MontyValue v, List<Object> open) {
  switch (v) {
    case MontyNone():
      return 'None';
    case MontyBool(:final value):
      return value ? 'True' : 'False';
    case MontyInt(:final Object value) || MontyBigInt(:final Object value):
      return '$value';
    case MontyFloat(:final value):
      if (value.isNaN) return 'nan';
      if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
      // dart2js has one number type, so a whole float prints without its
      // `.0`; outside [1e-4, 1e16) a value has no Python repr.
      if (value == 0) return value.isNegative ? '-0.0' : '0.0';
      final magnitude = value.abs();
      if (magnitude < 1e-4 || magnitude >= 1e16) {
        throw const FormatException('value has no supported Python repr');
      }
      if (value == value.truncateToDouble()) {
        return '${value.toInt()}.0';
      }

      return '$value';
    case MontyString(:final value):
      return pyStringRepr(value);
    case MontyList(:final items):
      if (open.any((o) => identical(o, v))) return '[...]';
      open.add(v);
      final text = '[${items.map((i) => _repr(i, open)).join(', ')}]';
      open.removeLast();

      return text;
    case MontyTuple(:final items):
      if (open.any((o) => identical(o, v))) {
        throw const FormatException('value has no supported Python repr');
      }
      open.add(v);
      final inner = items.map((i) => _repr(i, open)).join(', ');
      open.removeLast();

      return items.length == 1 ? '($inner,)' : '($inner)';
    case MontyDict(:final pairs):
      if (open.any((o) => identical(o, v))) return '{...}';
      open.add(v);
      final entries = [
        for (final (key, item) in pairs)
          '${_repr(key, open)}: ${_repr(item, open)}',
      ];
      open.removeLast();

      return '{${entries.join(', ')}}';
    default:
      throw const FormatException('value has no supported Python repr');
  }
}

/// `run_iter_loop`: answers each suspension from
/// the host registry until the run completes (or raises).
Future<MontyValue> _drive(
  MontySession session,
  String source,
  WorkerFixtureRegistry registry,
  WorkerFixtureTools tools,
) async {
  final os = WorkerFixtureOs.virtual();
  final pending = <int, HostOutcome>{};

  var snapshot = await session.feedStart(
    source,
    externalLookup: {
      for (final name in workerFixtureFunctions)
        name: MontyHostFunction(
          name,
          (args, kwargs) => throw StateError('answered by $name'),
        ),
    },
    os: os.call,
    printCallback: _discard,
  );

  while (true) {
    switch (snapshot) {
      case MontyComplete(:final output):
        return output;

      case FunctionSnapshot(isOsFunction: true) && final call:
        snapshot = await call.resumeAuto();

      case FunctionSnapshot(:final objectId?) && final call:
        snapshot = await call.resume(
          _answer(
            registry.method(
              call.functionName,
              objectId,
              call.args,
              call.kwargs,
            ),
          ),
        );

      case FunctionSnapshot() && final call:
        final outcome = _outcome(
          registry,
          tools,
          call.functionName,
          call.args,
          call.kwargs,
        );
        switch (outcome) {
          case HostPending(:final settled):
            pending[call.callId] = settled;
            snapshot = await call.resume(const ExternalFuture());
          case final result:
            snapshot = await call.resume(_answer(result));
        }

      case FutureSnapshot(:final pendingCallIds) && final wait:
        final results = <int, ExternalSettledResult>{
          for (final id in pendingCallIds)
            if (pending.remove(id) case final settled?)
              id: _answer(settled) as ExternalSettledResult,
        };
        // Calls the harness did not start (an `asyncio.sleep`) are the
        // session's own host coroutines: it waits for those.
        snapshot = results.isEmpty
            ? await wait.resumeAuto()
            : await wait.resume(results);

      // A lazy attribute of a host object: the session answers it through
      // the instance's wrapper, a raising property included.
      case NameLookupSnapshot(objectId: _?) && final lookup:
        snapshot = await lookup.resumeAuto();

      case NameLookupSnapshot(:final variableName) && final lookup:
        snapshot = workerFixtureFunctions.contains(variableName)
            ? await lookup.resumeAuto()
            : await lookup.resume(value: workerFixtureConstants[variableName]);
    }
  }
}

ExternalResult _answer(HostOutcome outcome) => switch (outcome) {
  HostReturn(:final value) => ExternalReturnValue(value),
  HostRaise(:final excType, :final message) => ExternalException(
    excType,
    message,
  ),
  HostPending() => throw StateError('a pending answer is not settled'),
};

/// The outcome of the call [name] makes: the tool the host module holds for
/// a qualified name, the registry's own for a bare one.
///
/// A qualified name is the module's own path and the function's name, as
/// the sandbox calls it (`tools.add_ints`, `tools.nested.return_value`). A
/// dotted name the module does not hold names nothing: the lookup is never
/// consulted for a dotted name, so the call is not found — a `NameError`,
/// as upstream's not-found answer raises.
HostOutcome _outcome(
  WorkerFixtureRegistry registry,
  WorkerFixtureTools tools,
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  final tool = tools.toolNamed(name);
  if (tool != null) return registry.call(tool, args, kwargs);
  if (name.contains('.')) {
    return HostRaise('NameError', "name '$name' is not defined");
  }

  return registry.call(name, args, kwargs);
}
