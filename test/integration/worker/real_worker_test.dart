// ProcessChannel against the real worker executable (tool/build_worker.sh, or
// the CI artefact), with raw monty-proto requests: there is no driver yet.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyBigInt, MontyBool, MontyFloat, MontyInt, MontyTuple, MontyValue;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:fixnum/fixnum.dart';
// The corpus manifest is imported from the conformance package's src/ on
// purpose: its public library also exports the generated corpus, and this
// test MEASURES the corpus rather than importing it.
import 'package:monty_conformance/src/worker_corpus_manifest.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../unit/worker/_display_cases.dart';
import '../../unit/worker/_kind_round_trips.dart';
import '_worker_harness.dart';

/// Upstream monty-proto 1.1.0's `PROTOCOL_VERSION`.
const _protocolVersion = 5;

/// Every test bounds the worker's memory: an unbounded worker running away
/// was measured at 6 GB in three minutes.
const int _maxMemory = 64 * 1024 * 1024;

pb.ParentRequest _configure({
  int protocolVersion = _protocolVersion,
  int maxMemory = _maxMemory,
}) => pb.ParentRequest(
  configure: pb.Configure(
    scriptName: 'main.py',
    protocolVersion: protocolVersion,
    limits: pb.ResourceLimits(maxMemoryBytes: Int64(maxMemory)),
  ),
);

pb.ParentRequest _feed(String code) => pb.ParentRequest(
  feed: pb.Feed(code: code, cwd: '/'),
);

/// The [MontyCrashedError] that [future] fails with (see
/// process_channel_test.dart for why through the matcher).
Future<MontyCrashedError> _crashOf(Future<Object?> future) async {
  MontyCrashedError? seen;
  await expectLater(
    future,
    throwsA(
      isA<MontyCrashedError>().having((e) => seen = e, 'error', isNotNull),
    ),
  );

  return seen ?? fail('the matcher saw no MontyCrashedError');
}

/// A configured real worker, closed after the test.
Future<ProcessChannel> _configured({int maxMemory = _maxMemory}) async {
  final channel = await ProcessChannel.spawn(await realWorker());
  addTearDown(channel.close);
  final ok = await channel.turn(_configure(maxMemory: maxMemory));
  expect(ok.whichKind(), pb.ChildEvent_Kind.ok);

  return channel;
}

/// The int a `Complete` carries at its root node.
int _completeInt(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete);
  final complete = event.complete;
  final root = complete.values.nodes.elementAtOrNull(complete.value);
  expect(root?.whichKind(), pb.MontyNode_Kind.int_5);

  return root == null
      ? fail('no root node in $complete')
      : intOfNode(root).toInt();
}

/// The value a `Complete` carries, decoded by the arena reader.
MontyValue _completeValue(pb.ChildEvent event) {
  expect(event.whichKind(), pb.ChildEvent_Kind.complete, reason: '$event');

  return ArenaReader(event.complete.values)[event.complete.value];
}

BigInt _bigOf(MontyValue v) => switch (v) {
  MontyInt(:final value) => BigInt.from(value),
  MontyBigInt(:final value) => value,
  _ => fail('$v is not an integer'),
};

/// A feed of [code] with each of [inputs] bound under its name.
pb.ParentRequest _feedWith(String code, Map<String, MontyValue> inputs) {
  final writer = ArenaWriter();
  final refs = [
    for (final MapEntry(:key, :value) in inputs.entries)
      pb.NamedRef(name: key, value: writer.add(value)),
  ];

  return pb.ParentRequest(
    feed: pb.Feed(code: code, cwd: '/', inputs: refs, values: writer.arena),
  );
}

/// The artefact checks, in the order the gate runs them: the committed
/// assets against the sources they are built from, the worker executable
/// against its build, and the wasm against its download budget. Every script
/// verifies: none of them rebuilds, re-records the provenance or fetches
/// anything.
const List<({String script, List<String> arguments})> _artefactChecks = [
  (script: 'tool/check_asset_freshness.sh', arguments: <String>[]),
  (script: 'tool/build_worker.sh', arguments: ['--check']),
  (script: 'tool/check_worker_wasm_size.sh', arguments: <String>[]),
];

