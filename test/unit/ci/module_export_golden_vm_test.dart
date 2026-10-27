// The export golden is the reviewed list of the package's public API: the
// names each public library exports, and the public members of every
// declaration a public signature reaches. `tool/check_export_boundary.dart`
// writes it and compares it against the sources; the CI job runs that checker
// with `--post-cutover`.
//
// The session's module options belong to that public API: `Monty.checkout`
// and `Monty.withSession` take them, so the golden must list the completed
// session module signatures. This test runs the checker the way CI runs it
// and requires it to be green -- a golden that still carries the pre-module
// signatures fails the check, which prints the signature mismatch -- and then
// requires the golden to carry the module options on both session entry
// points.
//
// Today the golden still carries the pre-module signatures (`OsPolicy?
// osPolicy`, and no module option), so this test fails here: the golden is
// regenerated when the module options land, not before.
//
// VM only: it runs a subprocess and reads the checkout.
@Tags(['unit', 'vm-only'])
@TestOn('vm')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// The golden the export-boundary check writes and compares against.
const _goldenPath = 'tool/export-golden.txt';

/// The checker this test runs, relative to the repository root.
const _checkerPath = 'tool/check_export_boundary.dart';

/// A member line of the golden: two spaces, the declaring type, the member.
final RegExp _memberLine = RegExp(
  r'^ {2}([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*):',
);

/// A type name in a signature.
final RegExp _typeName = RegExp(r'\b[A-Z][A-Za-z0-9_]*\b');

/// The word a module option is named after, in any spelling.
final RegExp _moduleWord = RegExp('module', caseSensitive: false);

/// The word an import option is named after, in any spelling.
final RegExp _importWord = RegExp('import', caseSensitive: false);

void main() {
  test(
    'export golden includes the completed session module signatures',
    () async {
      final root = _repositoryRoot();
      final check = await _runCheck(root);
      final diagnostics = _diagnostics(check);
      expect(
        check.exitCode,
        0,
        reason:
            'the export-boundary check must be green: the golden must '
            'match the sources, the session module options included. A '
            'mismatch here is the signature mismatch the check prints.\n'
            '$diagnostics',
      );
      _expectModuleSignatures(root, diagnostics);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Runs the export-boundary check the way the CI job runs it.
Future<ProcessResult> _runCheck(Directory root) => Process.run(
  Platform.resolvedExecutable,
  [
    '--packages=.dart_tool/package_config.json',
    _checkerPath,
    '--post-cutover',
  ],
  workingDirectory: root.path,
);

/// The check's output, kept for the failure messages.
String _diagnostics(ProcessResult check) =>
    'stdout:\n${check.stdout}\nstderr:\n${check.stderr}';

/// Requires the golden to list the session module options on both session
/// entry points.
void _expectModuleSignatures(Directory root, String diagnostics) {
  final goldenFile = File('${root.path}/$_goldenPath');
  final golden = goldenFile.existsSync() ? goldenFile.readAsStringSync() : '';
  final moduleBearing = _typesWithModuleMembers(golden);
  final checkout = _signature(golden, 'Monty.checkout');
  final withSession = _signature(golden, 'Monty.withSession');
  final without = <String>[
    if (!_carriesModuleOption(checkout, moduleBearing)) 'Monty.checkout',
    if (!_carriesModuleOption(withSession, moduleBearing)) 'Monty.withSession',
  ];
  expect(
    without,
    isEmpty,
    reason:
        'the export golden must list the session module options on '
        'Monty.checkout and Monty.withSession; these signatures carry '
        'none:\n'
        '  $checkout\n'
        '  $withSession\n'
        '$diagnostics',
  );
}

/// The signature the golden prints for [member], or an empty string when the
/// golden does not list it.
String _signature(String golden, String member) {
  for (final line in golden.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.startsWith('$member:')) return trimmed;
  }

  return '';
}

/// Whether [signature] names the session's module option: the option's own
/// name, or a type the golden declares with a module member.
bool _carriesModuleOption(String signature, Set<String> moduleBearing) {
  if (signature.isEmpty) return false;
  if (_moduleWord.hasMatch(signature)) return true;
  if (_importWord.hasMatch(signature)) return true;
  for (final match in _typeName.allMatches(signature)) {
    if (moduleBearing.contains(match.group(0))) return true;
  }

  return false;
}

/// The types the golden declares a member named after a module in.
Set<String> _typesWithModuleMembers(String golden) {
  final types = <String>{};
  for (final line in golden.split('\n')) {
    final match = _memberLine.firstMatch(line);
    if (match == null) continue;
    final type = match.group(1);
    final member = match.group(2);
    if (type == null || member == null) continue;
    if (!_moduleWord.hasMatch(member)) continue;
    types.add(type);
  }

  return types;
}

/// The repository root: the checkout that holds the checker this test runs.
/// It is found through the package's own library, which does not move with
/// the working directory, and falls back to the nearest ancestor of the
/// working directory.
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
        '$_checkerPath not found',
      );
    }
    directory = parent;
  }
}

/// Whether [directory] is the repository root: the checkout that holds the
/// export-boundary checker.
bool _isRepositoryRoot(Directory directory) =>
    File('${directory.path}/$_checkerPath').existsSync();
