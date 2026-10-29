// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 18 — a durable agent loop
//
// A typed agent script parks on a human approval and survives its host
// process exiting: the suspension is dumped to disk, every tool effect is
// journaled, and a later Dart process rebuilds the modules, loads the dump
// and finishes the run, replaying recorded answers instead of rerunning
// the tools. The launcher runs the three phases as child processes, keeps
// no pool of its own, and prints one PASS line per property it verified.
//
// Covers: ExternalModule stubs under typeCheck, coroutine-marked host
//         functions, feedStart drive loops over FunctionSnapshot and
//         FutureSnapshot, FunctionSnapshot.dump and loadSnapshot across a
//         process restart, ResourceLimits ceilings a dump keeps.
//
// Run: dart run example/18_durable_agent.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

// ── The fixed scripts, stubs and operation specifications ────────────────────

const String _agentSource = '''
import asyncio
import tools
import human

hits = await asyncio.gather(
    tools.search("search:a", "alpha"),
    tools.search("search:b", "beta"),
)

decision = human.approve("approve:1", "|".join(hits))
repeated = await tools.search("search:a", "alpha")

try:
    detail = tools.enrich("enrich:1")
except ValueError as error:
    detail = "fallback:" + str(error)

draft = "|".join([
    hits[0],
    hits[1],
    decision,
    repeated,
    detail,
])
receipt = tools.publish("publish:1", draft)
draft + "|" + receipt
''';

const String _toolsStubs =
    'async def search(operation_id: str, query: str) -> str: ...\n'
    'def enrich(operation_id: str) -> str: ...\n'
    'def publish(operation_id: str, report: str) -> str: ...\n';

const String _humanStubs =
    'def approve(operation_id: str, summary: str) -> str: ...\n';

const String _probeSource = 'tools.publish("publish:probe", 3)';

const String _expectedDraft =
    'alpha-hit|beta-hit|approved|alpha-hit|fallback:catalog offline';

const String _expectedReport = '$_expectedDraft|published';

const List<String> _approvalArgs = ['approve:1', 'alpha-hit|beta-hit'];

String _depthScript(int depth) =>
    'def depth(n: int) -> int:\n'
    '    if n == 0:\n'
    '        return 0\n'
    '    return 1 + depth(n - 1)\n'
    '\n'
    'depth($depth)\n';

/// One fixed operation specification, as a record value.
typedef _OpSpec = ({
  String id,
  String function,
  List<String> args,
  Map<String, Object?> outcome,
});

const List<_OpSpec> _opSpecs = [
  (
    id: 'search:a',
    function: 'tools.search',
    args: ['search:a', 'alpha'],
    outcome: {'kind': 'value', 'value': 'alpha-hit'},
  ),
  (
    id: 'search:b',
    function: 'tools.search',
    args: ['search:b', 'beta'],
    outcome: {'kind': 'value', 'value': 'beta-hit'},
  ),
  (
    id: 'approve:1',
    function: 'human.approve',
    args: ['approve:1', 'alpha-hit|beta-hit'],
    outcome: {'kind': 'value', 'value': 'approved'},
  ),
  (
    id: 'enrich:1',
    function: 'tools.enrich',
    args: ['enrich:1'],
    outcome: {
      'kind': 'exception',
      'excType': 'ValueError',
      'message': 'catalog offline',
    },
  ),
  (
    id: 'publish:1',
    function: 'tools.publish',
    args: ['publish:1', _expectedDraft],
    outcome: {'kind': 'value', 'value': 'published'},
  ),
];

// ── Shapes shared across the phases, as record types ─────────────────────────

/// A journal: its file and the decoded version-1 document it holds.
typedef _JournalState = ({File file, Map<String, Object?> data});

/// The rebuilt modules, the callbacks wired into them, and their counters.
typedef _AgentState = ({
  _JournalState journal,
  Map<String, int> invocations,
  ExternalModule tools,
  ExternalModule human,
  MontyHostFunction search,
});

/// One feedStart drive loop: what it captured and what it counted.
typedef _DriverState = ({
  MontyHostFunction search,
  Map<int, (List<MontyValue>, Map<String, MontyValue>)> captures,
  Map<String, int> counters,
  List<int> batchWidths,
});

/// Everything the launcher gathers before it starts checking.
typedef _Evidence = ({
  Map<String, Object?> baseline,
  Map<String, Object?> park,
  Map<String, Object?> resume,
  Map<String, Object?> checkpoint,
  int parkExitCode,
  bool parkedOnlySearches,
  String offlineAnswer,
  int snapshotBytes,
  _JournalState baselineJournal,
  _JournalState restartJournal,
});

// ── Entry point: the launcher, or one of the three child phases ──────────────

Future<void> main(List<String> arguments) async {
  try {
    switch (arguments) {
      case []:
        if (!await _launch()) {
          exitCode = 1;
        }
      case ['--baseline', final directory]:
        await _runChild('baseline', directory, _runBaseline);
      case ['--park', final directory]:
        await _runChild('park', directory, _runPark);
      case ['--resume', final directory]:
        await _runChild('resume', directory, _runResume);
      default:
        throw ArgumentError.value(arguments, 'arguments', 'unknown phase');
    }
  } on Object catch (error, stackTrace) {
    stderr.writeln('durable agent: $error');
    stderr.writeln(stackTrace.toString());
    exitCode = 1;
  }
}

/// Runs one child phase and writes its version-1 result file.
Future<void> _runChild(
  String kind,
  String directory,
  Future<Map<String, Object?>> Function(String) run,
) async {
  final result = await run(directory);
  await _writeJson(File(_path(directory, '$kind-result.json')), result);
}

// ── The launcher: children, offline approval, checks, PASS lines ─────────────

Future<bool> _launch() async {
  final root = await Directory.systemTemp.createTemp('durable_agent_');
  var ok = true;
  try {
    _verify(await _gatherEvidence(root));
  } on Object catch (error, stackTrace) {
    stderr.writeln('durable agent: $error');
    stderr.writeln(stackTrace.toString());
    ok = false;
  } finally {
    ok = await _deleteRoot(root) && ok;
  }
  if (ok) {
    _printPassLines();
  }

  return ok;
}