void main() {
  expectNoWorkersLeftAfterEachTest();

  test('locates the built worker for this host', () async {
    final launch = await locateWorker(
      cache: WorkerCacheSource(manifest: WorkerManifest(targets: {})),
    );
    expect(
      launch,
      isA<WorkerExecutable>().having(
        (w) => w.path,
        'path',
        endsWith(workerPackagePath(Abi.current())),
      ),
    );
  });

  test('the artefacts match their sources', () async {
    for (final check in _artefactChecks) {
      final result = await Process.run(
        'bash',
        [check.script, ...check.arguments],
      );
      expect(
        result.exitCode,
        0,
        reason:
            'bash ${check.script} ${check.arguments.join(' ')} must pass:\n'
            '${result.stdout}\n${result.stderr}',
      );
    }
  });

  test('integers across the i64 range decode exactly', () async {
    // package:protobuf's own zigzag decoding gets four of these wrong.
    final channel = await _configured();
    for (final code in [
      '2**62 - 1',
      '2**62',
      '-2**62',
      '-2**62 - 1',
      '2**63 - 1',
      '-2**63',
      '2**64',
      '-2**64',
    ]) {
      final want = _pythonPower(code);
      expect(
        _bigOf(_completeValue(await channel.turn(_feed(code)))),
        want,
        reason: code,
      );
    }
  });

  test('integers at the i64 edges reach Python exactly', () async {
    final channel = await _configured();
    final top = (BigInt.one << 63) - BigInt.one;
    final bottom = -(BigInt.one << 63);
    final v = _completeValue(
      await channel.turn(
        _feedWith(
          '(a == 2**63 - 1, b == -2**63, c == 2**62, d == -2**62 - 1, a, b)',
          {
            'a': MontyBigInt(top),
            'b': MontyBigInt(bottom),
            'c': MontyBigInt(BigInt.one << 62),
            'd': MontyBigInt(-(BigInt.one << 62) - BigInt.one),
          },
        ),
      ),
    );
    final items = (v as MontyTuple).items;
    expect(items.take(4), everyElement(const MontyBool(true)));
    expect(_bigOf(itemAt(items, 4)), top);
    expect(_bigOf(itemAt(items, 5)), bottom);
  });

  test("a NaN's sign survives Python -> Dart -> Python", () async {
    final channel = await _configured();
    final nan = _completeValue(await channel.turn(_feed("float('nan')")));
    final negative = _completeValue(
      await channel.turn(_feed("-float('nan')")),
    );
    expect(_bits(nan), '7ff8000000000000');
    expect(_bits(negative), 'fff8000000000000');
    // Python sees the sign of the NaN it is given, and hands back the same
    // bits.
    final back = _completeValue(
      await channel.turn(
        _feedWith('import math\n(math.copysign(1.0, x), x)', {'x': negative}),
      ),
    );
    final items = (back as MontyTuple).items;
    expect(itemAt(items, 0), const MontyFloat(-1));
    expect(_bits(itemAt(items, 1)), 'fff8000000000000');
  });

  test("a NaN made in Dart reaches Python as float('nan')", () async {
    // double.nan's bits are the host's (fff8... on x86_64); -double.nan
    // flips the sign. Neither came from Python, so both go as 7ff8...
    final channel = await _configured();
    final v = _completeValue(
      await channel.turn(
        _feedWith(
          'import math\n(math.copysign(1.0, a), math.copysign(1.0, b))',
          {
            'a': const MontyFloat(double.nan),
            'b': const MontyFloat(-double.nan),
          },
        ),
      ),
    );
    expect((v as MontyTuple).items, everyElement(const MontyFloat(1)));
  });

  kindRoundTripTests('vm', () async {
    final channel = await _configured();

    return (channel.turn, channel.close);
  });

  displayFixtureTests('vm', () async {
    final channel = await _configured();

    return (channel.turn, channel.close);
  });

  test('Configure, Feed 1 + 1, Shutdown', () async {
    final channel = await _configured();
    expect(_completeInt(await channel.turn(_feed('1 + 1'))), 2);
    await channel.close();
    expect(await channel.exitCode, 0);
  });

  test('prints stream to onPrint before the turn ends', () async {
    final channel = await _configured();
    final text = StringBuffer();
    final end = await channel.turn(
      _feed('print("hello")\n3'),
      onPrint: (print) => text.writeAll([
        for (final segment in print.segments) segment.text,
      ]),
    );
    expect(text.toString(), 'hello\n');
    expect(_completeInt(end), 3);
  });

  test('a Python exception is in-band; the worker survives', () async {
    final channel = await _configured();
    final end = await channel.turn(_feed('1 / 0'));
    expect(end.whichKind(), pb.ChildEvent_Kind.error);
    expect(channel.isAlive, isTrue);
    expect(_completeInt(await channel.turn(_feed('2 + 2'))), 4);
  });

  test('max_memory inside the interpreter is in-band MemoryError', () async {
    final channel = await _configured(maxMemory: 16 * 1024 * 1024);
    final end = await channel.turn(
      _feed('x = []\nwhile True:\n    x.append("a" * 100000)'),
    );
    expect(end.whichKind(), pb.ChildEvent_Kind.error);
    expect(end.error.toString(), contains('MemoryError'));
    expect(channel.isAlive, isTrue);
  });

  test('protocol version skew: FatalError, exit 4', () async {
    final channel = await ProcessChannel.spawn(await realWorker());
    addTearDown(channel.close);
    final crash = await _crashOf(
      channel.turn(_configure(protocolVersion: 999)),
    );
    expect(crash.cause, CrashCause.fatal);
    expect(crash.exitCode, 4);
    expect(crash.toString(), contains('999'));
  });

  test('deadline kill, then a fresh worker answers', () async {
    final channel = await _configured();
    final turn = channel.turn(_feed('while True:\n    pass'));
    Timer(const Duration(milliseconds: 300), channel.kill);
    final crash = await _crashOf(turn);
    expect(crash.cause, CrashCause.killed);
    expect(channel.isAlive, isFalse);

    // Recovery is a new channel; the dead one is never reused.
    final fresh = await ProcessChannel.spawn(await realWorker());
    addTearDown(fresh.close);
    await fresh.turn(_configure());
    expect(_completeInt(await fresh.turn(_feed('1 + 1'))), 2);
  });

  test('release pin and oracle lock target v1.2.0', () {
    expect(_pinnedUpstreamVersion(), '1.2.0');
    expect(_pinnedUpstreamTag(), 'v1.2.0');
    expect(_pinnedUpstreamDistributions(), const {
      'pydantic-monty': '1.2.0',
      'pydantic-monty-client': '1.2.0',
      'pydantic-monty-runtime': '1.2.0',
    });
    expect(_offlineUpstreamPinValidationSucceeds(), isTrue);
  });

  test('worker v1.2.0 dependencies and reviewed mirrors are consistent', () {
    // The manifest is read and checked FIRST: it is the file that still
    // pins monty 1.1.0, so this test fails on that declaration, before any
    // later check runs.
    _expectWorkerManifestPinsV120();

    final packages = _workerLockPackages();
    final versionsByName = _lockVersionsByName(packages);
    _expectWorkerLockResolvesV120(versionsByName);
    _expectMontyHashDependencies(packages, versionsByName);
    _expectPackageVersionsTrackV120();
    _expectLocalMirrorAndVersionChecksPass();
  });

  test('migration test floors and change fragment match completed suites', () {
    // The monty v1.2.0 migration registered its suites -- the pin test above
    // passes -- but nothing followed through: the two floors that count those
    // suites still hold the values they were locked at before it, and
    // changes/ holds no fragment for the upgrade. A floor is raised when a
    // suite grows, never lowered to make a run pass, and a lib/ change lands
    // with its changes/<slug>.md.

    final unitFloor = _gateSuiteFloor('unit_tests');
    expect(
      unitFloor,
      greaterThan(_lockedUnitTestsFloor),
      reason:
          'tool/gate.sh still reads "sf unit_tests '
          '$_lockedUnitTestsFloor"; the migration grew the suite this floor '
          'counts, so the floor moves up with it',
    );
    expect(
      unitFloor,
      greaterThanOrEqualTo(_lockedUnitTestsFloor),
      reason:
          'the unit_tests floor never drops below its locked baseline of '
          '$_lockedUnitTestsFloor',
    );

    final webFloor = _workerWebFloor();
    expect(
      webFloor,
      greaterThan(_lockedWorkerWebFloor),
      reason:
          'tool/test_worker_web.sh still reads "FLOOR='
          '$_lockedWorkerWebFloor"; the migration grew the web suites this '
          'floor counts, so the floor moves up with it',
    );
    expect(
      webFloor,
      greaterThanOrEqualTo(_lockedWorkerWebFloor),
      reason:
          'the worker web floor never drops below its locked baseline of '
          '$_lockedWorkerWebFloor',
    );

    final observed = _observedSuiteCounts();
    expect(
      unitFloor,
      lessThan(_observedCount(observed, 'unit_tests')),
      reason:
          'a raised floor still sits under the observed unit_tests '
          'count, so ordinary churn does not trip it',
    );
    expect(
      webFloor,
      lessThan(_observedCount(observed, 'worker_web')),
      reason:
          'a raised floor still sits under the observed worker_web '
          'count, so ordinary churn does not trip it',
    );

    expect(
      _migrationChangeFragment(),
      isNotEmpty,
      reason:
          'the release upgrade, protocol/imports, Scan, open behavior, '
          'restore limits, exception codecs and BOM correction are '
          'user-visible and belong in a changes/<slug>.md fragment',
    );
  });

  test(
    'v1.2.0 corpus scorecards and capability records match measured '
    'results',
    _corpusScorecardAcceptance,
    timeout: const Timeout(Duration(minutes: 120)),
  );
}

/// The value of a `2**n` expression in [code], as Python computes it.
BigInt _pythonPower(String code) {
  final m = RegExp(r'^(-?)2\*\*(\d+)(?: - 1)?$').firstMatch(code);
  if (m == null) fail('unexpected expression $code');
  final power = BigInt.one << int.parse(m[2] ?? '');
  final signed = m[1] == '-' ? -power : power;

  return code.endsWith(' - 1') ? signed - BigInt.one : signed;
}

/// The IEEE 754 bits of a decoded float, as 16 hex digits.
String _bits(MontyValue v) => switch (v) {
  MontyFloat(:final value) => [
    for (final b in (ByteData(8)..setFloat64(0, value)).buffer.asUint8List())
      b.toRadixString(16).padLeft(2, '0'),
  ].join(),
  _ => fail('$v is not a float'),
};

// The release pin readers below read the records they name: the pin
// tool/upstream/upstream-pin.json and the oracle lock it points at. They
// report what those records say, so 'release pin and oracle lock target
// v1.2.0' fails while the tree still pins an older upstream release.

/// The upstream monty release this core pins: `version` in
/// tool/upstream/upstream-pin.json (upstream pydantic/monty).
String _pinnedUpstreamVersion() => _pinString('version');

/// The git tag recorded in tool/upstream/upstream-pin.json, which must be
/// `v` + the version in [_pinnedUpstreamVersion].
String _pinnedUpstreamTag() => _pinString('tag');

/// The PyPI distributions recorded in the pin's `python.distributions`,
/// the three upstream packages tool/bump_upstream.py's `DIST_NAMES` lock.
Map<String, String> _pinnedUpstreamDistributions() {
  final python = _pinRecord()['python'];
  if (python is! Map<String, Object?>) {
    fail('the upstream pin records no "python" section');
  }
  final distributions = python['distributions'];
  if (distributions is! Map<String, Object?>) {
    fail('the upstream pin records no "python.distributions" section');
  }

  final pinned = <String, String>{};
  for (final entry in distributions.entries) {
    final version = entry.value;
    if (version is! String) {
      fail('the upstream pin records ${entry.key} at no version');
    }
    pinned[entry.key] = version;
  }

  return pinned;
}

/// Whether `python3 -I tool/check_upstream_pin.py` passes offline: record
/// shape and sha256 lock hashes, no network, exit 0.
bool _offlineUpstreamPinValidationSucceeds() {
  final result = Process.runSync(
    'python3',
    ['-I', 'tool/check_upstream_pin.py'],
  );

  return result.exitCode == 0;
}

/// The upstream pin record, read from tool/upstream/upstream-pin.json.
Map<String, Object?> _pinRecord() {
  final file = File('tool/upstream/upstream-pin.json');
  final Object? decoded = json.decode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('${file.path} is not a JSON object');
  }

  return decoded;
}

/// The string the upstream pin record holds at [key], or a failure naming it.
String _pinString(String key) {
  final value = _pinRecord()[key];
  if (value is! String) {
    fail('the upstream pin records no "$key"');
  }

  return value;
}

// The migration follow-through readers below report what the tree holds, not
// what it should hold: the two floors the completed monty v1.2.0
// registrations were supposed to raise, the observed counts those floors must
// stay under, and the changes/<slug>.md fragment recording the upgrade. So
// 'migration test floors and change fragment match completed suites' fails
// while any of the three is still missing.

