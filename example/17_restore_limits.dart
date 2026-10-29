// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 17 — a restore cannot loosen limits
//
// A dump remembers the limits its session ran under, and a restore keeps
// the stricter of the two: the dump's own limit and the receiving
// checkout's. A destination with roomier limits cannot widen what the
// dump was made under; a destination with tighter ones wins outright.
// The limits that a dump does not carry keep the destination's.
//
// Every probe here restores a dump into a fresh checkout and runs one
// expression in it, so each measurement stands on its own: the recursion
// depth, the suspension budget, the heap, the feed and turn clocks and
// the total sleep of the restored session are the ones the dump and the
// destination agree on.
//
// Covers: loadSession, loadSnapshot, ResourceLimits on restore,
//         FunctionSnapshot.resume, MontyRuntimeError.
//
// Run: dart run example/17_restore_limits.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';

// ── The Python the checks run ───────────────────────────────────────────────

// The Python starts at the first character on purpose: a leading newline
// would be part of the source the interpreter reads.
// ignore: leading_newlines_in_multiline_strings
const _bootstrap = '''def recurse(n):
    if n <= 0:
        return 0
    return 1 + recurse(n - 1)

def allocate(n):
    return len('x' * n)

def spin():
    while True:
        pass

def calls(n):
    for i in range(n):
        tick()
    return n

def nap(seconds):
    import time
    time.sleep(seconds)
    return 7

42
''';

// The checkpoint starts at the first character too.
// ignore: leading_newlines_in_multiline_strings
const _checkpoint = '''gate()
gate()
expression = gate()
eval(expression)
''';

// ── The limits ───────────────────────────────────────────────────────────────

const _mainSource = ResourceLimits(
  maxRecursionDepth: 32,
  maxSuspensions: 5,
  maxMemory: 2097152,
  maxFeedDuration: Duration(seconds: 1),
  gcInterval: 1000,
);

const _turnSource = ResourceLimits(
  maxRecursionDepth: 32,
  maxSuspensions: 5,
  maxMemory: 2097152,
  maxTurnDuration: Duration(seconds: 1),
  gcInterval: 1000,
);

const _sleepSource = ResourceLimits(
  maxRecursionDepth: 32,
  maxSuspensions: 5,
  maxMemory: 2097152,
  maxTotalSleep: Duration(milliseconds: 250),
  gcInterval: 1000,
);

const _optionalSource = ResourceLimits(
  maxRecursionDepth: 32,
  maxSuspensions: 5,
  gcInterval: 1000,
);

const _mainLooser = ResourceLimits(
  maxRecursionDepth: 128,
  maxSuspensions: 20,
  maxMemory: 8388608,
  maxFeedDuration: Duration(seconds: 4),
  gcInterval: 10000,
);

const _mainTighter = ResourceLimits(
  maxRecursionDepth: 8,
  maxSuspensions: 3,
  maxMemory: 524288,
  maxFeedDuration: Duration(milliseconds: 250),
  gcInterval: 100,
);

const _turnLooser = ResourceLimits(maxTurnDuration: Duration(seconds: 4));
const _turnTighter = ResourceLimits(
  maxTurnDuration: Duration(milliseconds: 250),
);
const _sleepLooser = ResourceLimits(maxTotalSleep: Duration(seconds: 1));
const _sleepTighter = ResourceLimits(
  maxTotalSleep: Duration(milliseconds: 125),
);
const _memoryOnly = ResourceLimits(maxMemory: 524288);
const _feedOnly = ResourceLimits(maxFeedDuration: Duration(milliseconds: 250));
const _turnOnly = ResourceLimits(maxTurnDuration: Duration(milliseconds: 250));
const _sleepOnly = ResourceLimits(maxTotalSleep: Duration(milliseconds: 125));

// ── The shapes of the checks ────────────────────────────────────────────────

/// A dump of one profile in one mode, and the suspensions its source saw.
typedef _Dump = ({Uint8List bytes, int sourceSeen});

/// A receiving checkout: its name, and the limits it asks for.
typedef _Destination = ({String name, ResourceLimits? limits});

