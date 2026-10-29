@Tags(['vm-only'])
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/mount/native_mount_service.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

// Expectations: design/F/evidence/probes/oracle_probes.out, P01-P08.
// Protobuf is transport only; no expected result is computed by monty-fs.
void main() {
  // One probe runner per suite invocation: it owns this invocation's
  // snapshot, its temporary directory, and nothing else.
  final probe = _ProbeRunner();
  tearDownAll(probe._deleteProbeSnapshot);

  test(
    'the lookup route names the discovery path that supplied the symbols',
    () {
      expect(nativeMountLookupRoute, isIn(<String>['asset', 'package']));
    },
  );
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dmfs-');
    File('${dir.path}/a.txt').writeAsStringSync('host');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  NativeMountRoot root({
    String path = '/d',
    String? host,
    String mode = 'overlay',
    int? writes,
    int memory = 100000000,
  }) {
    final value = NativeMountRoot(
      hostPath: host ?? dir.path,
      virtualPath: path,
      mode: mode,
      writeBytesLimit: writes,
      memoryUsageLimit: memory,
    );
    addTearDown(value.close);

    return value;
  }

  NativeMountTable table(List<NativeMountRoot> roots) {
    final value = NativeMountTable(roots);
    addTearDown(value.close);

    return value;
  }

  test('P01 normalises virtual paths and reports canonical host', () {
    final alias = Link('${dir.path}/alias')..createSync(dir.path);
    final mount = root(path: '/a/../d/', host: alias.path);
    expect(mount.virtualPath, '/d');
    expect(mount.hostPath, dir.resolveSymbolicLinksSync());
    expect(root(path: '/').virtualPath, '/');
  });
  test('upstream retains embedded NUL virtual labels and mode error text', () {
    // MountRoot::open only requires an absolute virtual path; do not add a
    // C-string truncation or validation rule that upstream does not have.
    expect(root(path: '/d\u0000tail').virtualPath, '/d\u0000tail');
    expect(
      () => root(mode: 'overlay\u0000tail'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "Invalid mode 'overlay\u0000tail', expected 'read-only', "
              "'read-write', or 'overlay'",
        ),
      ),
    );
  });
  test('P01 rejects relative and empty virtual paths', () {
    for (final path in ['data', '']) {
      expect(
        () => root(path: path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "virtual path must be absolute, got: '$path'",
          ),
        ),
      );
    }
  });
  test('P01 rejects missing and file host paths', () {
    for (final (path, suffix) in [
      (
        '${dir.path}/missing',
        Platform.isWindows
            ? 'The system cannot find the file specified. (os error 2)'
            : 'No such file or directory (os error 2)',
      ),
      (
        '${dir.path}/a.txt',
        Platform.isWindows
            ? 'The directory name is invalid. (os error 267)'
            : 'Not a directory (os error 20)',
      ),
    ]) {
      expect(
        () => root(host: path),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "cannot open host path '$path': $suffix",
          ),
        ),
      );
    }
  });
  test('P01 rejects invalid mode and negative budgets', () {
    expect(
      () => root(mode: 'rw'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          "Invalid mode 'rw', expected 'read-only', 'read-write', or 'overlay'",
        ),
      ),
    );
    expect(() => root(writes: -1), throwsRangeError);
    expect(() => root(memory: -1), throwsRangeError);
  });
  test('P02 overlap fails at begin-feed with runtime ValueError', () {
    final first = root(path: '/m1');
    final second = root(path: '/m2');
    expect(
      () => table([first, second]),
      throwsA(
        isA<MontyRuntimeError>()
            .having((e) => e.exception.excType, 'type', 'ValueError')
            .having(
              (e) => e.toString(),
              'text',
              "ValueError: cannot mount '${second.hostPath}' at '/m2': it overlaps "
                  "the mount of '${first.hostPath}' at '/m1'; mounts must have distinct "
                  'virtual paths and disjoint host directories',
            )
            .having((e) => e.traceback, 'traceback', isEmpty),
      ),
    );
  });
  test('P02 duplicate virtual and nested host directories overlap', () {
    final other = Directory.systemTemp.createTempSync('dmfs-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    final nested = Directory('${dir.path}/sub')..createSync();
    for (final second in [
      root(host: other.path),
      root(host: nested.path, path: '/x'),
    ]) {
      expect(
        () => table([root(), second]),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'ValueError')
              .having(
                (e) => e.exception.message,
                'text',
                contains('it overlaps the mount'),
              ),
        ),
      );
    }
  });
  test('nested virtual paths with disjoint hosts use longest prefix', () {
    // P02 also nested its hosts; upstream mount_table.rs explicitly permits
    // nested virtual paths when the hosts are disjoint (contract rule 7a).
    final other = Directory.systemTemp.createTempSync('dmfs-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    File('${other.path}/a.txt').writeAsStringSync('nested');
    final feed = table([root(), root(host: other.path, path: '/d/sub')]);
    expect(
      value(feed, pb.OsCall(readText: '/d/sub/a.txt')),
      const MontyString('nested'),
    );
  });
  test(
    'P03 closed root refuses new tables but existing table retains capability',
    () {
      final mount = root();
      final feed = table([mount]);
      mount
        ..close()
        ..close();
      expect(mount.virtualPath, '/d');
      expect(
        () => table([mount]),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            "mount '/d' is closed",
          ),
        ),
      );
      expect(
        value(feed, pb.OsCall(readText: '/d/a.txt')),
        const MontyString('host'),
      );
    },
  );
  test(
    'P07 route 2 handles reads and leaves outside and non-fs calls unhandled',
    () async {
      final feed = table([root()]);
      // Other suites may have loaded global symbols already. Check discovery
      // in a fresh VM so @Native's process fallback cannot mask route 2.
      final lookup = await probe._runProbe(['--lookup-only']);
      expect(lookup.exitCode, 0, reason: '${lookup.stdout}\n${lookup.stderr}');
      expect(lookup.stdout, contains('mount lookup: package'));
      expect(
        value(feed, pb.OsCall(readText: '/d/a.txt')),
        const MontyString('host'),
      );
      expect(
        feed.call(pb.OsCall(readText: '/else/a.txt').writeToBuffer()),
        isNull,
      );
      expect(
        feed.call(
          pb.OsCall(getEnviron: pb.Unit()).writeToBuffer(),
        ),
        isNull,
      );
      expect(
        error(feed, pb.OsCall(readText: '/d/nope.txt')),
        "FileNotFoundError: [Errno 2] No such file or directory: '/d/nope.txt'",
      );
    },
  );
  test('P04 read-only refuses writes', () {
    expect(
      error(table([root(mode: 'read-only')]), write('ov')),
      "PermissionError: [Errno 30] Read-only file system: '/d/a.txt'",
    );
  });
  test('P04 overlay is discarded at end-feed', () {
    final mount = root();
    final first = table([mount]);
    expect(value(first, write('ov')), const MontyInt(2));
    expect(
      value(first, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('ov'),
    );
    first.close();
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'host');
    expect(
      value(table([mount]), pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
    expect(
      () => first.call(pb.OsCall(exists: '/d').writeToBuffer()),
      throwsStateError,
    );
  });
  test('P04 read-write persists on host', () {
    expect(
      value(table([root(mode: 'read-write')]), write('rw')),
      const MontyInt(2),
    );
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'rw');
  });
  test('P05 write budget resets per table', () {
    final mount = root(writes: 10);
    final first = table([mount]);
    final request = write('12345678');
    expect(value(first, request), const MontyInt(8));
    expect(
      error(first, request),
      'OSError: disk write limit of 10 bytes exceeded',
    );
    first.close();
    expect(value(table([mount]), request), const MontyInt(8));
  });
  test('P05 transient reads obey memory budget in every mode', () {
    File('${dir.path}/a.txt').writeAsStringSync('a' * 5000);
    for (final mode in ['overlay', 'read-write', 'read-only']) {
      expect(
        error(
          table([root(mode: mode, memory: 1000)]),
          pb.OsCall(readText: '/d/a.txt'),
        ),
        'MemoryError: mount memory usage limit of 1 KB exceeded',
      );
    }
  });
  test('P05 exists needs no read buffer at zero memory', () {
    expect(
      value(table([root(memory: 0)]), pb.OsCall(exists: '/d/a.txt')),
      const MontyBool(true),
    );
  });
  test('tables have independent live overlays', () {
    final mount = root();
    final first = table([mount]);
    final second = table([mount]);
    expect(value(first, write('ov')), const MontyInt(2));
    expect(
      value(second, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
  });
  test('P05 overlay writes obey memory budget', () {
    expect(
      error(table([root(memory: 1000)]), write('a' * 2000)),
      'MemoryError: mount memory usage limit of 1 KB exceeded',
    );
  });
  test('P08 relative symlink works and absolute symlink is refused', () {
    Link('${dir.path}/rel_link').createSync('a.txt');
    expect(Link('${dir.path}/rel_link').targetSync(), 'a.txt');
    expect(File('${dir.path}/rel_link').readAsStringSync(), 'host');
    Link('${dir.path}/abs_link').createSync('${dir.path}/a.txt');
    // P08 explicitly uses read-write; overlay refuses all symlinks upstream.
    final feed = table([root(mode: 'read-write')]);
    expect(
      value(feed, pb.OsCall(readText: '/d/rel_link')),
      const MontyString('host'),
    );
    expect(
      error(feed, pb.OsCall(readText: '/d/abs_link')),
      "PermissionError: [Errno 13] Permission denied: '/d/abs_link'",
    );
  });
  test('P08 cross-mount and outside rename are refused', () {
    final other = Directory.systemTemp.createTempSync('dmfs-other-');
    addTearDown(() => other.deleteSync(recursive: true));
    final feed = table([root(), root(host: other.path, path: '/m2')]);
    for (final dest in ['/m2/a.txt', '/else/a.txt']) {
      expect(
        error(
          feed,
          pb.OsCall(
            rename: pb.OsCall_Rename(src: '/d/a.txt', dst: dest),
          ),
        ),
        "OSError: [Errno 18] Invalid cross-device link: '/d/a.txt' -> '$dest'",
      );
    }
  });
  test('opened root survives host directory rename', () {
    final mount = root();
    final original = dir.path;
    dir = dir.renameSync('$original-renamed');
    Directory(original).createSync();
    addTearDown(() => Directory(original).deleteSync());
    expect(
      value(table([mount]), pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
  }, skip: Platform.isWindows ? 'POSIX directory rename semantics' : false);
  test('Windows refuses renaming a live directory capability', () {
    final mount = root();
    final feed = table([mount]);
    final destination = '${dir.path}-renamed';
    expect(
      () => dir.renameSync(destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(
      value(feed, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
    feed.close();
    mount.close();
    dir = dir.renameSync(destination);
  }, skip: !Platform.isWindows ? 'Windows sharing mode contract' : false);
  test('NativeFinalizer releases unclosed directory capabilities', () async {
    final result = await probe._runProbe(
      [],
      vmOptions: ['--enable-vm-service=0'],
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('finalized 32 mount roots'));
  }, skip: Platform.isWindows ? 'descriptor probe uses POSIX fcntl' : false);
  test('malformed protobuf is refused without poisoning the table', () {
    final feed = table([root()]);
    expect(() => feed.call([255]), throwsFormatException);
    expect(
      value(feed, pb.OsCall(readText: '/d/a.txt')),
      const MontyString('host'),
    );
  });

  // The Scan cases, each registered with its own body. They are red until the
  // native worker answers upstream's scan call: the red test proper, and the
  // also-red cases the aggregate in `expectScanCases` attempts.
  test('a scan lists the tree to its depth', _expectScanDepths);
  test('a scan of a file or a missing path', _expectScanRoots);
  test('a glob replies with its matches', _expectScanGlobs);
  test(
    'a scan outside every mount is not handled',
    _expectScanOutsideEveryMount,
  );
  test(
    'the overlay is scanned and never reaches the disk',
    _expectScanOverlay,
  );
  test(
    'links are described and followed only on request',
    _expectScanSymlinks,
    skip: Platform.isWindows ? 'POSIX symlink semantics' : false,
  );
  test('a nested mount is read through the table', _expectScanNestedMounts);
}

pb.OsCall write(String content) => pb.OsCall(
  writeText: pb.OsCall_TextWrite(path: '/d/a.txt', data: content),
);

pb.ResumeCall reply(NativeMountTable table, pb.OsCall call) {
  call.callId = 73;
  final bytes = table.call(call.writeToBuffer());
  expect(bytes, isNotNull);
  final result = pb.ResumeCall.fromBuffer(
    bytes ?? (throw StateError('unhandled mount call')),
  );
  expect(result.callId, 73);

  return result;
}

MontyValue value(NativeMountTable table, pb.OsCall call) {
  final replyValue = reply(table, call);
  final result = replyValue.result;
  final exception = result.error;
  expect(
    result.whichKind(),
    pb.ExtFunctionResult_Kind.returnValue,
    reason: '${exception.excType}: ${exception.message}',
  );

  return ArenaReader(replyValue.values)[result.returnValue];
}

String error(NativeMountTable table, pb.OsCall call) {
  final result = reply(table, call).result;
  expect(result.whichKind(), pb.ExtFunctionResult_Kind.error);
  final exception = result.error;

  return '${exception.excType}: ${exception.message}';
}

/// The checkout root that owns this package.
///
/// The package library's own location is the anchor: the probe, the package
/// configuration and the worker binaries all live below it. Resolving the
/// package URI keeps the paths correct no matter which directory the test
/// runner was started from.
String _packageRoot() {
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:dart_monty_core/dart_monty_core.dart'),
  );
  if (library == null) {
    throw StateError(
      'cannot resolve package:dart_monty_core/dart_monty_core.dart',
    );
  }
  // <root>/lib/dart_monty_core.dart -> <root>/lib -> <root>
  final root = File.fromUri(library).parent.parent;

  return root.path;
}

/// Compiles and runs the native mount probe for one suite invocation.
///
/// The probe is compiled once per suite invocation, asynchronously, into a
/// private temporary directory; each probe execution then runs that kernel
/// snapshot in a fresh Dart VM. Separate test processes compile concurrently:
/// they share neither output paths nor coordination state, so no lock, cache
/// or PID protocol is involved.
final class _ProbeRunner {
  /// The compilation started by this suite invocation, if any.
  Future<File>? _snapshot;

  /// The temporary directory holding this invocation's snapshot, if any.
  Directory? _snapshotDirectory;

  /// The compiled probe snapshot, compiling it at most once per invocation.
  Future<File> _probeSnapshot() {
    final pending = _snapshot;
    if (pending != null) return pending;

    // Recorded before it is awaited, so a second caller reuses the same
    // compilation instead of starting another one.
    final compilation = _compileProbe();
    _snapshot = compilation;

    return compilation;
  }

  /// Compiles the probe into this invocation's private temporary directory.
  Future<File> _compileProbe() async {
    final root = _packageRoot();
    final directory = await Directory.systemTemp.createTemp('dmfs-probe-');
    _snapshotDirectory = directory;
    final snapshot = File('${directory.path}/native_mount_probe.dill');
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'kernel',
        '$root/test/unit/mount/native_mount_finalizer_probe.dart',
        '--packages=$root/.dart_tool/package_config.json',
        '-o',
        snapshot.path,
      ],
      workingDirectory: root,
    );
    if (result.exitCode != 0 || !snapshot.existsSync()) {
      await _removePartialSnapshot(snapshot);
      throw StateError(
        'native mount probe compilation failed '
        '(exit ${result.exitCode}):\n${result.stdout}\n${result.stderr}',
      );
    }

    return snapshot;
  }

  /// Runs the compiled probe in a fresh VM and returns its result.
  Future<ProcessResult> _runProbe(
    List<String> arguments, {
    List<String> vmOptions = const [],
  }) async {
    final root = _packageRoot();
    final snapshot = await _probeSnapshot();

    return Process.run(
      Platform.resolvedExecutable,
      [
        ...vmOptions,
        '--packages=$root/.dart_tool/package_config.json',
        snapshot.path,
        ...arguments,
      ],
      workingDirectory: root,
    );
  }

  /// Removes this invocation's temporary directory, once compilation settled.
  Future<void> _deleteProbeSnapshot() async {
    final pending = _snapshot;
    if (pending != null) {
      // Let a started compilation settle before its directory disappears.
      try {
        await pending;
      } on Object {
        // The test that asked for the snapshot reports the failure.
      }
    }
    final directory = _snapshotDirectory;
    if (directory == null) return;
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
  }

  /// Removes a partial compilation artefact, keeping the original failure.
  Future<void> _removePartialSnapshot(File snapshot) async {
    if (!snapshot.existsSync()) return;
    try {
      await snapshot.delete();
    } on FileSystemException {
      // The suite teardown removes the whole temporary directory.
    }
  }
}

// =============================================================================
// Scan: the one OS call behind os.scandir, os.walk, Path.walk and Path.glob.
//
// Upstream monty v1.2.0 pins both reply shapes: a tree of
// (path, is_dir, is_file, is_symlink) tuples, and a glob's matches as
// {'matches': [path, ...]}. These cases are red until the native worker
// answers that call; they are the red test and the also-red cases the
// aggregate in `expectScanCases` attempts.
// =============================================================================

/// A Scan case: the name it is reported under and the body that checks it.
///
/// The aggregate that runs these cases imports this file, so `main` does not
/// reach it.
// ignore: unreachable_from_main, the aggregate imports this file.
typedef ScanCase = ({String name, void Function() body});

/// The Scan cases the native mount must satisfy, in the order they run.
///
/// The first is the red test; the other six are the also-red cases. Every
/// case owns the resources it takes and releases them before it returns, so
/// the aggregate can attempt all of them in one run.
// ignore: unreachable_from_main, the aggregate imports this file.
List<ScanCase> scanCases() => [
  (name: 'a scan lists the tree to its depth', body: _expectScanDepths),
  (name: 'a scan of a file or a missing path', body: _expectScanRoots),
  (name: 'a glob replies with its matches', body: _expectScanGlobs),
  (
    name: 'a scan outside every mount is not handled',
    body: _expectScanOutsideEveryMount,
  ),
  (
    name: 'the overlay is scanned and never reaches the disk',
    body: _expectScanOverlay,
  ),
  (
    name: 'links are described and followed only on request',
    body: _expectScanSymlinks,
  ),
  (
    name: 'a nested mount is read through the table',
    body: _expectScanNestedMounts,
  ),
];

/// Attempts every Scan case and collects the failures, labelled by case.
///
/// A case that fails still releases its own resources, and a later case is
/// attempted whatever an earlier one did.
// ignore: unreachable_from_main, the aggregate imports this file.
List<String> expectScanCases() {
  final failures = <String>[];
  for (final scanCase in scanCases()) {
    try {
      scanCase.body();
    } on Object catch (error) {
      failures.add('${scanCase.name}: $error');
    }
  }

  return failures;
}

/// A scan of [path], with the depth and the link handling upstream uses.
///
/// An absent [maxDepth] is the whole tree, `0` the root alone; an absent
/// [caseSensitive] is CPython's default, which looks literal parts up.
pb.OsCall _scanCall(
  String path, {
  int? maxDepth,
  bool followSymlinks = false,
  bool? caseSensitive,
}) => pb.OsCall(
  callId: 73,
  scan: pb.OsCall_Scan(
    path: path,
    maxDepth: maxDepth,
    followSymlinks: followSymlinks,
    caseSensitive: caseSensitive,
  ),
);

/// A glob of the pattern parts [parts] below [path].
///
/// Upstream derives the depth and the link handling from the parts: the depth
/// is absent when a part is `**`, and the scan follows links when a part
/// before the last one may match a linked directory.
pb.OsCall _globCall(
  String path,
  List<String> parts, {
  bool recurseSymlinks = false,
}) {
  final recursive = parts.contains('**');
  final depth = parts.where((part) => !_isSpecialPart(part)).length;
  final descends =
      parts.length > 1 &&
      parts
          .take(parts.length - 1)
          .any((part) => part != '**' && !_isSpecialPart(part));

  return pb.OsCall(
    callId: 73,
    scan: pb.OsCall_Scan(
      path: path,
      maxDepth: recursive ? null : depth,
      followSymlinks: recurseSymlinks || descends,
      pattern: parts,
      recurseSymlinks: recurseSymlinks,
    ),
  );
}

/// Whether a pattern part is one CPython never matches against a name.
bool _isSpecialPart(String part) => part == '' || part == '.' || part == '..';

/// The tree a scan reply holds, as (path, kind) records sorted by path.
///
/// The reply is a list of four-element tuples, each naming its path and
/// describing it with three booleans; anything else is a failure, not a
/// shorter answer.
List<(String, String)> _entries(MontyValue reply) {
  if (reply is! MontyList) {
    fail('a scan tree is a list, got ${reply.runtimeType}');
  }
  final records = <(String, String)>[];
  for (final entry in reply.items) {
    if (entry is! MontyTuple || entry.items.length != 4) {
      fail('a scan tree entry is a four-element tuple, got $entry');
    }
    final [path, isDirectory, isFile, isSymlink] = entry.items;
    if (path is! MontyString) {
      fail('a scan tree entry names its path with a string, got $path');
    }
    if (isDirectory is! MontyBool ||
        isFile is! MontyBool ||
        isSymlink is! MontyBool) {
      fail(
        'a scan tree entry describes its path with three booleans, got $entry',
      );
    }
    records.add((
      path.value,
      _scanKind(isDirectory.value, isFile.value, isSymlink.value),
    ));
  }
  records.sort(_compareScanEntries);

  return records;
}

/// The kind one scan entry describes.
String _scanKind(bool isDirectory, bool isFile, bool isSymlink) =>
    switch ((isDirectory, isFile, isSymlink)) {
      (true, false, false) => 'd',
      (false, true, false) => 'f',
      (true, false, true) => 'D',
      (false, true, true) => 'F',
      (false, false, true) => 'l',
      _ => fail(
        'a scan entry is a directory, a file, a link to one or a dangling '
        'link, got ($isDirectory, $isFile, $isSymlink)',
      ),
    };

/// Orders scan records by their path, then by their kind.
int _compareScanEntries((String, String) left, (String, String) right) {
  final byPath = left.$1.compareTo(right.$1);
  if (byPath != 0) {
    return byPath;
  }

  return left.$2.compareTo(right.$2);
}

/// The paths a glob reply holds, sorted lexically.
///
/// The reply is one dictionary entry, `matches`, holding a list of paths.
List<String> _matches(MontyValue reply) {
  if (reply is! MontyDict || reply.pairs.length != 1) {
    fail("a scan matches reply is one 'matches' entry, got $reply");
  }
  final [(key, paths)] = reply.pairs;
  if (key is! MontyString || key.value != 'matches') {
    fail("a scan matches reply is keyed 'matches', got $reply");
  }
  if (paths is! MontyList) {
    fail('a scan matches reply holds a list of paths, got $reply');
  }
  final matches = <String>[];
  for (final path in paths.items) {
    if (path is! MontyString) {
      fail('a scan match is a path, got $path');
    }
    matches.add(path.value);
  }
  matches.sort();

  return matches;
}

/// Runs [body] and then [cleanup], keeping every failure of either.
///
/// A failure of [body] survives a failure of [cleanup]: the cleanup failure
/// is reported beside it, never in place of it.
void _protect(void Function() body, void Function() cleanup) {
  final failures = <(Object, StackTrace)>[];
  try {
    body();
  } on Object catch (error, stack) {
    failures.add((error, stack));
  }
  try {
    cleanup();
  } on Object catch (error, stack) {
    failures.add((error, stack));
  }
  if (failures.length == 1) {
    Error.throwWithStackTrace(failures.single.$1, failures.single.$2);
  }
  if (failures.length > 1) {
    fail(failures.map((failure) => '${failure.$1}').join('\n'));
  }
}

/// Runs [body] with a table over the roots [roots] opens.
///
/// The table is closed before the roots, and every root is closed even when
/// another one fails to close.
void _withScanTable(
  List<NativeMountRoot Function()> roots,
  void Function(NativeMountTable table) body,
) {
  final opened = <NativeMountRoot>[];
  _protect(
    () {
      for (final open in roots) {
        opened.add(open());
      }
      final table = NativeMountTable(opened);
      _protect(() => body(table), table.close);
    },
    () => _closeRoots(opened),
  );
}

/// Closes every root, reporting each failure of one.
void _closeRoots(List<NativeMountRoot> roots) {
  final failures = <String>[];
  for (final root in roots) {
    try {
      root.close();
    } on Object catch (error) {
      failures.add('$error');
    }
  }
  if (failures.isNotEmpty) {
    fail(failures.join('\n'));
  }
}

/// A root over [hostPath], released by the caller's cleanup.
NativeMountRoot _scanRoot(
  String hostPath, {
  String virtualPath = '/mnt',
  String mode = 'overlay',
}) => NativeMountRoot(
  hostPath: hostPath,
  virtualPath: virtualPath,
  mode: mode,
);

/// The tree every scan case scans.
///
/// ```text
/// fixture/
///   a.txt
///   b.py
///   sub/
///     c.txt
///     deep/
///       d.py
/// ```
void _writeScanTree(Directory fixture) {
  File('${fixture.path}/a.txt').writeAsStringSync('a');
  File('${fixture.path}/b.py').writeAsStringSync('b');
  Directory('${fixture.path}/sub/deep').createSync(recursive: true);
  File('${fixture.path}/sub/c.txt').writeAsStringSync('c');
  File('${fixture.path}/sub/deep/d.py').writeAsStringSync('d');
}

/// Runs a case body, reporting a refused scan as a failure.
///
/// The service refuses a call it cannot decode by raising a
/// [FormatException]; that is a failure of the scan, never an answer.
void _scanCase(void Function() body) {
  try {
    body();
  } on FormatException catch (error) {
    fail('the mount service refused the scan call: $error');
  }
}

/// A scan lists the tree to its depth.
void _expectScanDepths() {
  _scanCase(() {
    final wholeTree = _scanCall('/mnt');
    final rootAlone = _scanCall('/mnt', maxDepth: 0);
    final children = _scanCall('/mnt', maxDepth: 1);
    final pedantic = _scanCall('/mnt', caseSensitive: false);
    expect(
      wholeTree.scan.hasMaxDepth(),
      isFalse,
      reason: 'the whole tree asks for no depth',
    );
    expect(
      rootAlone.scan.hasMaxDepth(),
      isTrue,
      reason: 'the root alone asks for depth zero',
    );
    expect(
      wholeTree.scan.hasCaseSensitive(),
      isFalse,
      reason: "CPython's default case sensitivity is not sent",
    );
    expect(
      pedantic.scan.hasCaseSensitive(),
      isTrue,
      reason: 'an explicit case sensitivity is sent',
    );
    final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(fixture);
        for (final mode in ['read-write', 'read-only', 'overlay']) {
          _withScanTable(
            [() => _scanRoot(fixture.path, mode: mode)],
            (table) {
              expect(
                _entries(value(table, rootAlone)),
                [('', 'd')],
                reason: 'the root alone in $mode',
              );
              expect(
                _entries(value(table, children)),
                [('', 'd'), ('a.txt', 'f'), ('b.py', 'f'), ('sub', 'd')],
                reason: 'the children of the root in $mode',
              );
              expect(
                _entries(value(table, wholeTree)),
                [
                  ('', 'd'),
                  ('a.txt', 'f'),
                  ('b.py', 'f'),
                  ('sub', 'd'),
                  ('sub/c.txt', 'f'),
                  ('sub/deep', 'd'),
                  ('sub/deep/d.py', 'f'),
                ],
                reason: 'the whole tree in $mode',
              );
            },
          );
        }
      },
      () => fixture.deleteSync(recursive: true),
    );
  });
}

/// A scan of a file or a missing path.
void _expectScanRoots() {
  _scanCase(() {
    final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(fixture);
        for (final mode in ['read-write', 'read-only', 'overlay']) {
          _withScanTable(
            [() => _scanRoot(fixture.path, mode: mode)],
            (table) {
              expect(
                error(table, _scanCall('/mnt/nope')),
                'FileNotFoundError: [Errno 2] No such file or directory: '
                "'/mnt/nope'",
                reason: 'a missing root in $mode',
              );
              expect(
                _entries(value(table, _scanCall('/mnt/a.txt'))),
                [('', 'f')],
                reason: 'a file root is described, not listed, in $mode',
              );
            },
          );
        }
      },
      () => fixture.deleteSync(recursive: true),
    );
  });
}

/// A glob replies with its matches.
void _expectScanGlobs() {
  _scanCase(() {
    expect(
      _globCall('/mnt', ['**', '*']).scan.hasMaxDepth(),
      isFalse,
      reason: 'a recursive glob asks for no depth',
    );
    expect(
      _globCall('/mnt', ['*.txt']).scan.maxDepth,
      1,
      reason: 'a glob of one part asks for one level',
    );
    expect(
      _globCall('/mnt', ['*', 'c.txt']).scan.followSymlinks,
      isTrue,
      reason: 'a wildcard before the last part may match a linked directory',
    );
    expect(
      _globCall('/mnt', ['*']).scan.followSymlinks,
      isFalse,
      reason: 'the last part alone matches no linked directory',
    );
    final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(fixture);
        for (final mode in ['read-write', 'read-only', 'overlay']) {
          _withScanTable(
            [() => _scanRoot(fixture.path, mode: mode)],
            (table) {
              expect(
                _matches(value(table, _globCall('/mnt', ['*.txt']))),
                ['a.txt'],
                reason: 'a glob of the root in $mode',
              );
              expect(
                _matches(value(table, _globCall('/mnt', ['s*', 'deep', '*']))),
                ['sub/deep/d.py'],
                reason: 'a glob through a matched directory in $mode',
              );
              expect(
                _matches(value(table, _globCall('/mnt', ['**', '']))),
                ['', 'sub/', 'sub/deep/'],
                reason: 'a glob for directories in $mode',
              );
              expect(
                _matches(value(table, _globCall('/mnt', ['nope', '*']))),
                isEmpty,
                reason: 'a glob that matches nothing in $mode',
              );
            },
          );
        }
      },
      () => fixture.deleteSync(recursive: true),
    );
    // A glob whose matches outnumber the entries it read replies with the
    // tree it read instead of with its matches.
    final expanded = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(expanded);
        Directory('${expanded.path}/sub/deep/x/y').createSync(recursive: true);
        File('${expanded.path}/sub/deep/x/y/e.py').writeAsStringSync('e');
        _withScanTable(
          [() => _scanRoot(expanded.path, mode: 'read-only')],
          (table) {
            expect(
              _entries(value(table, _globCall('/mnt', ['**', '*', '**']))),
              contains(('sub/deep/x/y/e.py', 'f')),
              reason: 'the tree an amplifying glob read',
            );
            expect(
              _matches(
                value(
                  table,
                  _globCall('/mnt/sub/deep/x', ['**', '*', '**']),
                ),
              ),
              ['y/', 'y/e.py'],
              reason: 'the matches the same glob found below its root',
            );
          },
        );
      },
      () => expanded.deleteSync(recursive: true),
    );
  });
}