/// The unit_tests floor as it was locked when the monty v1.2.0 migration
/// began: `sf unit_tests 3211`, tool/gate.sh:270.
const int _lockedUnitTestsFloor = 3211;

/// The worker web floor as it was locked when the monty v1.2.0 migration
/// began: `FLOOR=566`, tool/test_worker_web.sh:44.
const int _lockedWorkerWebFloor = 566;

/// Every topic a `changes/<slug>.md` fragment for the monty v1.2.0 migration
/// must describe, matched case-insensitively by [_migrationChangeFragment]:
/// the release upgrade, protocol/imports, Scan, open behavior, restore
/// limits, exception codecs and BOM correction.
const List<String> _migrationFragmentTopics = [
  '1.2.0',
  'protocol',
  'import',
  'scan',
  'open',
  'restore',
  'limit',
  'exception',
  'codec',
  'bom',
];

/// The count tool/gate.sh asserts under its [suite] step -- the number in
/// its `sf <suite> <count>` line -- or a failure naming the missing line.
int _gateSuiteFloor(String suite) {
  final gate = File('tool/gate.sh').readAsStringSync();
  final match = RegExp(
    '^sf\\s+$suite\\s+(\\d+)',
    multiLine: true,
  ).firstMatch(gate);
  final count = match?[1];
  if (count == null) {
    fail('tool/gate.sh registers no "sf $suite <count>" floor');
  }

  return int.parse(count);
}

/// The count tool/test_worker_web.sh asserts under each compiler run -- the
/// value of its `FLOOR=` line -- or a failure naming the missing assignment.
int _workerWebFloor() {
  final script = File('tool/test_worker_web.sh').readAsStringSync();
  final match = RegExp(
    r'^FLOOR=(\d+)',
    multiLine: true,
  ).firstMatch(script);
  final count = match?[1];
  if (count == null) {
    fail('tool/test_worker_web.sh sets no FLOOR= floor');
  }

  return int.parse(count);
}

/// The observed complete-suite counts the raised floors must stay under,
/// keyed by suite ('unit_tests', 'worker_web').
///
/// STUB: the monty v1.2.0 suites' final counts are not recorded in this
/// bundle and must not be invented, so this returns an empty record, which
/// is wrong for every suite; the `lessThan` assertions fail until the
/// measured counts replace it. It never throws.
Map<String, int> _observedSuiteCounts() => const {};

/// The observed count recorded for [suite] in [observed], or a failure
/// naming the suite nothing was recorded for.
int _observedCount(Map<String, int> observed, String suite) {
  final count = observed[suite];
  if (count == null) {
    fail('no observed complete-suite count is recorded for "$suite"');
  }

  return count;
}

/// The `changes/<slug>.md` fragment recording the monty v1.2.0 migration,
/// or a failure naming what is missing: a markdown file directly under
/// changes/ (README excluded, as tool/check_changelog_fragments.sh does not
/// assemble it) whose text covers every topic in [_migrationFragmentTopics].
String _migrationChangeFragment() {
  final fragments = <String>[
    if (Directory('changes').existsSync())
      for (final entity in Directory('changes').listSync())
        if (entity is File &&
            entity.path.endsWith('.md') &&
            entity.path != 'changes/README.md')
          entity.path,
  ];
  for (final path in fragments) {
    final text = File(path).readAsStringSync().toLowerCase();
    final missing = [
      for (final topic in _migrationFragmentTopics)
        if (!text.contains(topic)) topic,
    ];
    if (missing.isEmpty) {
      return path;
    }
  }

  fail(
    'no changes/<slug>.md fragment describes the monty v1.2.0 migration; one '
    'must cover: ${_migrationFragmentTopics.join(', ')}',
  );
}

// The worker dependency readers below read the two files the worker's build
// depends on -- native/worker/Cargo.toml and native/worker/Cargo.lock -- and
// report what they say. They parse the files themselves, so the test states
// its own expectations instead of trusting a shared schema type: the six
// monty requirements the manifest declares, the eight monty packages the
// lock resolves, and the sha1/sha2 the monty crate brings with it.

// The worker's Cargo manifest: its monty requirements are read from here.
const String _workerManifestPath = 'native/worker/Cargo.toml';

// The worker's Cargo lock: its resolved packages are read from here.
const String _workerLockPath = 'native/worker/Cargo.lock';

// The six monty requirements native/worker/Cargo.toml declares, sorted:
// monty-proto, monty-types and monty-alloc for every target, plus monty-fs,
// monty-alloc and monty-types for the native target.
const List<String> _expectedMontyRequirementNames = [
  'monty-alloc',
  'monty-alloc',
  'monty-fs',
  'monty-proto',
  'monty-types',
  'monty-types',
];

// The eight monty crates the worker's lock resolves, sorted.
const List<String> _expectedMontyLockPackages = [
  'monty',
  'monty-alloc',
  'monty-fs',
  'monty-macros',
  'monty-proto',
  'monty-type-checking',
  'monty-types',
  'monty-typeshed',
];

/// A monty requirement the worker's manifest declares: the dependency table
/// it sits in, the crate name and the version requirement it pins.
typedef _MontyRequirement = ({String table, String name, String version});

/// A package entry in a Cargo lock: its name, the version it resolved to and
/// the dependencies it names.
typedef _LockPackage = ({
  String name,
  String version,
  List<String> dependencies,
});

/// A dependency entry a Cargo manifest declares: the table it sits in, the
/// crate name and the value it declares.
typedef _ManifestEntry = ({String table, String name, String value});

/// The manifest's monty requirements, checked first: the worker declares
/// six of them, and each must pin exactly "=1.2.0".
void _expectWorkerManifestPinsV120() {
  final requirements = _workerManifestMontyRequirements();
  expect(
    requirements.map((requirement) => requirement.name).toList()..sort(),
    _expectedMontyRequirementNames,
    reason:
        'native/worker/Cargo.toml must declare the six monty '
        'requirements the mirror check counts',
  );
  for (final requirement in requirements) {
    expect(
      requirement.version,
      '=1.2.0',
      reason:
          'native/worker/Cargo.toml [${requirement.table}] '
          '${requirement.name} must pin "=1.2.0"',
    );
  }
}

/// The lock's monty packages: exactly the eight the mirror pins, each with
/// one 1.2.0 resolution.
void _expectWorkerLockResolvesV120(Map<String, List<String>> versionsByName) {
  final montyVersions = <String, List<String>>{
    for (final entry in versionsByName.entries)
      if (entry.key.startsWith('monty')) entry.key: entry.value,
  };
  expect(
    montyVersions.keys.toList()..sort(),
    _expectedMontyLockPackages,
    reason:
        'native/worker/Cargo.lock must record exactly the eight monty '
        'crates the mirror pins',
  );
  for (final name in _expectedMontyLockPackages) {
    final versions = montyVersions[name] ?? const <String>[];
    expect(
      versions,
      hasLength(1),
      reason:
          '$name must resolve to exactly one version in '
          'native/worker/Cargo.lock',
    );
    expect(
      versions.singleOrNull,
      '1.2.0',
      reason: '$name must resolve to 1.2.0 in native/worker/Cargo.lock',
    );
  }
}

/// monty's sha1 and sha2 dependencies, and the lock entries they resolve to.
void _expectMontyHashDependencies(
  List<_LockPackage> packages,
  Map<String, List<String>> versionsByName,
) {
  final monty = packages.firstWhereOrNull((package) => package.name == 'monty');
  if (monty == null) {
    fail('$_workerLockPath records no monty package');
  }
  for (final hash in const ['sha1', 'sha2']) {
    final dependency = _lockDependency(monty.dependencies, hash);
    if (dependency == null) {
      fail('monty must depend on $hash in $_workerLockPath');
    }
    expect(
      _resolvedLockVersion(dependency, versionsByName),
      '0.11.0',
      reason: 'monty must depend on $hash 0.11.0',
    );
    expect(
      versionsByName[hash],
      contains('0.11.0'),
      reason:
          '$_workerLockPath must record a $hash 0.11.0 package entry '
          'for monty to resolve',
    );
  }
}

/// Both package versions: the Dart package and the worker crate carry the
/// 0.120.x version that tracks upstream monty 1.2.0.
void _expectPackageVersionsTrackV120() {
  expect(
    _packageVersion('pubspec.yaml'),
    '0.120.0-dev.1',
    reason:
        'pubspec.yaml must carry the 0.120.x version that tracks '
        'upstream monty 1.2.0',
  );
  expect(
    _packageVersion(_workerManifestPath),
    '0.120.0-dev.1',
    reason:
        '$_workerManifestPath must carry the 0.120.x version that '
        'tracks upstream monty 1.2.0',
  );
}