/// One expression to run in a restored session, and what it must do.
typedef _Probe = ({
  String expression,
  int? value,
  String? errorType,
  String? errorExact,
  String? errorPrefix,
  String? errorSuffix,
  bool errorTraceback,
});

/// One run of a group: its label, its destinations and their probes.
typedef _Run = ({
  String label,
  List<_Destination> destinations,
  List<_Probe> Function(_Destination destination) probes,
});

/// One profile in one mode, with the runs that print its PASS lines.
typedef _Group = ({String profile, String mode, List<_Run> runs});

Future<void> main() async {
  try {
    _printPolicies();
    await Monty.withPool(
      _run,
      maxProcesses: 1,
      requestTimeout: const Duration(seconds: 15),
      feedDurationLimitGrace: const Duration(seconds: 5),
      turnDurationLimitGrace: const Duration(seconds: 5),
    );
  } on Object catch (error, stack) {
    stderr
      ..writeln('restore_limits: $error')
      ..writeln(stack);
    exitCode = 1;

    return;
  }
  print('DEMO OK restore_limits');
}

// ── The policies the checks measure ─────────────────────────────────────────

void _printPolicies() {
  print('POLICY recursion main=32 omitted=32 looser=32 tighter=8');
  print('POLICY suspensions main=5 omitted=5 looser=5 tighter=3');
  print(
    'POLICY memory main=2097152 omitted=2097152 looser=2097152 tighter=524288',
  );
  print('POLICY feed main=1s omitted=1s looser=1s tighter=250ms');
  print('POLICY turn isolated=1s omitted=1s looser=1s tighter=250ms');
  print('POLICY sleep isolated=250ms omitted=250ms looser=250ms tighter=125ms');
  print(
    'POLICY gcInterval main=1000 omitted=1000 looser=1000 tighter=100 '
    'documentation-only',
  );
}

// ── The runs ────────────────────────────────────────────────────────────────

Future<void> _run(Monty monty) async {
  final dumps = await _sourceDumps(monty);
  print('PASS source-dumps');
  for (final group in _groups()) {
    for (final run in group.runs) {
      for (final destination in run.destinations) {
        await _probes(
          monty,
          dumps,
          group,
          destination,
          run.probes(destination),
        );
      }
      print('PASS ${run.label}');
    }
  }
}

List<_Group> _groups() => [
  _mainGroup('idle'),
  _mainGroup('snapshot'),
  _turnGroup('idle'),
  _turnGroup('snapshot'),
  _sleepGroup('idle'),
  _sleepGroup('snapshot'),
  _optionalGroup('idle'),
  _optionalGroup('snapshot'),
];

// ── The dumps the probes restore ────────────────────────────────────────────

Future<Map<String, _Dump>> _sourceDumps(Monty monty) async {
  final dumps = <String, _Dump>{};
  for (final profile in const ['main', 'turn', 'sleep', 'optional']) {
    for (final mode in const ['idle', 'snapshot']) {
      final dump = await _sourceDump(monty, profile, mode);
      dumps['$profile/$mode'] = dump;
      print('OBS dump profile=$profile mode=$mode bytes=${dump.bytes.length}');
    }
  }

  return dumps;
}

Future<_Dump> _sourceDump(Monty monty, String profile, String mode) async {
  final session = await monty.checkout(limits: _sourceLimits(profile));
  try {
    final value = await session.feedRun(_bootstrap);
    if (value is! MontyInt || value.value != 42) {
      _fail('the $profile bootstrap did not return 42');
    }
    if (mode == 'idle') {
      final bytes = await session.dump();
      if (bytes.isEmpty) _fail('the idle dump of $profile is empty');

      return (bytes: bytes, sourceSeen: 0);
    }

    return await _suspendedDump(session, profile);
  } finally {
    await session.close();
  }
}

ResourceLimits _sourceLimits(String profile) => switch (profile) {
  'main' => _mainSource,
  'turn' => _turnSource,
  'sleep' => _sleepSource,
  _ => _optionalSource,
};

