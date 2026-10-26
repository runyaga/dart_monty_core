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