/// Runs the three children in order, records the offline approval between
/// park and resume, and loads every artefact the checks read.
Future<_Evidence> _gatherEvidence(Directory root) async {
  final baselineDir = Directory(_path(root.path, 'baseline'));
  final restartDir = Directory(_path(root.path, 'restart'));
  await baselineDir.create();
  await restartDir.create();
  final baselineJournal = File(_path(baselineDir.path, 'journal.json'));
  final restartJournal = File(_path(restartDir.path, 'journal.json'));
  final baseline = await _childRun(
    ['--baseline', baselineDir.path],
    'baseline',
    _path(baselineDir.path, 'baseline-result.json'),
  );
  final park = await _childRun(
    ['--park', restartDir.path],
    'park',
    _path(restartDir.path, 'park-result.json'),
  );
  final offline = await _approveOffline(restartJournal);
  final resume = await _childRun(
    ['--resume', restartDir.path],
    'resume',
    _path(restartDir.path, 'resume-result.json'),
  );
  final checkpoint = _objectAt(
    jsonDecode(
      await File(_path(restartDir.path, 'checkpoint.json')).readAsString(),
    ),
    'checkpoint',
  );

  return (
    baseline: baseline.result,
    park: park.result,
    resume: resume.result,
    checkpoint: checkpoint,
    parkExitCode: park.exitCode,
    parkedOnlySearches: offline.onlySearches,
    offlineAnswer: offline.answer,
    snapshotBytes: await File(_path(restartDir.path, 'snapshot.bin')).length(),
    baselineJournal: await _journalOpen(baselineJournal),
    restartJournal: await _journalOpen(restartJournal),
  );
}

/// Spawns this script as one child phase and loads its result file. A child
/// must exit 0 and write no stdout; its stderr belongs to the diagnostics.
Future<({int exitCode, Map<String, Object?> result})> _childRun(
  List<String> arguments,
  String kind,
  String resultPath,
) async {
  final run = await Process.run(Platform.resolvedExecutable, [
    Platform.script.toFilePath(),
    ...arguments,
  ]);
  if (run.exitCode != 0 || (run.stdout as String).isNotEmpty) {
    _reportChildFailure(kind, run.exitCode, run.stdout, run.stderr);
  }
  final file = File(resultPath);
  _require(file.existsSync(), '$kind wrote no result file');
  final result = _objectAt(
    jsonDecode(await file.readAsString()),
    '$kind result',
  );
  _require(
    _intAt(result['version'], '$kind result version') == 1,
    '$kind result is not version 1',
  );

  return (exitCode: run.exitCode, result: result);
}

void _reportChildFailure(
  String kind,
  int exitCode,
  Object? outText,
  Object? errText,
) {
  stderr.writeln('durable agent: $kind child failed with exit code $exitCode');
  if (outText is String && outText.isNotEmpty) {
    stderr.writeln('--- $kind stdout ---');
    stderr.write(outText);
  }
  if (errText is String && errText.isNotEmpty) {
    stderr.writeln('--- $kind stderr ---');
    stderr.write(errText);
  }
  throw StateError('$kind child failed');
}

/// With the park child gone and no launcher pool, answers the parked
/// approval from the journal: the demonstration's offline approval.
Future<({bool onlySearches, String answer})> _approveOffline(
  File journalFile,
) async {
  final journal = await _journalOpen(journalFile);
  final onlySearches = _sameStringSets(
    _operationsOf(journal).keys.toSet(),
    const {'search:a', 'search:b'},
  );
  final answer = await _journalExecute(
    journal,
    'approve:1',
    'human.approve',
    _approvalArgs,
  );

  return (
    onlySearches: onlySearches,
    answer: _stringValue(answer, 'the offline approval answer'),
  );
}

Future<bool> _deleteRoot(Directory root) async {
  try {
    await root.delete(recursive: true);

    return true;
  } on Object catch (error) {
    stderr.writeln('durable agent: could not delete ${root.path}: $error');

    return false;
  }
}

void _printPassLines() {
  const names = [
    'module-stubs',
    'search-fanout',
    'parked-at-approval',
    'worker-released',
    'host-restarted',
    'worker-restarted',
    'restored-approval',
    'journal-replay',
    'effects-once',
    'restored-tool-error',
    'report-matches',
    'dump-limit-retained',
    'loose-limit-control',
  ];
  for (final name in names) {
    print('PASS $name');
  }
  print('DEMO OK durable_agent');
}

// ── The thirteen checks, in the order their PASS lines print ─────────────────

void _verify(_Evidence evidence) {
  _checkModuleStubs(evidence);
  _checkSearchFanout(evidence);
  _checkParkedAtApproval(evidence);
  _checkWorkerReleased(evidence);
  _checkHostRestarted(evidence);
  _checkWorkerRestarted(evidence);
  _checkRestoredApproval(evidence);
  _checkJournalReplay(evidence);
  _checkEffectsOnce(evidence);
  _checkRestoredToolError(evidence);
  _checkReportMatches(evidence);
  _checkDumpLimitRetained(evidence);
  _checkLooseLimitControl(evidence);
}

void _checkModuleStubs(_Evidence evidence) {
  for (final result in [evidence.baseline, evidence.park, evidence.resume]) {
    _require(
      result['toolsStubsExact'] == true,
      'the tools stubs differ in ${result['kind']}',
    );
    _require(
      result['humanStubsExact'] == true,
      'the human stubs differ in ${result['kind']}',
    );
  }
  for (final result in [evidence.baseline, evidence.park]) {
    _require(
      _resultInt(result, 'imports') > 0,
      '${result['kind']} saw no import',
    );
    _require(
      _resultInt(result, 'importStubs') > 0,
      '${result['kind']} saw no import_stubs',
    );
  }
  _require(
    evidence.resume['probeRejected'] == true,
    'the restored session accepted the mistyped publish',
  );
  _require(
    _intAt(_invocations(evidence.resume)['publish:1'], 'resume publish:1') == 1,
    'the mistyped probe reached the publish callback',
  );
}