/// The reviewed mirrors and the version mapping, checked locally: the
/// upstream pin record, the worker's mirror of the pinned tag, and the
/// mapping from the upstream release to this package's version.
void _expectLocalMirrorAndVersionChecksPass() {
  final upstreamPin = Process.runSync(
    'python3',
    ['-I', 'tool/check_upstream_pin.py'],
  );
  expect(
    upstreamPin.exitCode,
    0,
    reason:
        'the offline upstream pin check must pass:\n'
        '${upstreamPin.stdout}${upstreamPin.stderr}',
  );
  final mirror = Process.runSync(
    'python3',
    ['-I', 'tool/check_worker_mirror.py', '--local'],
  );
  expect(
    mirror.exitCode,
    0,
    reason:
        'the local worker mirror check must pass:\n'
        '${mirror.stdout}${mirror.stderr}',
  );
  final versionPin = Process.runSync('bash', ['tool/check_version_pin.sh']);
  expect(
    versionPin.exitCode,
    0,
    reason:
        'the version pin check must pass:\n'
        '${versionPin.stdout}${versionPin.stderr}',
  );
}

/// The monty requirements native/worker/Cargo.toml declares, in the order the
/// manifest lists them.
List<_MontyRequirement> _workerManifestMontyRequirements() {
  final requirements = <_MontyRequirement>[];
  final entries = _manifestDependencyEntries(
    File(_workerManifestPath).readAsStringSync(),
  );
  for (final entry in entries) {
    if (!entry.name.startsWith('monty')) {
      continue;
    }
    final version = _declaredVersion(entry.value);
    if (version == null) {
      fail(
        '$_workerManifestPath [${entry.table}] ${entry.name} declares no '
        'version',
      );
    }
    requirements.add((
      table: entry.table,
      name: entry.name,
      version: version,
    ));
  }

  return requirements;
}

/// The dependency entries a Cargo manifest declares, with the table each one
/// sits in.
List<_ManifestEntry> _manifestDependencyEntries(String text) {
  final entries = <_ManifestEntry>[];
  var table = '';
  for (final line in _manifestLines(text)) {
    if (line.startsWith('[')) {
      table = _tableName(line);
      continue;
    }
    if (!table.endsWith('dependencies')) {
      continue;
    }
    final entry = RegExp(r'^([A-Za-z0-9_-]+)\s*=\s*(.*)$').firstMatch(line);
    if (entry == null) {
      continue;
    }
    entries.add((
      table: table,
      name: entry.group(1) ?? '',
      value: entry.group(2) ?? '',
    ));
  }

  return entries;
}

/// The manifest's lines, with a dependency's inline table joined onto the
/// line that opens it, so every entry is one line.
List<String> _manifestLines(String text) {
  final lines = <String>[];
  var buffer = StringBuffer();
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    buffer.write(buffer.isEmpty ? line : ' $line');
    final joined = buffer.toString();
    if (_opensInlineTable(joined)) {
      continue;
    }
    lines.add(joined);
    buffer = StringBuffer();
  }
  if (buffer.isNotEmpty) {
    lines.add(buffer.toString());
  }

  return lines;
}

/// The table a Cargo manifest's section header names.
String _tableName(String header) =>
    header.replaceAll(RegExp(r'^\[+'), '').replaceAll(RegExp(r'\]+$'), '');

/// Whether a Cargo dependency value opens an inline table the line does not
/// close.
bool _opensInlineTable(String value) =>
    '{'.allMatches(value).length != '}'.allMatches(value).length;

/// The version requirement a Cargo dependency value pins, or null when it
/// declares none.
String? _declaredVersion(String value) {
  final inline = RegExp(r'version\s*=\s*"([^"]*)"').firstMatch(value);
  if (inline != null) {
    return inline.group(1);
  }
  final plain = RegExp(r'^"([^"]*)"$').firstMatch(value.trim());

  return plain?.group(1);
}

/// The packages native/worker/Cargo.lock records.
List<_LockPackage> _workerLockPackages() {
  final text = File(_workerLockPath).readAsStringSync();

  return [
    for (final block in text.split('[[package]]').skip(1)) _lockPackage(block),
  ];
}

/// The package one `[[package]]` block of a Cargo lock records.
_LockPackage _lockPackage(String block) {
  final name =
      RegExp(
        '^name = "([^"]+)"',
        multiLine: true,
      ).firstMatch(block)?.group(1) ??
      '';
  final version =
      RegExp(
        '^version = "([^"]+)"',
        multiLine: true,
      ).firstMatch(block)?.group(1) ??
      '';
  final listed = RegExp(
    r'^dependencies = \[(.*?)^\]',
    multiLine: true,
    dotAll: true,
  ).firstMatch(block);
  final dependencies = listed == null
      ? <String>[]
      : [
          for (final match in RegExp(
            '"([^"]+)"',
          ).allMatches(listed.group(1) ?? ''))
            match.group(1) ?? '',
        ];

  return (name: name, version: version, dependencies: dependencies);
}

/// The versions the lock's packages resolve to, keyed by package name.
Map<String, List<String>> _lockVersionsByName(List<_LockPackage> packages) {
  final versionsByName = <String, List<String>>{};
  for (final package in packages) {
    versionsByName
        .putIfAbsent(package.name, () => <String>[])
        .add(package.version);
  }

  return versionsByName;
}

/// The dependency a lock names for [crate], or null when it names none.
String? _lockDependency(List<String> dependencies, String crate) {
  for (final dependency in dependencies) {
    if (dependency.split(' ').firstOrNull == crate) {
      return dependency;
    }
  }

  return null;
}

/// The version a lock dependency resolves to. The lock's own package entries
/// decide: a dependency that names a version the lock does not record is a
/// resolution the lock cannot honour, and fails.
String _resolvedLockVersion(
  String dependency,
  Map<String, List<String>> versionsByName,
) {
  final parts = dependency.split(' ');
  final crate = parts.firstOrNull ?? '';
  final declared = parts.elementAtOrNull(1) ?? '';
  final versions = versionsByName[crate] ?? const <String>[];
  if (versions.isEmpty) {
    fail('$_workerLockPath records no package entry for "$crate"');
  }
  if (declared.isEmpty) {
    if (versions.length != 1) {
      fail('$_workerLockPath resolves "$crate" to ${versions.join(', ')}');
    }

    return versions.singleOrNull ?? '';
  }
  if (!versions.contains(declared)) {
    fail(
      '$_workerLockPath names "$dependency" but records no such package '
      'entry',
    );
  }

  return declared;
}

