// The documentation names the versions the package is at: the upstream
// `monty` version the package tracks, and the version of the package
// itself. Both are read out of the repository -- the upstream version from
// tool/upstream/upstream-pin.json, the package version from pubspec.yaml --
// so this test follows the pin instead of a copy of it, and a page that
// names a stale version fails whatever that stale version is.
//
// The package version is compared without its development suffix: the
// manifest may carry a pre-release (a development number written after a
// dash), while the pages name the plain release version, so the suffix is
// dropped before the comparison.
//
// The pages checked are the ones a reader lands on and that name the
// pinned version in prose: the upstream divergences page and the
// documentation index.
//
// The site index is a template: tool/build_pages.py fills the version
// tokens in it from the pin and the manifest, and refuses a page that
// hardcodes a version, so the site index is not read for a version but
// for the tokens it carries -- each of them exactly once.
//
// The capability cites are not checked here: they are re-pointed by the
// docs green from a measured list, so the pages that name the versions are
// what this test holds, and no lasting test names the cites.
//
// The test only reads the checkout: it runs no checker, clones nothing,
// fetches nothing and installs nothing.
//
// VM only: the pages, the pin and the manifest are repository files, and
// reading them needs dart:io.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The pin record: the upstream version the package is measured against.
const _pinPath = 'tool/upstream/upstream-pin.json';

/// The manifest: the version this package publishes under.
const _manifestPath = 'pubspec.yaml';

/// The pages that must name the pinned upstream version.
const _upstreamPages = [
  'docs/reference/upstream-divergences.md',
  'docs/README.md',
];

/// The site index: the page the builder fills with the versions.
const _templatePage = 'docs/index.html';

/// The version tokens the site index carries, each of them exactly once.
const _templateTokens = ['@dart_monty_core_version@', '@monty_version@'];

/// The manifest line that carries the package version.
final RegExp _manifestVersion = RegExp(r'^version:\s*(\S+)');

/// A version as a page writes it: three numbers separated by dots or more,
/// with an optional pre-release suffix after a dash.
final RegExp _statedVersion = RegExp(r'\d+(?:\.\d+){2,}(?:-[0-9A-Za-z.]+)?');

void main() {
  test('current docs name the pinned upstream and package versions', () {
    final root = _repositoryRoot();
    final upstream = _pinnedUpstreamVersion(root);
    final package = _packageVersion(root);
    final mismatches = <String>[];
    for (final page in _upstreamPages) {
      final mismatch = _mismatch(root, page, upstream, 'upstream');
      if (mismatch != null) {
        mismatches.add(mismatch);
      }
    }
    mismatches.addAll(_tokenMismatches(root));
    expect(
      mismatches,
      isEmpty,
      reason:
          'the documentation must name the pinned upstream version $upstream '
          'and the package version $package; ${mismatches.join('; ')}',
    );
  });
}

/// The upstream version pinned in tool/upstream/upstream-pin.json, read from
/// the checkout at [root].
String _pinnedUpstreamVersion(Directory root) {
  final file = File('${root.path}/$_pinPath');
  if (!file.existsSync()) {
    fail('$_pinPath does not exist');
  }
  final Object? decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, Object?>) {
    fail('$_pinPath does not hold a JSON object');
  }
  final version = decoded['version'];
  if (version is! String) {
    fail('$_pinPath holds no "version" string');
  }

  return version;
}

/// The package version in pubspec.yaml, read from the checkout at [root]
/// and without its development suffix.
String _packageVersion(Directory root) {
  final file = File('${root.path}/$_manifestPath');
  if (!file.existsSync()) {
    fail('$_manifestPath does not exist');
  }
  for (final line in file.readAsLinesSync()) {
    final match = _manifestVersion.firstMatch(line);
    if (match == null) {
      continue;
    }
    final version = match.group(1);
    if (version == null) {
      continue;
    }

    return _withoutSuffix(version);
  }
  fail('$_manifestPath holds no version');
}

/// [version] without its development suffix: the manifest may name a
/// pre-release, while the pages name the plain release version.
String _withoutSuffix(String version) {
  final dash = version.indexOf('-');
  if (dash < 0) {
    return version;
  }

  return version.substring(0, dash);
}