void _checkSearchFanout(_Evidence evidence) {
  _require(
    _intListsEqual(
      _intsAt(evidence.baseline['batchWidths'], 'baseline batch widths'),
      const [2, 1],
    ),
    'the baseline batch widths differ',
  );
  _require(
    _intListsEqual(
      _intsAt(evidence.park['batchWidths'], 'park batch widths'),
      const [2],
    ),
    'the park batch widths differ',
  );
  _require(
    _intListsEqual(
      _intsAt(evidence.resume['batchWidths'], 'resume batch widths'),
      const [1],
    ),
    'the resume batch widths differ',
  );
  for (final result in [evidence.baseline, evidence.park, evidence.resume]) {
    _require(
      _resultInt(result, 'setChecks') ==
          _intsAt(result['batchWidths'], 'batch widths').length,
      '${result['kind']} did not compare pending ids as sets',
    );
  }
}

void _checkParkedAtApproval(_Evidence evidence) {
  final checkpoint = evidence.checkpoint;
  _require(
    _intAt(checkpoint['version'], 'checkpoint version') == 1,
    'the checkpoint version differs',
  );
  _require(
    _stringAt(checkpoint['functionName'], 'checkpoint functionName') ==
        'human.approve',
    'the checkpoint is not the approval call',
  );
  _require(
    _stringListsEqual(
      _stringsAt(checkpoint['args'], 'checkpoint args'),
      _approvalArgs,
    ),
    'the checkpointed approval args differ',
  );
  _require(
    _objectAt(checkpoint['kwargs'], 'checkpoint kwargs').isEmpty,
    'the checkpoint kwargs are not empty',
  );
  _require(
    _intAt(checkpoint['pendingSearchCount'], 'checkpoint pendingSearchCount') ==
        0,
    'the checkpoint has pending searches',
  );
  _require(
    _intListsEqual(
      _intsAt(checkpoint['batchWidths'], 'checkpoint batch widths'),
      const [2],
    ),
    'the checkpoint batch widths differ',
  );
  _require(evidence.snapshotBytes > 0, 'the parked snapshot dump is empty');
  _require(
    evidence.parkedOnlySearches,
    'the parked journal held more than the two searches',
  );
}

void _checkWorkerReleased(_Evidence evidence) {
  _require(
    evidence.parkExitCode == 0,
    'the park child exited with ${evidence.parkExitCode}',
  );
  _require(
    _resultInt(evidence.park, 'workerPid') > 0,
    'the parked worker pid is not positive',
  );
  _require(
    evidence.park.containsKey('closedWorkerPid') &&
        evidence.park['closedWorkerPid'] == null,
    'the closed worker pid was not recorded as null',
  );
}

void _checkHostRestarted(_Evidence evidence) {
  final parkPid = _resultInt(evidence.park, 'hostPid');
  final resumePid = _resultInt(evidence.resume, 'hostPid');
  _require(parkPid > 0 && resumePid > 0, 'a child recorded no Dart process id');
  _require(parkPid != resumePid, 'park and resume shared one Dart process');
}

void _checkWorkerRestarted(_Evidence evidence) {
  final parkPid = _resultInt(evidence.park, 'workerPid');
  final resumePid = _resultInt(evidence.resume, 'workerPid');
  _require(parkPid > 0 && resumePid > 0, 'a child recorded no worker pid');
  _require(parkPid != resumePid, 'park and resume shared one worker');
}

void _checkRestoredApproval(_Evidence evidence) {
  final restored = _objectAt(
    evidence.resume['restored'],
    'the restored snapshot',
  );
  final checkpoint = evidence.checkpoint;
  final name = _stringAt(restored['functionName'], 'restored functionName');
  _require(name == 'human.approve', 'the restored call is $name');
  _require(
    name == _stringAt(checkpoint['functionName'], 'checkpoint functionName'),
    'the restored call name differs from the checkpoint',
  );
  _require(
    _intAt(restored['callId'], 'restored callId') ==
        _intAt(checkpoint['callId'], 'checkpoint callId'),
    'the restored call id differs from the checkpoint',
  );
  _require(
    _stringListsEqual(
      _stringsAt(restored['args'], 'restored args'),
      _stringsAt(checkpoint['args'], 'checkpoint args'),
    ),
    'the restored approval args differ from the checkpoint',
  );
  _require(
    _objectAt(restored['kwargs'], 'restored kwargs').isEmpty &&
        _objectAt(checkpoint['kwargs'], 'checkpoint kwargs').isEmpty,
    'the approval carried keyword arguments',
  );
  _require(
    _resultInt(evidence.resume, 'approvalRequestsAtRestore') == 1,
    'approve:1 was not requested exactly once before the restore',
  );
  _require(
    _intAt(_invocations(evidence.resume)['approve:1'], 'resume approve:1') == 1,
    'the rebuilt approve callback did not run exactly once',
  );
  _require(
    evidence.offlineAnswer == 'approved',
    'the offline approval answered ${evidence.offlineAnswer}',
  );
}

void _checkJournalReplay(_Evidence evidence) {
  final requests = _countsOf(evidence.baselineJournal, 'requests');
  final replays = _countsOf(evidence.baselineJournal, 'replays');
  _require(
    _intAt(requests['search:a'], 'baseline requests search:a') == 2,
    'baseline search:a requests differ',
  );
  _require(
    _intAt(replays['search:a'], 'baseline replays search:a') == 1,
    'baseline search:a replays differ',
  );
  for (final opId in const ['search:b', 'approve:1', 'enrich:1', 'publish:1']) {
    _require(
      _intAt(requests[opId], 'baseline requests $opId') == 1,
      'baseline $opId requests differ',
    );
    _require(
      _intAt(replays[opId], 'baseline replays $opId') == 0,
      'baseline $opId replays differ',
    );
  }
  final restartRequests = _countsOf(evidence.restartJournal, 'requests');
  final restartReplays = _countsOf(evidence.restartJournal, 'replays');
  _require(
    _intAt(restartRequests['search:a'], 'restart requests search:a') == 2,
    'restart search:a requests differ',
  );
  _require(
    _intAt(restartReplays['search:a'], 'restart replays search:a') == 1,
    'restart search:a replays differ',
  );
  _require(
    _intAt(restartRequests['approve:1'], 'restart requests approve:1') == 2,
    'restart approve:1 requests differ',
  );
  _require(
    _intAt(restartReplays['approve:1'], 'restart replays approve:1') == 1,
    'restart approve:1 replays differ',
  );
  for (final opId in const ['search:b', 'enrich:1', 'publish:1']) {
    _require(
      _intAt(restartRequests[opId], 'restart requests $opId') == 1,
      'restart $opId requests differ',
    );
    _require(
      _intAt(restartReplays[opId], 'restart replays $opId') == 0,
      'restart $opId replays differ',
    );
  }
}

