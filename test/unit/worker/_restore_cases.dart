// Dumps and loads against upstream's outcomes: each case of
// _restore_oracle.g.dart (pydantic-monty 1.1.0) run step by step on a real
// pool, every step's outcome in the oracle's form. Shared by the VM harness
// (test/integration/worker/pool_session_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_restore_oracle.g.dart';

/// Starts a pool with [options].
typedef StartPool = Future<MontyPool> Function(PoolOptions options);

void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// A directory's stat result: `os.chdir` reads only `st_mode`.
const MontyValue _dirStat = MontyNamedTuple(
  typeName: 'os.stat_result',
  fieldNames: ['st_mode'],
  values: [MontyInt(0x41ed)], // S_IFDIR | 0o755
);

Duration _seconds(Object value) =>
    Duration(microseconds: ((value as num) * 1000000).round());

/// The pool settings a case names, at most three sessions.
PoolOptions _poolOptions(Map<String, Object> settings) => PoolOptions(
  maxProcesses: 3,
  feedDurationLimitGrace: switch (settings['feed_duration_limit_grace']) {
    final Object grace => _seconds(grace),
    null => PoolOptions.defaultDurationLimitGrace,
  },
  turnDurationLimitGrace: switch (settings['turn_duration_limit_grace']) {
    final Object grace => _seconds(grace),
    null => PoolOptions.defaultDurationLimitGrace,
  },
);

/// The session settings an `open` step names.
SessionConfig _sessionConfig(Map<String, Object> settings) {
  Duration? seconds(String key) =>
      settings[key] == null ? null : _seconds(settings[key]!);
  final suspensions = settings['max_suspensions'] as int?;
  final feed = seconds('max_feed_duration_secs');
  final turn = seconds('max_turn_duration_secs');
  final sleep = seconds('max_total_sleep_secs');
  final limited = [suspensions, feed, turn, sleep].any((v) => v != null);

  return SessionConfig(
    scriptName: settings['script_name'] as String? ?? 'main.py',
    typeCheck: settings['type_check'] as bool? ?? false,
    limits: limited
        ? ResourceLimits(
            maxSuspensions: suspensions,
            maxFeedDuration: feed,
            maxTurnDuration: turn,
            maxTotalSleep: sleep,
          )
        : null,
  );
}

/// [snapshot] in the oracle's form.
String _describe(MontySnapshot snapshot) {
  String at(SuspendedSnapshot s) =>
      'script=${s.scriptName} at=${s.position.filename}:'
      '${s.position.start}-${s.position.end}';
  // An int, None, or a str as Python's repr shows a plain one.
  String int(MontyValue v) => switch (v) {
    MontyNone() => 'None',
    MontyString(:final value) => "'$value'",
    _ => '${(v as MontyInt).value}',
  };
  String named(Map<String, MontyValue> kwargs) => [
    for (final k in kwargs.keys.toList()..sort()) '$k: ${int(kwargs[k]!)}',
  ].join(', ');

  return switch (snapshot) {
    SessionComplete(:final output) =>
      'complete: ${(output as MontyString).value}',
    FunctionSnapshot(:final kwargs) =>
      '${snapshot.isOsFunction ? 'os' : 'call'} ${snapshot.functionName} '
          'args=[${snapshot.args.map(int).join(', ')}] '
          'kwargs={${named(kwargs)}} '
          '${at(snapshot)}',
    NameLookupSnapshot() => 'lookup ${snapshot.variableName} ${at(snapshot)}',
    FutureSnapshot() =>
      'futures [${snapshot.pendingCallIds.join(', ')}] ${at(snapshot)}',
  };
}

/// [error] in the oracle's form; the time a feed took is left out of a
/// time-limit message.
String _errorText(Object error) => switch (error) {
  MontyTypingError() => 'MontyTypingError: ${error.display()}',
  MontyRuntimeError() =>
    "MontyRuntimeError: ${error.display('type-msg')}".replaceAll(
      RegExp(r'time limit exceeded: \S+ >'),
      'time limit exceeded: … >',
    ),
  StateError(:final message) when message == 'the session is finished' =>
    'finished',
  StateError(:final message) => 'RuntimeError: $message',
  _ => '${error.runtimeType}: $error',
};

/// One case's sessions, snapshots and dumps, by session name.
final class _Run {
  _Run(this._pool);