/// What [page] says about the expected [version], or null when the page
/// names it. [kind] names the version in the message: the upstream version
/// or the package version.
String? _mismatch(
  Directory root,
  String page,
  String version,
  String kind,
) {
  final file = File('${root.path}/$page');
  if (!file.existsSync()) {
    return '$page does not exist, so it names no $kind version';
  }
  final lines = file.readAsLinesSync();
  if (_names(lines, version)) {
    return null;
  }
  final reported = _reported(_statedVersions(lines), version);
  if (reported == null) {
    return '$page names no $kind version';
  }

  return '$page:${reported.line} states ${reported.version}, '
      'not the $kind version $version';
}

/// What the site index says about the version tokens it must carry: one
/// message per token that is not carried exactly once, and none when the
/// page carries every token exactly once.
List<String> _tokenMismatches(Directory root) {
  final file = File('${root.path}/$_templatePage');
  if (!file.existsSync()) {
    return ['$_templatePage does not exist, so it carries no version token'];
  }
  final text = file.readAsStringSync();
  final mismatches = <String>[];
  for (final token in _templateTokens) {
    final count = RegExp(RegExp.escape(token)).allMatches(text).length;
    if (count != 1) {
      mismatches.add(
        '$_templatePage carries $token $count times, not once',
      );
    }
  }

  return mismatches;
}

/// Whether [lines] name [version] as a version of its own. The version is
/// escaped and then fenced with boundary patterns, so that a longer number
/// around it -- one with more digits, or one with more dotted parts --
/// cannot pass for it.
bool _names(List<String> lines, String version) {
  final pattern = _versionPattern(version);

  return lines.any(pattern.hasMatch);
}

/// The pattern that matches [version] as a whole version: the escaped
/// version, fenced with boundary patterns on both sides. The fences are
/// concatenated, not interpolated into a raw string, because a raw string
/// does not interpolate.
RegExp _versionPattern(String version) {
  return RegExp(
    r'(?<![\d.])' + RegExp.escape(version) + r'(?![\d])(?![\d.]\d)',
  );
}

/// The versions [lines] state, with the line each one is on.
List<({int line, String version})> _statedVersions(List<String> lines) {
  final stated = <({int line, String version})>[];
  for (var index = 0; index < lines.length; index++) {
    for (final match in _statedVersion.allMatches(lines[index])) {
      final version = match.group(0);
      if (version == null) {
        continue;
      }
      stated.add((line: index + 1, version: version));
    }
  }

  return stated;
}

/// The version to report for a page that does not name [version]: the first
/// one it states that differs, preferring one with the same major number,
/// so the message points at the version the page is stale about.
({int line, String version})? _reported(
  List<({int line, String version})> stated,
  String version,
) {
  final major = _major(version);
  ({int line, String version})? fallback;
  for (final entry in stated) {
    if (entry.version == version) {
      continue;
    }
    fallback ??= entry;
    if (_major(entry.version) == major) {
      return entry;
    }
  }

  return fallback;
}

/// The major number of [version]: the part before its first dot.
String _major(String version) {
  final dot = version.indexOf('.');
  if (dot < 0) {
    return version;
  }

  return version.substring(0, dot);
}

/// The repository root: the directory that holds the pin record. It is found
/// through the package's own library, which does not move with the working
/// directory, and falls back to the nearest ancestor of the working
/// directory.
Directory _repositoryRoot() {
  final packageUri = Isolate.resolvePackageUriSync(
    Uri.parse('package:dart_monty_core/dart_monty_core.dart'),
  );
  if (packageUri != null) {
    final root = File.fromUri(packageUri).parent.parent;
    if (_isRepositoryRoot(root)) {
      return root;
    }
  }
  var directory = Directory.current.absolute;
  while (true) {
    if (_isRepositoryRoot(directory)) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      fail(
        'no repository root above ${Directory.current.path}: '
        '$_pinPath not found',
      );
    }
    directory = parent;
  }
}

/// Whether [directory] is the repository root: the checkout that holds the
/// pin record.
bool _isRepositoryRoot(Directory directory) =>
    File('${directory.path}/$_pinPath').existsSync();