void _checkEffectsOnce(_Evidence evidence) {
  for (final journal in [evidence.baselineJournal, evidence.restartJournal]) {
    final operations = _operationsOf(journal);
    _require(
      operations.length == _opSpecs.length,
      'a journal holds ${operations.length} operations',
    );
    for (final spec in _opSpecs) {
      _require(
        _jsonEquals(operations[spec.id], _specRecord(spec)),
        'operation ${spec.id} differs from its specification',
      );
    }
    final effects = _effectsOf(journal);
    _require(
      effects.length == _opSpecs.length,
      'a journal holds ${effects.length} effect rows',
    );
  }
}

void _checkRestoredToolError(_Evidence evidence) {
  final invocations = _invocations(evidence.resume);
  _require(
    _intAt(invocations['enrich:1'], 'resume enrich:1') == 1 &&
        _intAt(invocations['publish:1'], 'resume publish:1') == 1,
    'the rebuilt enrich and publish callbacks did not each run once',
  );
  final outcome = _objectAt(
    _objectAt(
      _operationsOf(evidence.restartJournal)['enrich:1'],
      'operation enrich:1',
    )['outcome'],
    'the enrich outcome',
  );
  _require(
    _stringAt(outcome['kind'], 'enrich outcome kind') == 'exception',
    'the enrich outcome is not an exception',
  );
  _require(
    _stringAt(outcome['excType'], 'enrich excType') == 'ValueError',
    'the enrich exception type differs',
  );
  _require(
    _stringAt(outcome['message'], 'enrich message') == 'catalog offline',
    'the enrich message differs',
  );
  _require(
    _stringAt(
      evidence.resume['report'],
      'resume report',
    ).contains('fallback:catalog offline'),
    'the resumed report lacks the fallback',
  );
}

void _checkReportMatches(_Evidence evidence) {
  _require(
    _stringAt(evidence.baseline['report'], 'baseline report') ==
        _expectedReport,
    'the baseline report differs',
  );
  _require(
    _stringAt(evidence.resume['report'], 'resume report') == _expectedReport,
    'the resumed report differs',
  );
}

void _checkDumpLimitRetained(_Evidence evidence) {
  _require(
    evidence.resume['depth100Rejected'] == true,
    'depth(100) did not raise in the restored session',
  );
  _require(
    _resultInt(evidence.resume, 'depth40') == 40,
    'depth(40) did not return 40',
  );
}

void _checkLooseLimitControl(_Evidence evidence) {
  _require(
    _resultInt(evidence.resume, 'freshDepth100') == 100,
    'a fresh destination session did not return depth(100)',
  );
}

// ── The sessions and pools every child uses ──────────────────────────────────

const ResourceLimits _sourceLimits = ResourceLimits(
  maxRecursionDepth: 50,
  maxSuspensions: 100,
);

const ResourceLimits _destinationLimits = ResourceLimits(
  maxRecursionDepth: 500,
  maxSuspensions: 1000,
);

Future<Monty> _startPool() =>
    Monty.start(maxProcesses: 1, requestTimeout: const Duration(seconds: 30));

Future<MontySession> _openSession(
  Monty monty,
  _AgentState agent, {
  required bool destination,
}) => monty.checkout(
  typeCheck: true,
  externalModules: {'tools': agent.tools, 'human': agent.human},
  limits: destination ? _destinationLimits : _sourceLimits,
);

// ── The baseline child: an uninterrupted run ─────────────────────────────────

Future<Map<String, Object?>> _runBaseline(String directory) async {
  final journal = await _journalCreate(File(_path(directory, 'journal.json')));
  final agent = _buildAgent(journal);
  final monty = await _startPool();
  try {
    final session = await _openSession(monty, agent, destination: false);
    try {
      final driver = _startDriver(agent.search);
      final done = await _drive(driver, await session.feedStart(_agentSource));
      final workerPid = _positiveWorkerPid(session.workerPid, 'baseline');

      return {
        'version': 1,
        'kind': 'baseline',
        ..._stubChecks(agent),
        'imports': _count(driver, 'import'),
        'importStubs': _count(driver, 'import_stubs'),
        'invocations': Map.of(agent.invocations),
        'batchWidths': [...driver.batchWidths],
        'setChecks': _count(driver, 'set_checks'),
        'hostPid': pid,
        'workerPid': workerPid,
        'report': _reportText(done),
      };
    } finally {
      await session.close();
    }
  } finally {
    await monty.close();
  }
}

// ── The park child: stop at the approval, dump, release the worker ───────────

Future<Map<String, Object?>> _runPark(String directory) async {
  final journal = await _journalCreate(File(_path(directory, 'journal.json')));
  final agent = _buildAgent(journal);
  final monty = await _startPool();
  try {
    final session = await _openSession(monty, agent, destination: false);
    Map<String, Object?> result;
    try {
      final driver = _startDriver(agent.search);
      final parked = await _drive(
        driver,
        await session.feedStart(_agentSource),
        stopAtApproval: true,
      );
      final approval = _approvalSnapshot(parked);
      final dump = await approval.dump();
      _require(dump.isNotEmpty, 'the parked dump is empty');
      await _writeBytes(File(_path(directory, 'snapshot.bin')), dump);
      final workerPid = _positiveWorkerPid(session.workerPid, 'parked');
      await _writeJson(
        File(_path(directory, 'checkpoint.json')),
        _checkpoint(approval, workerPid, driver),
      );
      result = {
        'version': 1,
        'kind': 'park',
        ..._stubChecks(agent),
        'imports': _count(driver, 'import'),
        'importStubs': _count(driver, 'import_stubs'),
        'invocations': Map.of(agent.invocations),
        'batchWidths': [...driver.batchWidths],
        'setChecks': _count(driver, 'set_checks'),
        'hostPid': pid,
        'workerPid': workerPid,
      };
    } finally {
      await session.close();
    }
    result['closedWorkerPid'] = session.workerPid;

    return result;
  } finally {
    await monty.close();
  }
}

