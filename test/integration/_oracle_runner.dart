// Oracle subprocess helper — FFI integration tests only.
//
// Resolves the oracle binary built by `cargo build --bin oracle` and pipes
// Python code to it via stdin, returning the decoded JSON result map.

import 'dart:convert';
import 'dart:io';

/// Resolves the oracle binary path.
///
/// Checks `native/target/debug/oracle` then `native/target/release/oracle`
/// relative to the package root. Throws [StateError] if neither exists.
String get oracleBinaryPath {
  final root = _packageRoot();
  final candidates = [
    '$root/native/target/debug/oracle',
    '$root/native/target/release/oracle',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError(
    'Oracle binary not found at any of $candidates.\n'
    'Build it with: cd $root/native && cargo build --bin oracle',
  );
}

/// Runs [code] through the oracle binary and returns the parsed JSON map.
Future<Map<String, Object?>> runOracle(String code) async {
  final process = await Process.start(oracleBinaryPath, []);
  process.stdin.write(code);
  await process.stdin.close();

  final stdout = await process.stdout.transform(utf8.decoder).join();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  await process.exitCode;

  if (stderr.isNotEmpty) {
    // The oracle should never write to stderr; log it for debugging.
    // ignore: avoid_print
    print('[oracle stderr] $stderr');
  }

  return json.decode(stdout) as Map<String, Object?>;
}

/// Returns the package root directory.
///
/// `dart test` sets `Directory.current` to the package root, so that is
/// checked first. Falls back to walking up from `Platform.script` for
/// direct (non-test-runner) invocations.
String _packageRoot() {
  // Primary: dart test always runs with cwd = package root.
  final cwd = Directory.current.path;
  if (Directory('$cwd/native').existsSync()) return cwd;

  // Fallback: walk up from the script path (for direct `dart run` usage).
  final script = Platform.script.toFilePath();
  final parts = script.split('/');
  for (var i = parts.length - 1; i > 0; i--) {
    final candidate = parts.sublist(0, i).join('/');
    if (Directory('$candidate/native').existsSync()) {
      return candidate;
    }
  }

  throw StateError(
    'Cannot determine package root. '
    'cwd=$cwd script=$script',
  );
}
