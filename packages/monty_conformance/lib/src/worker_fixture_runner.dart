// The upstream corpus on the worker: one session per fixture on a pool, each
// judged by the strict adjudicator against its own directives.
//
// It follows upstream's datatest runner (`crates/monty-datatest/src/main.rs`):
//
//   * a plain fixture is one `feed`;
//   * a `# call-external` or `# mount-fs` fixture is driven snapshot by
//     snapshot (`run_iter_loop`, `run_mount_fs_iter_loop`), answering host
//     calls from the registry in `worker_fixture_host.dart`;
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
import 'package:monty_conformance/src/worker_fixture_host.dart';

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

/// What a corpus run did: every fixture it ran, in order, and the reason for
/// each one that failed.
final class WorkerCorpusRun {
  /// Creates a [WorkerCorpusRun].
  const WorkerCorpusRun(this.executed, this.failures);

  /// The fixture files run, each once, in corpus order.
  final List<String> executed;

  /// Why each failing fixture failed, by file.
  final Map<String, String> failures;

  /// How many of [executed] passed.
  int get passed => executed.length - failures.length;
}

/// Runs one fixture; null when it met its expectation, else why not.
Future<String?> _runOne(Monty pool, String name, String source) async {
  final expectation = parseFixture(
    source,
    skipCallExternal: false,
    skipMountFs: false,
    skipRunAsync: false,
  )!;
  final mount = fixtureMountsFs(source);
  final iter = mount || fixtureIsCallExternal(source);
  final timezone = fixtureTimezone(source);

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
    );
  } on TimeoutException catch (e) {
    return 'no worker for the fixture: $e';
  }

  try {
    FixtureOutcome outcome;
    try {
      final value = iter
          ? await _drive(session, source, mount: mount)
          : await session.feedRun(source, printCallback: _discard);
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

void _discard(String stream, String text) {}

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
    return _repr(value, <Object>[]);
  } on _Unsupported {
    return null;
  }
}

final class _Unsupported implements Exception {
  const _Unsupported();
}

String _repr(MontyValue v, List<Object> open) {
  switch (v) {
    case MontyNone():
      return 'None';
    case MontyBool(:final value):
      return value ? 'True' : 'False';
    case MontyInt(:final value):
      return '$value';
    case MontyBigInt(:final value):
      return '$value';
    case MontyFloat(:final value):
      if (value.isNaN) return 'nan';
      if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
      // dart2js has one number type, so a whole float prints without its
      // `.0`: spell it as Python does.
      if (value == 0) return value.isNegative ? '-0.0' : '0.0';
      if (value.abs() < 1e15 && value == value.truncateToDouble()) {
        return '${value.toInt()}.0';
      }
      final text = '$value';
      if (text.contains('e')) throw const _Unsupported();

      return text;
    case MontyString(:final value):
      return pyStringRepr(value);
    case MontyList(:final items):
      if (open.any((o) => identical(o, v))) return '[...]';
      open.add(v);
      final text = '[${items.map((i) => _repr(i, open)).join(', ')}]';
      open.removeLast();

      return text;
    case MontyTuple(:final items):
      if (open.any((o) => identical(o, v))) throw const _Unsupported();
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
      throw const _Unsupported();
  }
}

/// `run_iter_loop` and `run_mount_fs_iter_loop`: answers each suspension from
/// the host registry until the run completes (or raises).
Future<MontyValue> _drive(
  MontySession session,
  String source, {
  required bool mount,
}) async {
  final registry = WorkerFixtureRegistry();
  final os = mount ? WorkerFixtureOs.mounted() : WorkerFixtureOs.virtual();
  final pending = <int, HostOutcome>{};

  if (mount) {
    // `exec.set_cwd("/mnt")`: the sandbox starts in the first mount.
    await session.feedRun(
      'import os\nos.chdir("/mnt")',
      os: os.call,
      printCallback: _discard,
    );
  }

  var snapshot = await session.feedStart(
    source,
    externalLookup: mount
        ? null
        : {
            for (final name in workerFixtureFunctions)
              name: (args, kwargs) => throw StateError('answered by $name'),
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
        if (mount) {
          throw StateError('unexpected FunctionCall: ${call.functionName}');
        }
        switch (registry.call(call.functionName, call.args, call.kwargs)) {
          case HostPending(:final settled):
            pending[call.callId] = settled;
            snapshot = await call.resume(const ExternalFuture());
          case final HostOutcome outcome:
            snapshot = await call.resume(_answer(outcome));
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
        if (mount) {
          snapshot = await lookup.resume(
            value: variableName == 'root' ? MontyPath('/mnt') : null,
          );
        } else if (workerFixtureFunctions.contains(variableName)) {
          snapshot = await lookup.resumeAuto();
        } else {
          snapshot = await lookup.resume(
            value: workerFixtureConstants[variableName],
          );
        }
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