FunctionSnapshot _approvalSnapshot(MontySnapshot parked) {
  if (parked case FunctionSnapshot approval) {
    _require(
      approval.functionName == 'human.approve',
      'parked on ${approval.functionName}',
    );

    return approval;
  }
  throw StateError('the feed did not park on the approval call');
}

Map<String, Object?> _checkpoint(
  FunctionSnapshot approval,
  int workerPid,
  _DriverState driver,
) => {
  'version': 1,
  'functionName': approval.functionName,
  'args': [
    for (final arg in approval.args) _stringValue(arg, 'approval argument'),
  ],
  'kwargs': <String, Object?>{},
  'callId': approval.callId,
  'hostPid': pid,
  'workerPid': workerPid,
  'pendingSearchCount': 0,
  'batchWidths': [...driver.batchWidths],
};

// ── The resume child: load the dump, finish, prove the limits ────────────────

Future<Map<String, Object?>> _runResume(String directory) async {
  final journal = await _journalOpen(File(_path(directory, 'journal.json')));
  final approvalRequests = _intAt(
    _countsOf(journal, 'requests')['approve:1'],
    'requests approve:1',
  );
  _require(
    approvalRequests == 1,
    'approve:1 was requested $approvalRequests times before the restore',
  );
  final agent = _buildAgent(journal);
  final monty = await _startPool();
  try {
    final result = await _restoredRun(
      monty,
      agent,
      directory,
      approvalRequests,
    );
    result['freshDepth100'] = await _freshDepth100(monty, agent);

    return result;
  } finally {
    await monty.close();
  }
}

/// The restored session's own run: load the dump, finish the agent, prove
/// the dump's ceiling and the typed rejection.
Future<Map<String, Object?>> _restoredRun(
  Monty monty,
  _AgentState agent,
  String directory,
  int approvalRequests,
) async {
  final session = await _openSession(monty, agent, destination: true);
  try {
    final restored = await _loadParkedApproval(session, directory);
    final workerPid = _positiveWorkerPid(session.workerPid, 'restored');
    final driver = _startDriver(agent.search);
    final done = await _drive(driver, restored.approval);
    final probeRejected = await _probeRejected(session, agent);
    final depth100Rejected = await _depth100Rejected(session, agent);
    final depth40 = await _depthResult(session, agent, 40);

    return {
      'version': 1,
      'kind': 'resume',
      ..._stubChecks(agent),
      'imports': _count(driver, 'import'),
      'importStubs': _count(driver, 'import_stubs'),
      'invocations': Map.of(agent.invocations),
      'batchWidths': [...driver.batchWidths],
      'setChecks': _count(driver, 'set_checks'),
      'hostPid': pid,
      'workerPid': workerPid,
      'report': _reportText(done),
      'approvalRequestsAtRestore': approvalRequests,
      'restored': restored.metadata,
      'probeRejected': probeRejected,
      'depth100Rejected': depth100Rejected,
      'depth40': depth40,
    };
  } finally {
    await session.close();
  }
}

/// A fresh destination session, without a restore, keeps the loose limit.
Future<int> _freshDepth100(Monty monty, _AgentState agent) async {
  final fresh = await _openSession(monty, agent, destination: true);
  try {
    return await _depthResult(fresh, agent, 100);
  } finally {
    await fresh.close();
  }
}

/// Loads snapshot.bin into a fresh destination session and checks it
/// against checkpoint.json.
Future<({FunctionSnapshot approval, Map<String, Object?> metadata})>
_loadParkedApproval(MontySession session, String directory) async {
  final dumpFile = File(_path(directory, 'snapshot.bin'));
  _require(dumpFile.existsSync(), 'snapshot.bin is missing');
  final dump = await dumpFile.readAsBytes();
  _require(dump.isNotEmpty, 'snapshot.bin is empty');
  final snapshot = await session.loadSnapshot(dump);
  if (snapshot case FunctionSnapshot approval) {
    final checkpoint = _objectAt(
      jsonDecode(
        await File(_path(directory, 'checkpoint.json')).readAsString(),
      ),
      'checkpoint',
    );
    final args = _checkpointedArgs(approval, checkpoint);

    return (
      approval: approval,
      metadata: {
        'functionName': approval.functionName,
        'args': args,
        'kwargs': <String, Object?>{},
        'callId': approval.callId,
      },
    );
  }
  throw StateError('the restored snapshot is not a function call');
}

/// The approval's string arguments, after checking the restored call
/// against the checkpoint: same name, call id, args and empty kwargs.
List<String> _checkpointedArgs(
  FunctionSnapshot approval,
  Map<String, Object?> checkpoint,
) {
  final savedName = _stringAt(
    checkpoint['functionName'],
    'checkpoint functionName',
  );
  _require(
    approval.functionName == 'human.approve',
    'the restored call is ${approval.functionName}',
  );
  _require(
    approval.functionName == savedName,
    'the restored call name differs from the checkpoint',
  );
  _require(
    approval.callId == _intAt(checkpoint['callId'], 'checkpoint callId'),
    'the restored call id differs from the checkpoint',
  );
  final args = [
    for (final arg in approval.args) _stringValue(arg, 'approval argument'),
  ];
  _require(
    _stringListsEqual(args, _stringsAt(checkpoint['args'], 'checkpoint args')),
    'the restored approval args differ',
  );
  _require(
    approval.kwargs.isEmpty,
    'the restored approval carried keyword arguments',
  );

  return args;
}

/// The mistyped publish is rejected by the restored session's type check,
/// before any callback runs.
Future<bool> _probeRejected(MontySession session, _AgentState agent) async {
  final before = Map.of(agent.invocations);
  await _requireTypingError(session, _probeSource, 'the mistyped publish');
  final extra = <String>[
    for (final entry in agent.invocations.entries)
      if ((before[entry.key] ?? 0) != entry.value) entry.key,
  ];
  _require(extra.isEmpty, 'the probe reached tools: ${extra.join(', ')}');

  return true;
}

/// Requires that the type check rejects [code], and fails when it runs.
Future<void> _requireTypingError(
  MontySession session,
  String code,
  String what,
) async {
  try {
    await session.feedStart(code);
  } on MontyTypingError {
    return;
  }
  throw StateError('the restored session accepted $what');
}