Future<_Dump> _suspendedDump(MontySession session, String profile) async {
  var snapshot = await session.feedStart(_checkpoint);
  var seen = 0;
  while (seen < 2) {
    final gate = _gateOf(snapshot, profile);
    seen++;
    snapshot = await gate.resume(const ExternalReturnValue(MontyInt(0)));
  }
  final third = _gateOf(snapshot, profile);
  seen++;
  final bytes = await third.dump();
  if (bytes.isEmpty) _fail('the suspended dump of $profile is empty');

  return (bytes: bytes, sourceSeen: seen);
}

FunctionSnapshot _gateOf(MontySnapshot snapshot, String profile) {
  if (snapshot is! FunctionSnapshot) {
    _fail('the $profile checkpoint did not park on a call');
  }
  if (snapshot.functionName != 'gate' || snapshot.isOsFunction) {
    _fail('the $profile checkpoint did not park on gate');
  }

  return snapshot;
}

// ── One probe ───────────────────────────────────────────────────────────────

Future<void> _probes(
  Monty monty,
  Map<String, _Dump> dumps,
  _Group group,
  _Destination destination,
  List<_Probe> probes,
) async {
  final dump = dumps['${group.profile}/${group.mode}']!;
  for (var index = 0; index < probes.length; index++) {
    await _probe(monty, dump, group, destination, index, probes[index]);
  }
}

Future<void> _probe(
  Monty monty,
  _Dump dump,
  _Group group,
  _Destination destination,
  int index,
  _Probe probe,
) async {
  final id = _caseId(group, destination, index, probe.expression);
  final limits = destination.limits;
  final session = limits == null
      ? await monty.checkout()
      : await monty.checkout(limits: limits);
  try {
    final stopwatch = Stopwatch()..start();
    final gate = await _restore(session, dump.bytes, group.mode);
    stopwatch.stop();
    print('OBS restore case=$id micros=${stopwatch.elapsedMicroseconds}');
    final outcome = await _drive(session, gate, probe, group.mode);
    final error = outcome.error;
    if (error == null) {
      _expectValue(probe, outcome.output);
    } else {
      _expectFailure(probe, error);
      await _healthCheck(session);
    }
    if (group.mode == 'snapshot' && probe.expression == 'calls(30)') {
      final seen = dump.sourceSeen;
      print(
        'OBS carry case=$id source_seen=$seen '
        'returned_after_load=${outcome.returned}',
      );
    }
  } finally {
    await session.close();
  }
}

Future<FunctionSnapshot?> _restore(
  MontySession session,
  Uint8List bytes,
  String mode,
) async {
  if (mode == 'idle') {
    await session.loadSession(bytes);

    return null;
  }
  final snapshot = await session.loadSnapshot(bytes);
  if (snapshot is! FunctionSnapshot) {
    _fail('the restored checkpoint is not a call');
  }
  if (snapshot.functionName != 'gate' || snapshot.isOsFunction) {
    _fail('the restored checkpoint is not the gate');
  }

  return snapshot;
}

Future<({MontyValue? output, MontyRuntimeError? error, int returned})> _drive(
  MontySession session,
  FunctionSnapshot? gate,
  _Probe probe,
  String mode,
) async {
  final expression = '${probe.expression}\n';
  var returned = 0;
  var sleeps = 0;
  try {
    final MontySnapshot first;
    if (mode == 'snapshot') {
      if (gate == null) _fail('the restored checkpoint is missing');
      returned = 1;
      first = await gate.resume(ExternalReturnValue(MontyString(expression)));
    } else {
      first = await session.feedStart(expression);
    }
    var snapshot = first;
    while (snapshot is! MontyComplete) {
      returned++;
      if (returned > 30) {
        _fail('${probe.expression}: too many suspensions');
      }
      if (_isSleepCall(snapshot)) sleeps++;
      snapshot = await _answer(snapshot, probe);
    }
    if (probe.expression.startsWith('nap') && sleeps != 1) {
      _fail('${probe.expression}: expected one system.sleep call');
    }

    return (output: snapshot.output, error: null, returned: returned);
  } on MontyRuntimeError catch (error) {
    return (output: null, error: error, returned: returned);
  }
}

bool _isSleepCall(MontySnapshot snapshot) =>
    snapshot is FunctionSnapshot &&
    snapshot.isOsFunction &&
    snapshot.functionName == 'system.sleep';