/// The version a package manifest declares: pubspec.yaml's `version:` or a
/// Cargo manifest's `version = "..."`.
String _packageVersion(String path) {
  final text = File(path).readAsStringSync();
  final pubspec = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(
    text,
  );
  if (pubspec != null) {
    return pubspec.group(1) ?? '';
  }
  final cargo = RegExp(
    r'^version\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(text);

  return cargo?.group(1) ?? '';
}

// ---------------------------------------------------------------------------
// The v1.2.0 corpus scorecard acceptance.
//
// The corpus suite prints a scorecard per backend; the corpus manifest, the
// pin, the generated corpus and the capability records state what that run
// must have measured. This acceptance measures the corpus on all three
// backends, checks the records against the measurement, and reports every
// difference it finds.
//
// Nothing here updates a record, regenerates a fixture, builds an artefact
// or skips a prerequisite: a missing checkout, a stale record and a failing
// leg are reported, never worked around.
// ---------------------------------------------------------------------------

/// The upstream release this acceptance measures: the pin's version.
const String _upstreamVersion = '1.2.0';

/// The upstream release's tag.
const String _upstreamTag = 'v1.2.0';

/// How many fixtures the pinned corpus holds.
const int _pinnedCorpusFiles = 695;

/// The upstream corpus' path in the checkout, as the pin records it.
const String _corpusPath = 'crates/monty/test_cases';

/// The upstream pin record.
const String _pinPath = 'tool/upstream/upstream-pin.json';

/// The generated corpus: the file the corpus generator writes.
const String _generatedCorpusPath =
    'packages/monty_conformance/lib/src/fixture_corpus_v1.dart';

/// The frozen capability manifest.
const String _capabilityManifestPath = 'tool/upstream/capability-manifest.json';

/// The capability manifest's checker.
const String _capabilityChecker = 'tool/check_capability_manifest.py';

/// The generator of the corpus the corpus suite runs.
const String _corpusGenerator = 'tool/generate_fixture_corpus_v1.dart';

/// One measured corpus leg: the backend the corpus ran on, the platform its
/// tests ran on and the compiler a browser leg compiled with.
final class _CorpusLeg {
  /// Creates a [_CorpusLeg].
  const _CorpusLeg({
    required this.label,
    required this.platform,
    required this.compiler,
    required this.profile,
  });

  /// The label the corpus suite prints in its scorecard.
  final String label;

  /// The platform the corpus suite runs on: `vm`, `chrome` or `firefox`.
  final String platform;

  /// The compiler a browser leg compiles with; null on the native leg.
  final String? compiler;

  /// The manifest profile the leg's failures are judged against.
  final WorkerCorpusProfile profile;
}

/// The three legs the acceptance measures, in order: the native worker on
/// the VM, the Web Worker compiled by dart2js in Chrome and the Web Worker
/// compiled by dart2wasm in Firefox.
const List<_CorpusLeg> _corpusLegs = [
  _CorpusLeg(
    label: 'native',
    platform: 'vm',
    compiler: null,
    profile: WorkerCorpusProfile.native,
  ),
  _CorpusLeg(
    label: 'dart2js',
    platform: 'chrome',
    compiler: 'dart2js',
    profile: WorkerCorpusProfile.browser,
  ),
  _CorpusLeg(
    label: 'dart2wasm',
    platform: 'firefox',
    compiler: 'dart2wasm',
    profile: WorkerCorpusProfile.browser,
  ),
];

/// What a command run measured: its exit status, its output and what went
/// wrong, if anything did.
final class _CommandResult {
  /// Creates a [_CommandResult].
  const _CommandResult({
    required this.command,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.failure,
  });

  /// The command line that was run.
  final String command;

  /// The exit status; null when the process never ran.
  final int? exitCode;

  /// The standard output, decoded.
  final String stdout;

  /// The standard error, decoded.
  final String stderr;

  /// Why the run did not complete, when it did not.
  final String? failure;

  /// Whether the command ran to the end and exited 0.
  bool get ok => exitCode == 0 && failure == null;
}

/// What a command's process produced: its status, its two streams and what
/// went wrong while collecting them.
typedef _CommandOutput = ({
  int status,
  String stdout,
  String stderr,
  List<String> diagnostics,
});

/// The upstream checkout the acceptance measures against, and the cleanup
/// that removes it when this test made it. The cleanup is null for a
/// checkout this test did not make: that one is not this test's to remove.
typedef _UpstreamCheckout = ({String path, void Function()? cleanup});

/// The pin's record of the corpus tree: its git tree hash and its file
/// count.
typedef _PinnedTree = ({String gitTree, int files});

/// The versions the two documents name: the README's banner and the
/// generated corpus' header.
typedef _DocumentedVersions = ({String? readme, String? generated});

/// What the capability checker measured: its offline run and its online
/// run.
typedef _CapabilityRuns = ({_CommandResult offline, _CommandResult online});

/// One measured corpus leg: the leg and what its run measured.
typedef _LegRun = ({_CorpusLeg leg, _CommandResult result});

/// A measured corpus scorecard: the counts the corpus run printed.
final class _Scorecard {
  /// Creates a [_Scorecard].
  const _Scorecard({
    required this.label,
    required this.total,
    required this.passed,
    required this.divergent,
    required this.listed,
    required this.jspi,
  });

  /// The backend the scorecard names.
  final String label;

  /// How many fixtures ran.
  final int total;

  /// How many of them passed.
  final int passed;

  /// How many of them failed.
  final int divergent;

  /// How many failures the manifest lists for the leg's profile.
  final int listed;

  /// Whether the browser had JSPI; null on the native worker.
  final bool? jspi;
}

/// The repository root: the directory that holds the pubspec, the pin and
/// the corpus generator.
String _repositoryRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File(p.join(directory.path, 'pubspec.yaml')).existsSync() &&
        File(p.join(directory.path, _pinPath)).existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      return Directory.current.absolute.path;
    }
    directory = parent;
  }
}

/// The time left until [deadline], never negative.
Duration _remaining(DateTime deadline) {
  final left = deadline.difference(DateTime.now());

  return left.isNegative ? Duration.zero : left;
}

/// The tail of [text], for a problem message.
String _tail(String text, {int limit = 2000}) {
  final trimmed = text.trim();
  if (trimmed.length <= limit) {
    return trimmed;
  }

  return '...${trimmed.substring(trimmed.length - limit)}';
}

/// Runs [executable] with [arguments] from the repository root and measures
/// it: the exit status, the output and whatever went wrong.
///
/// A process that cannot be started, one that outlives [timeout] and one
/// whose output cannot be drained within it are failures with a diagnostic,
/// never a silent success. The timeout bounds the process AND its output:
/// a child that exits but holds its pipes open is a failed run, not a
/// successful one.
Future<_CommandResult> _runCommand(
  String executable,
  List<String> arguments, {
  Duration? timeout,
  Map<String, String>? environment,
}) async {
  final command = '$executable ${arguments.join(' ')}';
  final Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      workingDirectory: _repositoryRoot(),
      environment: environment,
    );
  } on Exception catch (error) {
    return _CommandResult(
      command: command,
      failure: 'could not start $executable: $error',
    );
  }

  final output = await _collectOutput(process, timeout);

  return _CommandResult(
    command: command,
    exitCode: output.status,
    stdout: output.stdout,
    stderr: output.stderr,
    failure: output.diagnostics.isEmpty ? null : output.diagnostics.join('; '),
  );
}

/// Collects a process' status and its two streams, within [timeout].
///
/// The deadline covers the process AND the streams: a child that exits and
/// leaves its pipes open is a timeout, not a success.
Future<_CommandOutput> _collectOutput(
  Process process,
  Duration? timeout,
) async {
  final diagnostics = <String>[];
  final stdoutBytes = <int>[];
  final stderrBytes = <int>[];
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  _collectStream(
    process.stdout,
    stdoutBytes,
    stdoutDone,
    'stdout',
    diagnostics,
  );
  _collectStream(
    process.stderr,
    stderrBytes,
    stderrDone,
    'stderr',
    diagnostics,
  );

  final deadline = timeout == null ? null : DateTime.now().add(timeout);
  final exit = await _awaitExit(process, deadline, timeout, diagnostics);
  if (exit.timedOut) {
    process.kill(ProcessSignal.sigkill);
  }

  await _drain(stdoutDone, 'stdout', deadline, exit.timedOut, diagnostics);
  await _drain(stderrDone, 'stderr', deadline, exit.timedOut, diagnostics);

  return (
    status: exit.status,
    stdout: _decode(stdoutBytes, 'stdout', diagnostics),
    stderr: _decode(stderrBytes, 'stderr', diagnostics),
    diagnostics: diagnostics,
  );
}

/// Waits for the process to exit, within the deadline: its status and
/// whether it timed out.
Future<({int status, bool timedOut})> _awaitExit(
  Process process,
  DateTime? deadline,
  Duration? timeout,
  List<String> diagnostics,
) async {
  if (deadline == null) {
    return (status: await process.exitCode, timedOut: false);
  }
  try {
    final status = await process.exitCode.timeout(_remaining(deadline));

    return (status: status, timedOut: false);
  } on TimeoutException {
    diagnostics.add(
      'the command did not finish within ${timeout?.inSeconds}s',
    );

    return (status: -1, timedOut: true);
  }
}

/// Collects one of a process' output streams into [bytes], and completes
/// [done] when the stream ends or fails.
void _collectStream(
  Stream<List<int>> stream,
  List<int> bytes,
  Completer<void> done,
  String name,
  List<String> diagnostics,
) {
  stream.listen(
    bytes.addAll,
    onError: (Object error) {
      diagnostics.add('the $name stream failed: $error');
      _complete(done);
    },
    onDone: () => _complete(done),
  );
}

/// Completes [done] once, whatever happened to the stream behind it.
void _complete(Completer<void> done) {
  if (!done.isCompleted) {
    done.complete();
  }
}

/// Waits for [done] -- the end of one output stream -- within the command's
/// deadline, and records what went wrong when it does not.
Future<void> _drain(
  Completer<void> done,
  String stream,
  DateTime? deadline,
  bool killed,
  List<String> diagnostics,
) async {
  if (deadline == null) {
    await done.future;

    return;
  }
  final budget = killed ? const Duration(seconds: 5) : _remaining(deadline);
  try {
    await done.future.timeout(budget);
  } on TimeoutException {
    diagnostics.add('the $stream stream did not end within the timeout');
  }
}