/// depth(100) still hits the dump's recursion ceiling of 50.
Future<bool> _depth100Rejected(MontySession session, _AgentState agent) async {
  try {
    await _depthResult(session, agent, 100);
  } on MontyRuntimeError catch (error) {
    final excType = error.exception.excType;
    _require(excType == 'RecursionError', 'depth(100) raised $excType');

    return true;
  }
  throw StateError('depth(100) completed in the restored session');
}

Future<int> _depthResult(
  MontySession session,
  _AgentState agent,
  int depth,
) async {
  final driver = _startDriver(agent.search);
  final done = await _drive(
    driver,
    await session.feedStart(_depthScript(depth)),
  );

  return _intValue(_outputOf(done), 'depth($depth)');
}

// ── The agent: rebuilt modules with journaling callbacks ─────────────────────

/// A host callback, as the sandbox calls it.
typedef _HostArgs = List<MontyValue>;
typedef _HostKwargs = Map<String, MontyValue>;
typedef _HostCallback = FutureOr<MontyValue> Function(_HostArgs, _HostKwargs);

/// One journaling callback for [function]: it validates the call, records
/// the invocation, and answers from the journal.
_HostCallback _journalCallback(
  _JournalState journal,
  Map<String, int> invocations,
  String function,
) => (args, kwargs) {
  _require(kwargs.isEmpty, '$function received keyword arguments');
  final values = [
    for (final arg in args) _stringValue(arg, '$function argument'),
  ];
  final opId = _headOf(values, function);
  _bump(invocations, opId);

  return _journalExecute(journal, opId, function, values);
};

_AgentState _buildAgent(_JournalState journal) {
  final invocations = <String, int>{};
  final callback = (String function) =>
      _journalCallback(journal, invocations, function);
  final search = MontyHostFunction(
    'search',
    coroutine(callback('tools.search')),
  );
  final enrich = MontyHostFunction('enrich', callback('tools.enrich'));
  final publish = MontyHostFunction('publish', callback('tools.publish'));
  final approve = MontyHostFunction('approve', callback('human.approve'));

  return (
    journal: journal,
    invocations: invocations,
    tools: ExternalModule({
      'search': search,
      'enrich': enrich,
      'publish': publish,
    }, stubs: _toolsStubs),
    human: ExternalModule({'approve': approve}, stubs: _humanStubs),
    search: search,
  );
}

// ── The feedStart drive loop every phase runs ────────────────────────────────

_DriverState _startDriver(MontyHostFunction search) => (
  search: search,
  captures: <int, (List<MontyValue>, Map<String, MontyValue>)>{},
  counters: <String, int>{},
  batchWidths: <int>[],
);

/// Drives [first] to completion, or to the approval when [stopAtApproval].
Future<MontySnapshot> _drive(
  _DriverState driver,
  MontySnapshot first, {
  bool stopAtApproval = false,
}) async {
  var snapshot = first;
  while (snapshot is! MontyComplete) {
    final next = await _driveStep(driver, snapshot, stopAtApproval);
    if (next == null) {
      return snapshot;
    }
    snapshot = next;
  }
  _require(driver.captures.isEmpty, 'the feed completed with pending searches');

  return snapshot;
}

Future<MontySnapshot?> _driveStep(
  _DriverState driver,
  MontySnapshot snapshot,
  bool stopAtApproval,
) {
  switch (snapshot) {
    case FunctionSnapshot call:
      return _driveCall(driver, call, stopAtApproval);
    case FutureSnapshot futures:
      return _driveFutures(driver, futures);
    case NameLookupSnapshot lookup:
      throw StateError('unexpected name lookup: ${lookup.variableName}');
    case MontyComplete():
      return Future<MontySnapshot?>.value(snapshot);
  }
}

Future<MontySnapshot?> _driveCall(
  _DriverState driver,
  FunctionSnapshot call,
  bool stopAtApproval,
) {
  if (call.isOsFunction) {
    return _driveOsCall(driver, call);
  }
  switch (call.functionName) {
    case 'tools.search':
      return _captureSearch(driver, call);
    case 'human.approve':
      return _answerApproval(driver, call, stopAtApproval);
    case 'tools.enrich':
      return _answerPlainTool(call, 'tools.enrich');
    case 'tools.publish':
      return _answerPlainTool(call, 'tools.publish');
    default:
      throw StateError('unexpected function snapshot: ${call.functionName}');
  }
}

/// Imports are OS function snapshots; resumeAuto supplies the configured
/// module values and stubs. Anything else is unexpected.
Future<MontySnapshot> _driveOsCall(_DriverState driver, FunctionSnapshot call) {
  final name = call.functionName;
  _require(
    name == 'import' || name == 'import_stubs',
    'unexpected OS function snapshot: $name',
  );
  _bump(driver.counters, name);

  return call.resumeAuto();
}

/// A search becomes a pending future, so asyncio.gather fans out: capture
/// the call, keyed by its call id, and settle it at the futures snapshot.
Future<MontySnapshot> _captureSearch(
  _DriverState driver,
  FunctionSnapshot call,
) {
  _require(call.kwargs.isEmpty, 'tools.search received keyword arguments');
  _require(
    !driver.captures.containsKey(call.callId),
    'duplicate tools.search call id ${call.callId}',
  );
  driver.captures[call.callId] = (List.of(call.args), Map.of(call.kwargs));

  return call.resume(const ExternalFuture());
}

Future<MontySnapshot?> _answerApproval(
  _DriverState driver,
  FunctionSnapshot call,
  bool stopAtApproval,
) {
  _require(!call.isOsFunction, 'the approval arrived as an OS call');
  _require(call.kwargs.isEmpty, 'human.approve received keyword arguments');
  final args = [
    for (final arg in call.args) _stringValue(arg, 'human.approve argument'),
  ];
  _require(
    _stringListsEqual(args, _approvalArgs),
    'human.approve args differ: ${jsonEncode(args)}',
  );
  _require(
    driver.captures.isEmpty,
    'the approval arrived with pending searches',
  );
  if (stopAtApproval) {
    return Future<MontySnapshot?>.value(null);
  }

  return call.resumeAuto();
}

Future<MontySnapshot> _answerPlainTool(FunctionSnapshot call, String name) {
  _require(call.kwargs.isEmpty, '$name received keyword arguments');

  return call.resumeAuto();
}