Future<MontySnapshot> _answer(MontySnapshot snapshot, _Probe probe) {
  if (snapshot is! FunctionSnapshot) {
    _fail('${probe.expression}: unexpected ${snapshot.runtimeType}');
  }
  _expectCall(snapshot, probe);

  return snapshot.resume(const ExternalReturnValue(MontyInt(0)));
}

void _expectCall(FunctionSnapshot snapshot, _Probe probe) {
  final expression = probe.expression;
  if (expression.startsWith('calls')) {
    if (snapshot.functionName != 'tick' || snapshot.isOsFunction) {
      _fail('$expression: expected a tick call');
    }

    return;
  }
  if (expression.startsWith('nap')) {
    if (!snapshot.isOsFunction || snapshot.functionName != 'system.sleep') {
      _fail('$expression: expected a system.sleep call');
    }

    return;
  }
  _fail('$expression: unexpected ${snapshot.functionName}');
}

// ── What a probe must show ──────────────────────────────────────────────────

void _expectValue(_Probe probe, MontyValue? output) {
  final value = probe.value;
  if (value == null) {
    _fail('${probe.expression}: expected ${probe.errorType}');
  }
  if (output is! MontyInt || output.value != value) {
    _fail('${probe.expression}: expected $value, got $output');
  }
}

void _expectFailure(_Probe probe, MontyRuntimeError error) {
  final type = probe.errorType;
  final actual = error.exception.excType;
  if (type == null) {
    _fail('${probe.expression}: unexpected $actual');
  }
  if (actual != type) {
    _fail('${probe.expression}: expected $type, got $actual');
  }
  _expectMessage(probe, error.exception.message ?? '');
  if (probe.errorTraceback && error.traceback.isEmpty) {
    _fail('${probe.expression}: the error carries no traceback');
  }
}

void _expectMessage(_Probe probe, String message) {
  final expression = probe.expression;
  final exact = probe.errorExact;
  if (exact != null && message != exact) {
    _fail('$expression: expected "$exact", got "$message"');
  }
  final prefix = probe.errorPrefix;
  if (prefix != null && !message.startsWith(prefix)) {
    _fail('$expression: expected "$prefix...", got "$message"');
  }
  final suffix = probe.errorSuffix;
  if (suffix != null && !message.endsWith(suffix)) {
    _fail('$expression: expected "...$suffix", got "$message"');
  }
}

Future<void> _healthCheck(MontySession session) async {
  final value = await session.feedRun('1 + 1\n');
  if (value is! MontyInt || value.value != 2) {
    _fail('the session is not healthy after the error');
  }
}

String _caseId(
  _Group group,
  _Destination destination,
  int index,
  String expression,
) {
  final slug = expression
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'-$'), '');

  return '${group.mode}-${group.profile}-${destination.name}-$index-$slug';
}

Never _fail(String message) => throw StateError('restore_limits: $message');

// ── The probes of every group ───────────────────────────────────────────────

_Probe _ok(String expression, int value) => (
  expression: expression,
  value: value,
  errorType: null,
  errorExact: null,
  errorPrefix: null,
  errorSuffix: null,
  errorTraceback: false,
);

_Probe _fails(
  String expression,
  String type, {
  String? exact,
  String? prefix,
  String? suffix,
  bool traceback = false,
}) => (
  expression: expression,
  value: null,
  errorType: type,
  errorExact: exact,
  errorPrefix: prefix,
  errorSuffix: suffix,
  errorTraceback: traceback,
);

_Group _mainGroup(String mode) => (
  profile: 'main',
  mode: mode,
  runs: [
    (
      label: '$mode-omitted',
      destinations: const [(name: 'omitted', limits: null)],
      probes: (_) => _mainProbes(tighter: false),
    ),
    (
      label: '$mode-looser',
      destinations: const [(name: 'looser', limits: _mainLooser)],
      probes: (_) => _mainProbes(tighter: false),
    ),
    (
      label: '$mode-tighter',
      destinations: const [(name: 'tighter', limits: _mainTighter)],
      probes: (_) => _mainProbes(tighter: true),
    ),
  ],
);