/// A scan outside every mount is not handled.
void _expectScanOutsideEveryMount() {
  _scanCase(() {
    final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(fixture);
        _withScanTable(
          [() => _scanRoot(fixture.path, mode: 'read-write')],
          (table) {
            expect(
              table.call(_scanCall('/mnt/..').writeToBuffer()),
              isNull,
              reason: 'a scan outside every mount is not handled',
            );
          },
        );
      },
      () => fixture.deleteSync(recursive: true),
    );
  });
}

/// The overlay is scanned and never reaches the disk.
void _expectScanOverlay() {
  _scanCase(() {
    final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(fixture);
        _withScanTable(
          [() => _scanRoot(fixture.path)],
          (table) {
            expect(
              value(
                table,
                pb.OsCall(
                  writeText: pb.OsCall_TextWrite(
                    path: '/mnt/sub/new.txt',
                    data: 'new',
                  ),
                ),
              ),
              const MontyInt(3),
              reason: 'the overlay holds the write',
            );
            expect(
              value(table, pb.OsCall(unlink: '/mnt/a.txt')),
              const MontyNone(),
              reason: 'an overlay unlink answers None',
            );
            expect(
              _matches(value(table, _globCall('/mnt', ['**', '*.txt']))),
              ['sub/c.txt', 'sub/new.txt'],
              reason: 'the overlay is scanned, not the disk',
            );
            expect(
              File('${fixture.path}/sub/new.txt').existsSync(),
              isFalse,
              reason: 'the overlay write reached no disk',
            );
            expect(
              File('${fixture.path}/a.txt').readAsStringSync(),
              'a',
              reason: 'the overlay unlink reached no disk',
            );
          },
        );
      },
      () => fixture.deleteSync(recursive: true),
    );
  });
}