/// The decoded bytes of one output stream. A stream that is not valid UTF-8
/// is a failure, not a silently mangled text.
String _decode(List<int> bytes, String stream, List<String> diagnostics) {
  try {
    return utf8.decode(bytes);
  } on FormatException catch (error) {
    diagnostics.add('the $stream stream is not valid UTF-8: ${error.message}');

    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// The upstream checkout the acceptance measures against.
///
/// An explicit MONTY_CHECKOUT is honoured as it is: an invalid one is a
/// problem, not a reason to measure something else. Otherwise the `up`
/// directory is used when it is a Git checkout of the pinned commit, and a
/// temporary checkout of the pinned commit is fetched when it is not: a
/// directory of upstream source files alone does not establish a Git
/// identity, and the supplied checkout is never altered.
Future<_UpstreamCheckout?> _upstreamCheckout(
  Map<String, Object?> pin,
  List<String> problems,
) async {
  final explicit = Platform.environment['MONTY_CHECKOUT']?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    final directory = Directory(explicit);
    if (!directory.existsSync()) {
      problems.add('MONTY_CHECKOUT points at $explicit, which does not exist');

      return null;
    }
    final reason = _checkoutPinProblem(directory.path, pin);
    if (reason != null) {
      problems.add('MONTY_CHECKOUT points at $explicit: $reason');

      return null;
    }

    return (path: directory.absolute.path, cleanup: null);
  }

  final supplied = Directory(p.join(_repositoryRoot(), 'up'));
  if (supplied.existsSync()) {
    final reason = _checkoutPinProblem(supplied.path, pin);
    if (reason == null) {
      return (path: supplied.absolute.path, cleanup: null);
    }
  }

  return _fetchUpstreamCommit(pin, problems);
}

/// Why [path] is not a Git checkout of the pinned commit; null when it is.
String? _checkoutPinProblem(String path, Map<String, Object?> pin) {
  final head = _gitOutput(path, ['rev-parse', 'HEAD']);
  if (head == null) {
    return 'it is not a Git checkout';
  }
  final commit = pin['commit'];
  if (commit is! String || head != commit) {
    return 'its HEAD is $head, not the pinned $commit';
  }
  final tree = _pinnedTree(pin);
  final gitTree = _gitOutput(path, ['rev-parse', 'HEAD:$_corpusPath']);
  if (tree == null || gitTree != tree.gitTree) {
    return 'its $_corpusPath tree is $gitTree, not the pinned ${tree?.gitTree}';
  }

  return null;
}

/// The output of a git command run in [path], or null when it failed.
String? _gitOutput(String path, List<String> arguments) {
  try {
    final result = Process.runSync('git', ['-C', path, ...arguments]);
    if (result.exitCode != 0) {
      return null;
    }
    final stdout = result.stdout;
    if (stdout is! String) {
      return null;
    }

    return stdout.trim();
  } on Exception {
    return null;
  }
}

/// Fetches the pinned commit into a temporary checkout and returns it. The
/// checkout is removed by its cleanup, and the pin is never changed.
Future<_UpstreamCheckout?> _fetchUpstreamCommit(
  Map<String, Object?> pin,
  List<String> problems,
) async {
  final upstream = pin['upstream'];
  final commit = pin['commit'];
  if (upstream is! String || commit is! String) {
    problems.add('the upstream pin records no upstream URL and commit');

    return null;
  }

  final directory = await Directory.systemTemp.createTemp('monty-upstream-');
  final path = directory.path;
  void cleanup() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  if (!await _prepareTemporaryCheckout(path, upstream, commit, problems)) {
    cleanup();

    return null;
  }

  return (path: path, cleanup: cleanup);
}

/// Makes the temporary checkout at [path] hold the pinned [commit] of
/// [upstream]. False when one of the steps failed.
Future<bool> _prepareTemporaryCheckout(
  String path,
  String upstream,
  String commit,
  List<String> problems,
) async {
  final steps = <(String, List<String>, Duration?)>[
    ('git init', ['init', '--quiet', path], null),
    (
      'git fetch $commit',
      ['-C', path, 'fetch', '--depth', '1', upstream, commit],
      const Duration(minutes: 15),
    ),
    (
      'git checkout',
      ['-C', path, 'checkout', '--detach', 'FETCH_HEAD'],
      null,
    ),
  ];
  for (final (name, arguments, timeout) in steps) {
    final result = await _runCommand('git', arguments, timeout: timeout);
    if (result.ok) {
      continue;
    }
    problems.add(
      '$name failed: '
      '${result.failure ?? _tail('${result.stdout}${result.stderr}')}',
    );

    return false;
  }

  return true;
}

/// The corpus tree the pin records.
_PinnedTree? _pinnedTree(Map<String, Object?> pin) {
  final trees = pin['trees'];
  if (trees is! List<Object?>) {
    return null;
  }
  for (final entry in trees) {
    if (entry is! Map<String, Object?>) {
      continue;
    }
    if (entry['path'] != _corpusPath) {
      continue;
    }
    final gitTree = entry['git_tree'];
    final files = entry['files'];
    if (gitTree is! String || files is! int) {
      return null;
    }

    return (gitTree: gitTree, files: files);
  }

  return null;
}

/// The fixture names in the checkout's corpus directory.
List<String> _checkoutCorpusFiles(String checkout) {
  final directory = Directory(p.join(checkout, _corpusPath));
  if (!directory.existsSync()) {
    return const [];
  }

  return [
    for (final entity in directory.listSync())
      if (entity is File && entity.path.endsWith('.py'))
        p.basename(entity.path),
  ]..sort();
}

/// What is wrong with the upstream pin itself; empty when it records the
/// v1.2.0 corpus.
///
/// The pin's own readers decide what the record says, so this states the
/// same version and tag the rest of the tree reads.
List<String> _pinProblems() {
  final Map<String, Object?> pin;
  final String version;
  final String tag;
  try {
    pin = _pinRecord();
    version = _pinnedUpstreamVersion();
    tag = _pinnedUpstreamTag();
  } on Exception catch (error) {
    return ['the upstream pin could not be read: $error'];
  }

  final problems = <String>[];
  if (version != _upstreamVersion) {
    problems.add(
      '$_pinPath records upstream version $version, not $_upstreamVersion',
    );
  }
  if (tag != _upstreamTag) {
    problems.add('$_pinPath records tag $tag, not $_upstreamTag');
  }
  final tree = _pinnedTree(pin);
  if (tree == null) {
    problems.add('$_pinPath records no $_corpusPath tree');
  } else if (tree.files != _pinnedCorpusFiles) {
    problems.add(
      '$_pinPath records ${tree.files} files in $_corpusPath, '
      'not $_pinnedCorpusFiles',
    );
  }

  return problems;
}

/// What is wrong with the corpus records: the pin, the checkout's fixtures,
/// the manifest and the generated corpus the generator writes.
///
/// The generator is run with --check: a corpus that differs from the pinned
/// checkout is a problem, and nothing here computes a hash of its own.
Future<List<String>> _corpusRecordProblems(String? checkout) async {
  final problems = <String>[..._pinProblems()];
  if (checkout == null) {
    problems.add('no upstream checkout to measure the corpus against');

    return problems;
  }

  final fixtures = _checkoutCorpusFiles(checkout);
  if (fixtures.length != _pinnedCorpusFiles) {
    problems.add(
      'the checkout holds ${fixtures.length} $_corpusPath fixtures, '
      'not $_pinnedCorpusFiles',
    );
  }
  for (final problem in manifestProblems(fixtures)) {
    problems.add('the corpus manifest: $problem');
  }

  final generated = await _runCommand(
    'dart',
    [_corpusGenerator, checkout, '--check'],
    timeout: const Duration(minutes: 10),
  );
  if (!generated.ok) {
    problems.add(
      'the corpus generator --check failed (exit ${generated.exitCode}): '
      '${generated.failure ?? _tail(generated.stderr)}',
    );
  }

  return problems;
}

/// The upstream version the README's version banner names.
///
/// The banner is the one line tool/check_docs_data.py checks: the package
/// version, a middle dot and the upstream version. A README without that
/// line names no version at all.
String? _readmeUpstreamVersion() {
  final file = File(p.join(_repositoryRoot(), 'README.md'));
  if (!file.existsSync()) {
    return null;
  }
  final List<String> lines;
  try {
    lines = const LineSplitter().convert(file.readAsStringSync());
  } on Exception {
    return null;
  }

  final pattern = RegExp(
    r'^\*\*dart_monty_core (\d+\.\d+\.\d+) · monty (\d+\.\d+\.\d+)\*\*$',
  );
  final versions = <String>[];
  for (final line in lines) {
    final match = pattern.firstMatch(line);
    if (match != null) {
      versions.add(match.group(2) ?? '');
    }
  }
  if (versions.length != 1) {
    return null;
  }

  return versions.singleOrNull;
}

/// The upstream version the generated corpus' header names.
///
/// The header is the leading comment line of the generated file that names
/// pydantic/monty and the corpus path, as the generator writes it. Only
/// that header counts: the version phrase elsewhere in the file is not a
/// header.
String? _generatedCorpusUpstreamVersion() {
  final file = File(p.join(_repositoryRoot(), _generatedCorpusPath));
  if (!file.existsSync()) {
    return null;
  }
  final List<String> lines;
  try {
    lines = const LineSplitter().convert(file.readAsStringSync());
  } on Exception {
    return null;
  }

  final pattern = RegExp(
    r"^///\s+pydantic/monty\s+v(\d+\.\d+\.\d+)'s\s+`[^`]+`,\s+embedded\.$",
  );
  final versions = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      continue;
    }
    if (!trimmed.startsWith('//')) {
      break;
    }
    final match = pattern.firstMatch(trimmed);
    if (match != null) {
      versions.add(match.group(1) ?? '');
    }
  }
  if (versions.length != 1) {
    return null;
  }

  return versions.singleOrNull;
}