/// Every task waits on the captured searches: run the rebuilt callbacks
/// together, then settle each pending future with its value. The pending
/// ids are compared as sets, never in order.
Future<MontySnapshot> _driveFutures(
  _DriverState driver,
  FutureSnapshot futures,
) async {
  final pending = futures.pendingCallIds;
  _require(pending.isNotEmpty, 'a futures snapshot with no pending calls');
  final pendingSet = Set.of(pending);
  _require(
    pendingSet.length == pending.length,
    'duplicate pending call ids: $pending',
  );
  _require(
    _sameIntSets(pendingSet, driver.captures.keys.toSet()),
    'the pending call ids do not match the captured searches',
  );
  driver.batchWidths.add(pending.length);
  _bump(driver.counters, 'set_checks');
  final values = await Future.wait([
    for (final id in pending) _searchAnswer(driver, id),
  ]);
  final answers = <int, ExternalSettledResult>{};
  final settled = values.iterator;
  for (final id in pending) {
    settled.moveNext();
    answers[id] = ExternalReturnValue(settled.current);
  }
  driver.captures.clear();

  return futures.resume(answers);
}

Future<MontyValue> _searchAnswer(_DriverState driver, int id) {
  final call = driver.captures[id];
  if (call == null) {
    throw StateError('no captured search for call $id');
  }

  return Future.sync(() => driver.search.fn(call.$1, call.$2));
}

// ── The journal: version-1 JSON, effects committed with their answers ────────

Future<_JournalState> _journalCreate(File file) async {
  final journal = (
    file: file,
    data: <String, Object?>{
      'version': 1,
      'operations': <String, Object?>{},
      'effects': <Object?>[],
      'requests': <String, Object?>{},
      'replays': <String, Object?>{},
    },
  );
  _journalValidate(journal);
  await _journalCommit(journal);

  return journal;
}

Future<_JournalState> _journalOpen(File file) async {
  _require(file.existsSync(), 'the journal ${file.path} is missing');
  final journal = (
    file: file,
    data: _objectAt(jsonDecode(await file.readAsString()), 'the journal root'),
  );
  _journalValidate(journal);

  return journal;
}

/// Answers [opId] as [function] called with [args]. A repeat verifies the
/// call against the stored specification, increments requests and replays,
/// and replays the persisted outcome; a first call stores the operation and
/// exactly one matching effect row. Either way the effect and its answer
/// are committed together, before the answer is used. Operations on one
/// journal serialize, so concurrently awaited callbacks commit in turn.
Future<MontyValue> _journalExecute(
  _JournalState journal,
  String opId,
  String function,
  List<String> args,
) => _withJournalTurn(journal.file.path, () async {
  final spec = _specOf(opId);
  _require(
    spec.function == function && _stringListsEqual(spec.args, args),
    'operation $opId was called as $function ${jsonEncode(args)}',
  );
  final operations = _operationsOf(journal);
  final requests = _countsOf(journal, 'requests');
  final replays = _countsOf(journal, 'replays');
  if (operations.containsKey(opId)) {
    requests[opId] = _intAt(requests[opId], 'requests $opId') + 1;
    replays[opId] = _intAt(replays[opId], 'replays $opId') + 1;
  } else {
    final record = _specRecord(spec);
    operations[opId] = record;
    _effectsOf(journal).add({'id': opId, ...record});
    requests[opId] = 1;
    replays[opId] = 0;
  }
  _journalValidate(journal);
  await _journalCommit(journal);

  return _outcomeAnswer(
    _objectAt(operations[opId], 'operation $opId')['outcome'],
  );
});

/// The pending turn of each journal, by path.
final Map<String, Future<void>> _journalTurns = <String, Future<void>>{};

/// Runs [action] alone among the operations on one journal: each turn
/// awaits the previous one, and always releases the next.
Future<T> _withJournalTurn<T>(String path, Future<T> Function() action) async {
  final waiting = _journalTurns[path];
  final release = Completer<void>();
  _journalTurns[path] = release.future;
  try {
    if (waiting != null) {
      await waiting;
    }

    return await action();
  } finally {
    release.complete();
  }
}

/// The journal transaction: write the whole document to a sibling temporary
/// file with a disk flush, and replace the journal by rename, so an effect
/// and its answer land together.
Future<void> _journalCommit(_JournalState journal) async {
  final temp = File('${journal.file.path}.tmp');
  await temp.writeAsString(
    const JsonEncoder.withIndent('  ').convert(journal.data),
    flush: true,
  );
  await temp.rename(journal.file.path);
}

void _journalValidate(_JournalState journal) {
  _require(
    _intAt(journal.data['version'], 'journal version') == 1,
    'the journal version differs',
  );
  final operations = _operationsOf(journal);
  _require(
    operations.keys.every(_isKnownId),
    'the journal holds unknown operation ids',
  );
  _require(
    _sameStringSets(
          operations.keys.toSet(),
          _countsOf(journal, 'requests').keys.toSet(),
        ) &&
        _sameStringSets(
          operations.keys.toSet(),
          _countsOf(journal, 'replays').keys.toSet(),
        ),
    'operations, requests and replays key sets differ',
  );
  for (final spec in _opSpecs) {
    final stored = operations[spec.id];
    if (stored != null) {
      _require(
        _jsonEquals(stored, _specRecord(spec)),
        'operation ${spec.id} differs from its specification',
      );
    }
  }
  _validateCounts(journal);
  _validateEffects(journal);
}

bool _isKnownId(String id) => _opSpecs.any((spec) => spec.id == id);

void _validateCounts(_JournalState journal) {
  final requests = _countsOf(journal, 'requests');
  final replays = _countsOf(journal, 'replays');
  for (final entry in requests.entries) {
    final count = _intAt(entry.value, 'requests ${entry.key}');
    _require(count >= 1, 'requests ${entry.key} is not positive');
    _require(
      _intAt(replays[entry.key], 'replays ${entry.key}') == count - 1,
      'replays ${entry.key} is not requests - 1',
    );
  }
}