/// Links are described and followed only on request.
void _expectScanSymlinks() {
  _scanCase(() {
    final outside = Directory.systemTemp.createTempSync('dmfs-outside-');
    _protect(
      () {
        File('${outside.path}/secret.txt').writeAsStringSync('secret');
        final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
        _protect(
          () {
            _writeScanTree(fixture);
            Link('${fixture.path}/linkdir').createSync('sub');
            Link('${fixture.path}/linkfile').createSync('a.txt');
            Link('${fixture.path}/dangling').createSync('missing');
            Link('${fixture.path}/escape').createSync(outside.path);
            _withScanTable(
              [() => _scanRoot(fixture.path, mode: 'read-write')],
              (table) {
                expect(
                  _entries(value(table, _scanCall('/mnt', maxDepth: 1))),
                  [
                    ('', 'd'),
                    ('a.txt', 'f'),
                    ('b.py', 'f'),
                    ('linkdir', 'D'),
                    ('linkfile', 'F'),
                    ('sub', 'd'),
                  ],
                  reason: 'the links of the mount are described',
                );
                expect(
                  _entries(value(table, _scanCall('/mnt'))).any(
                    (entry) => entry.$1.startsWith('linkdir/'),
                  ),
                  isFalse,
                  reason: 'a scan does not descend a linked directory',
                );
                final followed = _entries(
                  value(table, _scanCall('/mnt', followSymlinks: true)),
                );
                expect(
                  followed,
                  contains(('linkdir/deep/d.py', 'f')),
                  reason: 'a scan follows the links it is told to',
                );
                expect(
                  followed.any((entry) => entry.$1.contains('secret')),
                  isFalse,
                  reason: 'a scan never leaves the mount',
                );
                expect(
                  _matches(value(table, _globCall('/mnt', ['**', '*.py']))).any(
                    (path) => path.startsWith('linkdir/'),
                  ),
                  isFalse,
                  reason: 'a recursive glob does not descend a link',
                );
                expect(
                  _matches(value(table, _globCall('/mnt', ['*', 'c.txt']))),
                  containsAll(['linkdir/c.txt', 'sub/c.txt']),
                  reason: 'a wildcard may match a linked directory',
                );
                expect(
                  _matches(
                    value(
                      table,
                      _globCall(
                        '/mnt',
                        ['**', '*.py'],
                        recurseSymlinks: true,
                      ),
                    ),
                  ),
                  contains('linkdir/deep/d.py'),
                  reason: 'a recursive glob follows the links it is told to',
                );
                expect(
                  _matches(
                    value(table, _globCall('/mnt', ['linkdir', 'c.txt'])),
                  ),
                  ['linkdir/c.txt'],
                  reason: 'a read-write mount reads through a linked directory',
                );
                for (final name in ['escape', 'dangling']) {
                  expect(
                    _matches(value(table, _globCall('/mnt', [name]))),
                    isEmpty,
                    reason: 'a literal lookup of $name finds nothing',
                  );
                  expect(
                    _matches(
                      value(table, _globCall('/mnt', ['*', '..', name])),
                    ),
                    isEmpty,
                    reason: 'a wildcard lookup of $name finds nothing',
                  );
                }
              },
            );
            _withScanTable(
              [() => _scanRoot(fixture.path)],
              (table) {
                expect(
                  _entries(value(table, _scanCall('/mnt', maxDepth: 1))),
                  [
                    ('', 'd'),
                    ('a.txt', 'f'),
                    ('b.py', 'f'),
                    ('linkdir', 'l'),
                    ('linkfile', 'l'),
                    ('sub', 'd'),
                  ],
                  reason: 'an overlay describes the links it refuses to follow',
                );
                expect(
                  error(table, _scanCall('/mnt/linkfile', maxDepth: 0)),
                  startsWith('FileNotFoundError:'),
                  reason: 'an overlay does not read through a link',
                );
                expect(
                  _matches(
                    value(table, _globCall('/mnt', ['linkdir', 'c.txt'])),
                  ),
                  isEmpty,
                  reason: 'an overlay finds nothing through a link',
                );
              },
            );
          },
          () => fixture.deleteSync(recursive: true),
        );
      },
      () => outside.deleteSync(recursive: true),
    );
  });
}