  final MontyPool _pool;
  final Map<String, PoolSession> _sessions = {};
  final Map<String, MontySnapshot> _snapshots = {};
  final Map<String, MontySnapshot> _spent = {};
  final Map<String, Uint8List> _dumps = {};

  /// Closes every session the case opened.
  Future<void> closeAll() async {
    for (final session in _sessions.values) {
      await session.close();
    }
  }

  /// The outcome of [step], in the oracle's form.
  Future<String> step(List<Object> step) async {
    try {
      return await _step(step);
    } on Object catch (error) {
      return _errorText(error);
    }
  }

  Future<String> _step(List<Object> step) async {
    final [op as String, name as String, ...rest] = step;
    // A step's one argument; `close` and the dumps have none.
    final arg = rest.isEmpty ? '' : onlyItem(rest);
    if (op == 'open') {
      _sessions[name] = await _pool.checkout(
        options: _sessionConfig(arg as Map<String, Object>),
      );

      return 'ok';
    }
    final session = _sessions[name]!;
    switch (op) {
      case 'close':
        await session.close();

        return 'ok';
      case 'feed':
        return _value(
          await session.feedRun(arg as String, printCallback: _ignore),
        );
      case 'feed_dumping':
        final ext = coroutine((args, kwargs) async {
          _dumps[name] = await session.dump();

          return MontyInt((onlyItem(args) as MontyInt).value + 1);
        });

        return _value(
          await session.feedRun(
            arg as String,
            externals: {'ext': ext},
            printCallback: _ignore,
          ),
        );
      case 'chdir':
        await session.feedRun(
          "import os\nos.chdir('$arg')",
          printCallback: _ignore,
          os: (call, args, kwargs) => call == 'Path.stat'
              ? _dirStat
              : throw const OsCallNotHandledException(),
        );

        return 'ok';
      case 'start':
        return _describe(
          _snapshots[name] = await session.feedStart(
            arg as String,
            printCallback: _ignore,
          ),
        );
      case 'dump':
        _dumps[name] = await session.dump();

        return 'dumped';
      case 'snapdump' || 'olddump':
        final snapshot = (op == 'snapdump' ? _snapshots : _spent)[name];
        if (snapshot is! SuspendedSnapshot) {
          throw StateError('no suspension to dump: $snapshot');
        }
        _dumps[name] = await snapshot.dump();

        return 'dumped';
      case 'load_session':
        await session.loadSession(_state(arg as String));

        return 'ok';
      case 'load_snapshot':
        return _describe(
          _snapshots[name] = await session.loadSnapshot(
            _state(arg as String),
            printCallback: _ignore,
          ),
        );
      case 'resume':
        final snapshot = _spent[name] = _snapshots[name]!;
        final value = MontyInt(arg as int);

        return _describe(
          _snapshots[name] = await switch (snapshot) {
            NameLookupSnapshot() => snapshot.resume(value: value),
            FunctionSnapshot() => snapshot.resume(ExternalReturnValue(value)),
            _ => throw StateError('cannot resume $snapshot'),
          },
        );
    }
    throw ArgumentError.value(op, 'step', 'unknown step');
  }

  /// The dump kept under [source], or the bytes `garbage` for `!garbage`.
  Uint8List _state(String source) => source == '!garbage'
      ? Uint8List.fromList(utf8.encode('garbage'))
      : _dumps[source]!;

  String _value(MontyValue value) => 'value: ${(value as MontyString).value}';
}

/// The tests, each case on a pool from [start], closed at its end.
void restoreOracleTests(String label, StartPool start) {
  test('the restore oracle is complete ($label)', () {
    // The floor: a regeneration that lost cases must not pass as green.
    expect(restoreOracle.length, greaterThanOrEqualTo(33));
  });

  for (final MapEntry(key: id, value: (:pool, :steps))
      in restoreOracle.entries) {
    test(
      'restore $id matches upstream, step by step ($label)',
      () async {
        final montyPool = await start(_poolOptions(pool));
        final run = _Run(montyPool);
        try {
          final actual = [
            for (final (:step, outcome: _) in steps)
              '$step => ${await run.step(step)}',
          ];
          expect(actual, [
            for (final (:step, :outcome) in steps) '$step => $outcome',
          ]);
        } finally {
          await run.closeAll();
          await montyPool.close();
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  }
}