/// The upstream version each of the two documents names.
_DocumentedVersions _documentedReferenceVersions() => (
  readme: _readmeUpstreamVersion(),
  generated: _generatedCorpusUpstreamVersion(),
);

/// What is wrong with the two documents that name the upstream release.
/// Empty when both name it.
///
/// The documents are checked independently: a README without its banner is
/// a problem even when the generated corpus names the release, and the
/// other way round.
List<String> _documentationProblems() {
  final problems = <String>[];
  final versions = _documentedReferenceVersions();
  final readme = versions.readme;
  if (readme == null) {
    problems.add(
      'README.md has no package/upstream version banner naming '
      '$_upstreamVersion',
    );
  } else if (readme != _upstreamVersion) {
    problems.add('README.md names upstream $readme, not $_upstreamVersion');
  }
  final generated = versions.generated;
  if (generated == null) {
    problems.add(
      '$_generatedCorpusPath has no generated pydantic/monty header naming '
      '$_upstreamVersion',
    );
  } else if (generated != _upstreamVersion) {
    problems.add(
      '$_generatedCorpusPath names upstream $generated, '
      'not $_upstreamVersion',
    );
  }

  return problems;
}

/// Runs the capability checker, offline and online, and measures both.
Future<_CapabilityRuns> _measureCapabilityRecords() async {
  final offline = await _runCommand(
    'python3',
    ['-I', _capabilityChecker],
    timeout: const Duration(minutes: 5),
  );
  final online = await _runCommand(
    'python3',
    ['-I', _capabilityChecker, '--online'],
    timeout: const Duration(minutes: 10),
  );

  return (offline: offline, online: online);
}

/// The upstream version the capability manifest records.
String? _capabilityManifestVersion() {
  final file = File(p.join(_repositoryRoot(), _capabilityManifestPath));
  if (!file.existsSync()) {
    return null;
  }
  final Object? decoded;
  try {
    decoded = json.decode(file.readAsStringSync());
  } on Exception {
    return null;
  }
  if (decoded is! Map<String, Object?>) {
    return null;
  }
  final version = decoded['upstream_version'];

  return version is String ? version : null;
}

/// What is wrong with the capability records: the checker's two runs and the
/// manifest's recorded version.
///
/// A failed fetch and a citation that names no file are the checker's own
/// output, and they stay problems: they are not dropped and not replaced.
List<String> _capabilityProblems(_CapabilityRuns runs) {
  final problems = <String>[];
  for (final run in [runs.offline, runs.online]) {
    if (run.ok) {
      continue;
    }
    problems.add(
      '${run.command} failed (exit ${run.exitCode}): '
      '${run.failure ?? _tail('${run.stdout}${run.stderr}')}',
    );
  }
  final version = _capabilityManifestVersion();
  if (version == null) {
    problems.add('$_capabilityManifestPath records no upstream version');
  } else if (version != _upstreamVersion) {
    problems.add(
      '$_capabilityManifestPath records upstream version $version, '
      'not $_upstreamVersion',
    );
  }

  return problems;
}

/// Runs the corpus suite for [leg] and measures it.
///
/// The whole suite runs, unfiltered but for the corpus-worker tag it is
/// tagged with: a smaller subset would measure less than the acceptance
/// claims.
Future<_CommandResult> _measureCorpusLeg(_CorpusLeg leg) {
  final arguments = ['test', 'test/corpus', '-p', leg.platform];
  final compiler = leg.compiler;
  if (compiler != null) {
    arguments.addAll(['-c', compiler]);
  }
  arguments.addAll(['--tags=corpus-worker', '--reporter=json']);
  final environment = <String, String>{
    if (leg.platform == 'firefox') 'MOZ_HEADLESS': '1',
  };

  return _runCommand(
    'dart',
    arguments,
    timeout: const Duration(minutes: 20),
    environment: environment.isEmpty ? null : environment,
  );
}

/// Runs every corpus leg, in order, and keeps each leg's own result: a leg
/// that fails does not stop the ones after it.
Future<List<_LegRun>> _measureCorpusLegs() async {
  final runs = <_LegRun>[];
  for (final leg in _corpusLegs) {
    _CommandResult result;
    try {
      result = await _measureCorpusLeg(leg);
    } on Exception catch (error) {
      result = _CommandResult(
        command: 'dart test test/corpus -p ${leg.platform}',
        failure: 'the corpus run could not be started: $error',
      );
    }
    runs.add((leg: leg, result: result));
  }

  return runs;
}

/// The events the JSON reporter printed, in order.
List<Map<String, Object?>> _jsonEvents(String stdout) {
  final events = <Map<String, Object?>>[];
  for (final line in const LineSplitter().convert(stdout)) {
    final text = line.trim();
    if (text.isEmpty) {
      continue;
    }
    Object? decoded;
    try {
      decoded = json.decode(text);
    } on FormatException {
      continue;
    }
    if (decoded is Map<String, Object?>) {
      events.add(decoded);
    }
  }

  return events;
}

/// The scorecard the line states, or null when the line is not one.
///
/// The line is the corpus suite's own scorecard: the backend's label and
/// the five counts it prints, in the order it prints them. The JSPI state
/// is read strictly: `true`, `false` or `null`, and no other token.
_Scorecard? _scorecardOf(String line) {
  final match = RegExp(
    r'^CORPUS ([A-Za-z0-9_]+): total=(\d+) passed=(\d+) divergent=(\d+) '
    r'jspi=(true|false|null) listed=(\d+)$',
  ).firstMatch(line.trim());
  if (match == null) {
    return null;
  }
  final jspi = switch (match.group(5)) {
    'true' => true,
    'false' => false,
    _ => null,
  };

  return _Scorecard(
    label: match.group(1) ?? '',
    total: int.parse(match.group(2) ?? '0'),
    passed: int.parse(match.group(3) ?? '0'),
    divergent: int.parse(match.group(4) ?? '0'),
    listed: int.parse(match.group(6) ?? '0'),
    jspi: jspi,
  );
}

/// The scorecards the measured print events carry, and the lines that
/// claimed to be one but did not parse.
({List<_Scorecard> scorecards, List<String> malformed}) _scorecardsOf(
  String stdout,
) {
  final scorecards = <_Scorecard>[];
  final malformed = <String>[];
  for (final event in _jsonEvents(stdout)) {
    if (event['type'] != 'print') {
      continue;
    }
    final message = event['message'];
    if (message is! String) {
      continue;
    }
    for (final line in const LineSplitter().convert(message)) {
      if (!line.trim().startsWith('CORPUS ')) {
        continue;
      }
      final card = _scorecardOf(line);
      if (card == null) {
        malformed.add(line.trim());
      } else {
        scorecards.add(card);
      }
    }
  }

  return (scorecards: scorecards, malformed: malformed);
}

/// The files the manifest lists as expected failures for [profile].
Set<String> _listedFailureFiles(WorkerCorpusProfile profile) => {
  for (final entry in workerCorpusExpected)
    if (entry.profiles.contains(profile)) entry.file,
};

/// The recursion-set files that must crash when JSPI is off: the ones
/// upstream's own browser build crashes on.
Set<String> _recursionCrashFiles() => {
  for (final entry in workerRecursionSetNoJspi.entries)
    if (entry.value == RecursionOutcome.crashes) entry.key,
};

/// Whether the measured JSPI state is off: false, and nothing else.
bool _jspiOff(bool? jspi) => switch (jspi) {
  false => true,
  _ => false,
};

/// The files a leg must fail: the manifest's listed failures for the leg's
/// profile and, when [jspi] is false, the recursion-set files that crash
/// without JSPI.
///
/// A native leg has no JSPI at all (null), so it adds none, and the
/// scorecard's listed count never includes a recursion crash.
Set<String> _expectedFailureFiles(
  Set<String> listed,
  Set<String> crashes,
  bool? jspi,
) => _jspiOff(jspi) ? {...listed, ...crashes} : listed;