/// A nested mount is read through the table.
void _expectScanNestedMounts() {
  _scanCase(() {
    final fixture = Directory.systemTemp.createTempSync('dmfs-scan-');
    _protect(
      () {
        _writeScanTree(fixture);
        final nested = Directory.systemTemp.createTempSync('dmfs-nested-');
        _protect(
          () {
            File('${nested.path}/other.txt').writeAsStringSync('other');
            _withScanTable(
              [
                () => _scanRoot(fixture.path, mode: 'read-write'),
                () => _scanRoot(
                  nested.path,
                  virtualPath: '/mnt/sub',
                  mode: 'read-only',
                ),
              ],
              (table) {
                expect(
                  _entries(value(table, _scanCall('/mnt'))),
                  [
                    ('', 'd'),
                    ('a.txt', 'f'),
                    ('b.py', 'f'),
                    ('sub', 'd'),
                    ('sub/other.txt', 'f'),
                  ],
                  reason: 'a nested mount shadows the directory below it',
                );
                expect(
                  _matches(value(table, _globCall('/mnt', ['*', 'other.txt']))),
                  ['sub/other.txt'],
                  reason: 'a glob reads the nested mount',
                );
                expect(
                  _matches(value(table, _globCall('/mnt', ['*', 'c.txt']))),
                  isEmpty,
                  reason: 'the shadowed entries are not read',
                );
              },
            );
          },
          () => nested.deleteSync(recursive: true),
        );
        final overFile = Directory.systemTemp.createTempSync('dmfs-over-');
        _protect(
          () {
            File('${overFile.path}/x.txt').writeAsStringSync('x');
            _withScanTable(
              [
                () => _scanRoot(fixture.path, mode: 'read-write'),
                () => _scanRoot(
                  overFile.path,
                  virtualPath: '/mnt/b.py',
                  mode: 'read-only',
                ),
              ],
              (table) {
                final tree = _entries(value(table, _scanCall('/mnt')));
                expect(
                  tree,
                  contains(('b.py', 'd')),
                  reason: 'a mount over a file describes the mount',
                );
                expect(
                  tree,
                  contains(('b.py/x.txt', 'f')),
                  reason: 'a mount over a file is read, not the file',
                );
              },
            );
          },
          () => overFile.deleteSync(recursive: true),
        );
      },
      () => fixture.deleteSync(recursive: true),
    );
  });
}