List<_Probe> _mainProbes({required bool tighter}) {
  if (tighter) {
    return [
      _ok('recurse(2)', 2),
      _ok('allocate(4096)', 4096),
      _ok('calls(1)', 1),
      _ok('7', 7),
      _fails('recurse(16)', 'RecursionError'),
      _fails('allocate(1048576)', 'MemoryError', traceback: true),
      _fails('calls(30)', 'RuntimeError', exact: 'suspension limit 3 exceeded'),
      _fails(
        'spin()',
        'TimeoutError',
        prefix: 'feed time limit exceeded:',
        suffix: '> 250ms',
      ),
    ];
  }

  return [
    _ok('recurse(2)', 2),
    _ok('recurse(16)', 16),
    _ok('allocate(4096)', 4096),
    _ok('allocate(1048576)', 1048576),
    _ok('calls(1)', 1),
    _ok('7', 7),
    _fails('recurse(64)', 'RecursionError'),
    _fails('allocate(4194304)', 'MemoryError', traceback: true),
    _fails('calls(30)', 'RuntimeError', exact: 'suspension limit 5 exceeded'),
    _fails(
      'spin()',
      'TimeoutError',
      prefix: 'feed time limit exceeded:',
      suffix: '> 1s',
    ),
  ];
}

_Group _turnGroup(String mode) => (
  profile: 'turn',
  mode: mode,
  runs: [
    (
      label: '$mode-turn',
      destinations: const [
        (name: 'omitted', limits: null),
        (name: 'looser', limits: _turnLooser),
        (name: 'tighter', limits: _turnTighter),
      ],
      probes: (destination) =>
          _turnProbes(tighter: destination.name == 'tighter'),
    ),
  ],
);

List<_Probe> _turnProbes({required bool tighter}) => [
  _ok('7', 7),
  _fails(
    'spin()',
    'TimeoutError',
    prefix: 'turn time limit exceeded:',
    suffix: tighter ? '> 250ms' : '> 1s',
  ),
];

_Group _sleepGroup(String mode) => (
  profile: 'sleep',
  mode: mode,
  runs: [
    (
      label: '$mode-sleep',
      destinations: const [
        (name: 'omitted', limits: null),
        (name: 'looser', limits: _sleepLooser),
        (name: 'tighter', limits: _sleepTighter),
      ],
      probes: (destination) =>
          _sleepProbes(tighter: destination.name == 'tighter'),
    ),
  ],
);

List<_Probe> _sleepProbes({required bool tighter}) => [
  _ok('nap(0.0625)', 7),
  _fails(
    tighter ? 'nap(0.25)' : 'nap(0.5)',
    'TimeoutError',
    exact: tighter
        ? 'sleep limit exceeded: 250ms > 125ms'
        : 'sleep limit exceeded: 500ms > 250ms',
  ),
];

_Group _optionalGroup(String mode) => (
  profile: 'optional',
  mode: mode,
  runs: [
    (
      label: '$mode-optional',
      destinations: const [
        (name: 'memory', limits: _memoryOnly),
        (name: 'feed', limits: _feedOnly),
        (name: 'turn', limits: _turnOnly),
        (name: 'sleep', limits: _sleepOnly),
        (name: 'omitted', limits: null),
      ],
      probes: (destination) => _optionalProbes(destination.name),
    ),
  ],
);

List<_Probe> _optionalProbes(String destination) => switch (destination) {
  'memory' => [
    _ok('allocate(4096)', 4096),
    _fails('allocate(1048576)', 'MemoryError', traceback: true),
  ],
  'feed' => [
    _ok('7', 7),
    _fails(
      'spin()',
      'TimeoutError',
      prefix: 'feed time limit exceeded:',
      suffix: '> 250ms',
    ),
  ],
  'turn' => [
    _ok('7', 7),
    _fails(
      'spin()',
      'TimeoutError',
      prefix: 'turn time limit exceeded:',
      suffix: '> 250ms',
    ),
  ],
  'sleep' => [
    _ok('nap(0.0625)', 7),
    _fails(
      'nap(0.25)',
      'TimeoutError',
      exact: 'sleep limit exceeded: 250ms > 125ms',
    ),
  ],
  _ => [_ok('allocate(4194304)', 4194304), _ok('nap(0.5)', 7), _ok('7', 7)],
};