void _validateEffects(_JournalState journal) {
  final effects = _effectsOf(journal);
  final expected = <String, Object?>{};
  for (final entry in _operationsOf(journal).entries) {
    final record = _objectAt(entry.value, 'operation ${entry.key}');
    expected[entry.key] = {'id': entry.key, ...record};
  }
  _require(
    effects.length == expected.length,
    'the journal holds unmatched effect rows',
  );
  for (final row in effects) {
    final effect = _objectAt(row, 'effect row');
    if (effect['id'] case String idText) {
      final match = expected.remove(idText);
      _require(
        match != null && _jsonEquals(effect, match),
        'the effect row $idText does not match its operation',
      );
    } else {
      throw StateError('an effect row id is not a string');
    }
  }
  _require(
    expected.isEmpty,
    'operations without an effect row: ${expected.keys.toList()}',
  );
}

_OpSpec _specOf(String opId) {
  for (final spec in _opSpecs) {
    if (spec.id == opId) {
      return spec;
    }
  }
  throw StateError('unknown operation $opId');
}

Map<String, Object?> _specRecord(_OpSpec spec) => {
  'function': spec.function,
  'args': [...spec.args],
  'outcome': {...spec.outcome},
};

MontyValue _outcomeAnswer(Object? outcome) {
  final record = _objectAt(outcome, 'an outcome');
  switch (record['kind']) {
    case 'value':
      return MontyString(_stringAt(record['value'], 'an outcome value'));
    case 'exception':
      throw ExternalException(
        _stringAt(record['excType'], 'an outcome excType'),
        _stringAt(record['message'], 'an outcome message'),
      );
    default:
      throw StateError('an unknown outcome kind: ${record['kind']}');
  }
}

Map<String, Object?> _operationsOf(_JournalState journal) =>
    _objectAt(journal.data['operations'], 'operations');

List<Object?> _effectsOf(_JournalState journal) =>
    switch (journal.data['effects']) {
      List<Object?> list => list,
      _ => throw StateError('the journal effects are not a list'),
    };

Map<String, Object?> _countsOf(_JournalState journal, String key) =>
    _objectAt(journal.data[key], key);

// ── Small helpers ────────────────────────────────────────────────────────────

void _require(bool ok, String message) {
  if (!ok) {
    throw StateError('durable agent: $message');
  }
}

void _bump(Map<String, int> counters, String key) {
  final current = counters[key];
  counters[key] = current == null ? 1 : current + 1;
}

String _path(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

int _positiveWorkerPid(int? pidValue, String what) {
  if (pidValue case int positive when positive > 0) {
    return positive;
  }
  throw StateError('durable agent: the $what worker pid is not positive');
}

String _reportText(MontySnapshot done) =>
    _stringValue(_outputOf(done), 'the report');

MontyValue _outputOf(MontySnapshot done) {
  if (done case MontyComplete complete) {
    return complete.output;
  }
  throw StateError('the feed parked instead of completing');
}

Map<String, Object?> _stubChecks(_AgentState agent) => {
  'toolsStubsExact': agent.tools.stubs == _toolsStubs,
  'humanStubsExact': agent.human.stubs == _humanStubs,
};

int _count(_DriverState driver, String key) => driver.counters[key] ?? 0;

Future<void> _writeJson(File file, Map<String, Object?> data) =>
    file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(data),
      flush: true,
    );

Future<void> _writeBytes(File file, List<int> bytes) =>
    file.writeAsBytes(bytes, flush: true);

Map<String, Object?> _objectAt(Object? value, String what) => switch (value) {
  Map<String, Object?> map => map,
  _ => throw StateError('$what is not an object'),
};

int _intAt(Object? value, String what) => switch (value) {
  int number => number,
  _ => throw StateError('$what is not an integer'),
};

String _stringAt(Object? value, String what) => switch (value) {
  String text => text,
  _ => throw StateError('$what is not a string'),
};

List<int> _intsAt(Object? value, String what) => switch (value) {
  List<Object?> list => [for (final item in list) _intAt(item, what)],
  _ => throw StateError('$what is not a list'),
};

List<String> _stringsAt(Object? value, String what) => switch (value) {
  List<Object?> list => [for (final item in list) _stringAt(item, what)],
  _ => throw StateError('$what is not a list'),
};

int _resultInt(Map<String, Object?> result, String key) =>
    _intAt(result[key], '${result['kind']} $key');

Map<String, Object?> _invocations(Map<String, Object?> result) =>
    _objectAt(result['invocations'], '${result['kind']} invocations');

String _stringValue(MontyValue value, String what) => switch (value) {
  MontyString(value: final text) => text,
  _ => throw StateError('$what is not a string'),
};

int _intValue(MontyValue value, String what) => switch (value) {
  MontyInt(value: final number) => number,
  _ => throw StateError('$what is not an integer'),
};

String _headOf(List<String> values, String function) {
  if (values case [final head, ...]) {
    return head;
  }
  throw StateError('durable agent: $function received no arguments');
}

bool _stringListsEqual(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  final rightItems = right.iterator;
  for (final item in left) {
    rightItems.moveNext();
    if (item != rightItems.current) {
      return false;
    }
  }

  return true;
}

bool _intListsEqual(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  final rightItems = right.iterator;
  for (final item in left) {
    rightItems.moveNext();
    if (item != rightItems.current) {
      return false;
    }
  }

  return true;
}

bool _sameStringSets(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _sameIntSets(Set<int> left, Set<int> right) =>
    left.length == right.length && left.containsAll(right);

bool _jsonEquals(Object? left, Object? right) {
  if (left case Map<String, Object?> leftMap) {
    if (right case Map<String, Object?> rightMap) {
      return leftMap.length == rightMap.length &&
          leftMap.entries.every(
            (entry) =>
                rightMap.containsKey(entry.key) &&
                _jsonEquals(entry.value, rightMap[entry.key]),
          );
    }

    return false;
  }
  if (left case List<Object?> leftList) {
    if (right case List<Object?> rightList) {
      return leftList.length == rightList.length &&
          _listsJsonEqual(leftList, rightList);
    }

    return false;
  }

  return left == right;
}

bool _listsJsonEqual(List<Object?> left, List<Object?> right) {
  final rightItems = right.iterator;
  for (final item in left) {
    rightItems.moveNext();
    if (!_jsonEquals(item, rightItems.current)) {
      return false;
    }
  }

  return true;
}