/// What is wrong with a measured scorecard's JSPI state.
List<String> _scorecardJspiProblems(
  _Scorecard card,
  WorkerCorpusProfile profile,
) {
  if (profile == WorkerCorpusProfile.browser && card.jspi == null) {
    return ['the browser scorecard states no JSPI state'];
  }
  if (profile == WorkerCorpusProfile.native && card.jspi != null) {
    return ['the native scorecard states a JSPI state'];
  }

  return [];
}

/// What is wrong with a measured scorecard's counts.
///
/// [expected] are the files the leg must fail, [listedFiles] the manifest's
/// listed failures for the leg's profile and [expectedTotal] how many
/// fixtures the pinned corpus holds.
List<String> _scorecardCountProblems(
  _Scorecard card,
  Set<String> expected,
  Set<String> listedFiles,
  int expectedTotal,
) {
  final problems = <String>[];
  if (card.total != expectedTotal) {
    problems.add(
      'the scorecard states ${card.total} fixtures ran, not $expectedTotal',
    );
  }
  if (card.passed + card.divergent != expectedTotal) {
    problems.add(
      'the scorecard states ${card.passed} passed and '
      '${card.divergent} divergent, which is not $expectedTotal',
    );
  }
  if (card.divergent != expected.length) {
    problems.add(
      'the scorecard states ${card.divergent} divergent failures, '
      'not ${expected.length}',
    );
  }
  if (card.listed != listedFiles.length) {
    problems.add(
      'the scorecard lists ${card.listed} expected failures, '
      'not ${listedFiles.length}',
    );
  }
  for (final count in [
    ('total', card.total),
    ('passed', card.passed),
    ('divergent', card.divergent),
    ('listed', card.listed),
  ]) {
    if (count.$2 < 0) {
      problems.add('the scorecard states a negative ${count.$1} count');
    }
  }

  return problems;
}

/// What is wrong with a measured scorecard; empty when the scorecard states
/// the counts the manifest requires.
///
/// [listedFiles] are the manifest's listed failures for the leg's profile,
/// [crashes] the recursion-set files that must crash without JSPI and
/// [expectedTotal] how many fixtures the pinned corpus holds.
List<String> _scorecardProblems(
  _Scorecard card,
  Set<String> listedFiles,
  Set<String> crashes, {
  required WorkerCorpusProfile profile,
  required int expectedTotal,
}) {
  final expected = _expectedFailureFiles(listedFiles, crashes, card.jspi);

  return [
    ..._scorecardJspiProblems(card, profile),
    ..._scorecardCountProblems(card, expected, listedFiles, expectedTotal),
  ];
}

/// The error messages the JSON reporter recorded, for a problem message.
///
/// The corpus suite's own verdict is in them: which fixture failed
/// unexpectedly, which listed failure now passes and which reason changed.
List<String> _reportedErrors(String stdout) => [
  for (final event in _jsonEvents(stdout))
    if (event['type'] == 'error')
      if (event['error'] case final String message) message,
];

/// What is wrong with a leg's run itself: it did not finish, or it failed.
List<String> _legRunProblems(_CorpusLeg leg, _CommandResult result) {
  final problems = <String>[];
  final failure = result.failure;
  if (failure != null) {
    problems.add('${leg.label}: $failure');
  }
  final status = result.exitCode;
  if (status == null) {
    problems.add('${leg.label}: the corpus suite never ran');
  } else if (status != 0) {
    problems.add('${leg.label}: the corpus suite exited $status');
    final errors = _reportedErrors(result.stdout);
    final detail = errors.isEmpty ? _tail(result.stderr) : errors.join('\n');
    if (detail.isNotEmpty) {
      problems.add('${leg.label}: $detail');
    }
  }

  return problems;
}

/// What is wrong with a leg's scorecard: it is missing, it is duplicated, it
/// does not parse, it names another backend or its counts are wrong.
List<String> _legScorecardProblems(_CorpusLeg leg, _CommandResult result) {
  final problems = <String>[];
  final parsed = _scorecardsOf(result.stdout);
  for (final line in parsed.malformed) {
    problems.add('${leg.label}: the scorecard "$line" does not parse');
  }
  final printed = parsed.scorecards.length;
  if (printed != 1) {
    problems.add('${leg.label}: the run printed $printed scorecards, not 1');

    return problems;
  }

  final card = parsed.scorecards.singleOrNull;
  if (card == null) {
    problems.add('${leg.label}: the run printed no scorecard');

    return problems;
  }
  if (card.label != leg.label) {
    problems.add('${leg.label}: the run printed a scorecard for ${card.label}');

    return problems;
  }
  problems.addAll(
    _scorecardProblems(
      card,
      _listedFailureFiles(leg.profile),
      _recursionCrashFiles(),
      profile: leg.profile,
      expectedTotal: _pinnedCorpusFiles,
    ),
  );

  return problems;
}

/// What is wrong with one measured leg: its exit status and its scorecard.
///
/// The corpus suite judges the failures themselves, in both directions: the
/// run must have exited 0, or a failing file that is not a listed
/// divergence, a listed file that now passes and a changed failure reason
/// are all reported by it. The counts below are read on top of that.
List<String> _legProblem(_CorpusLeg leg, _CommandResult result) => [
  ..._legRunProblems(leg, result),
  ..._legScorecardProblems(leg, result),
];

/// What is wrong with every measured leg, in order.
List<String> _legProblems(List<_LegRun> runs) => [
  for (final run in runs) ..._legProblem(run.leg, run.result),
];

/// The upstream pin, or an empty record when it cannot be read.
Map<String, Object?> _readPin(List<String> problems) {
  try {
    return _pinRecord();
  } on Exception catch (error) {
    problems.add('the upstream pin could not be read: $error');

    return const {};
  }
}

/// The upstream checkout the measurement runs against.
Future<_UpstreamCheckout?> _checkoutStage(
  Map<String, Object?> pin,
  List<String> problems,
) async {
  try {
    return await _upstreamCheckout(pin, problems);
  } on Exception catch (error) {
    problems.add('the upstream checkout could not be prepared: $error');

    return null;
  }
}

/// The problems the corpus records stage found.
Future<List<String>> _corpusRecordStage(_UpstreamCheckout? checkout) async {
  try {
    return await _corpusRecordProblems(checkout?.path);
  } on Exception catch (error) {
    return ['the corpus records could not be checked: $error'];
  }
}

/// The problems the documentation stage found.
List<String> _documentationStage() {
  try {
    return _documentationProblems();
  } on Exception catch (error) {
    return ['the documented versions could not be read: $error'];
  }
}

/// The problems the capability stage found.
Future<List<String>> _capabilityStage() async {
  final problems = <String>[];
  var runs = (
    offline: const _CommandResult(
      command: _capabilityChecker,
      failure: 'the checker did not run',
    ),
    online: const _CommandResult(
      command: '$_capabilityChecker --online',
      failure: 'the checker did not run',
    ),
  );
  try {
    runs = await _measureCapabilityRecords();
  } on Exception catch (error) {
    problems.add('the capability checker could not be run: $error');
  }
  try {
    problems.addAll(_capabilityProblems(runs));
  } on Exception catch (error) {
    problems.add('the capability records could not be checked: $error');
  }

  return problems;
}

/// The problems the corpus legs found.
Future<List<String>> _corpusLegStage() async {
  List<_LegRun>? runs;
  try {
    runs = await _measureCorpusLegs();
  } on Exception catch (error) {
    return ['the corpus legs could not be measured: $error'];
  }
  try {
    return _legProblems(runs);
  } on Exception catch (error) {
    return ['the measured scorecards could not be checked: $error'];
  }
}

/// Removes the checkout this test made, if it made one.
void _cleanupStage(_UpstreamCheckout? checkout, List<String> problems) {
  final temporary = checkout;
  if (temporary == null) {
    return;
  }
  try {
    temporary.cleanup?.call();
  } on Exception catch (error) {
    problems.add('the temporary checkout could not be removed: $error');
  }
}

/// The acceptance: measures the corpus on every leg, checks the records
/// that describe it against the measurement, and reports the difference.
///
/// Every stage runs, whatever the stages before it found: a missing
/// checkout, a stale record and a failing leg are all reported, and the
/// stages that do not depend on them are still measured.
Future<void> _corpusScorecardAcceptance() async {
  final problems = <String>[];

  final pin = _readPin(problems);
  final checkout = await _checkoutStage(pin, problems);
  problems
    ..addAll(await _corpusRecordStage(checkout))
    ..addAll(_documentationStage())
    ..addAll(await _capabilityStage())
    ..addAll(await _corpusLegStage());
  _cleanupStage(checkout, problems);

  expect(problems, isEmpty, reason: problems.join('\n'));
}
