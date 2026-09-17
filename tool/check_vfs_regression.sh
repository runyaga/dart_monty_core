#!/usr/bin/env bash
# =============================================================================
# VFS phase gate — did this change break what already worked?
# =============================================================================
# The VFS rework fixes ~24 requirements WITHOUT regressing ~900 lines of
# filesystem assertions that pass today. Those assertions are the real
# constraint, and before this script the only way to check them was to
# hand-write a probe each time.
#
#   MUST STAY GREEN   open__fs.py (649 lines), with__all.py,
#                     pathlib__pure.py, open__fs_windows.py
#   TARGETS           mount_fs__ops.py, mount_fs__errors.py
#                     (red today; green is the Phase 3 exit criterion)
#
# Fast on purpose: drives the FFI handler directly, no oracle subprocess, so it
# runs in seconds and can sit inside an edit loop. It does NOT replace
# tool/gate.sh — the gate is the commit gate and covers both web targets.
#
# Usage: bash tool/check_vfs_regression.sh
# Exit:  0 = every MUST-STAY-GREEN fixture passes
#        1 = at least one regressed  <- stop and fix before continuing
# =============================================================================
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

# `mktemp -t vfsreg` works on macOS and FAILS on Linux — GNU coreutils
# requires the template to end in at least three X's, and errors with
# "too few X's in template". Measured in the dmc-build container: the script
# died at rc 255 before running anything. The X's make it portable.
PROBE="$(mktemp -t vfsreg.XXXXXX).dart"
trap 'rm -f "$PROBE"' EXIT

cat > "$PROBE" <<'DART'
import 'dart:io';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';

// The seed is `conformanceMountFsVfs()` from package:monty_conformance, NOT a
// copy — the corpus runners answer the same fixtures from the same bytes, and
// a probe seeded differently from the thing it is guarding proves nothing.
//
// This file used to hold its own copy, which wrote `data.bin` as the Dart
// STRING '\x00\x01\x02\x03' where upstream writes the BYTES b'\x00\x01\x02\x03'.
// It agreed by luck: U+0000..U+0003 are single-byte in UTF-8. A byte above
// 0x7F in that fixture would have made the two disagree on read_bytes() and
// st_size, and only one of them would have been right.

const _mustStayGreen = [
  'open__fs.py',
  'with__all.py',
  'pathlib__pure.py',
  'open__fs_windows.py',
];
const _targets = ['mount_fs__ops.py', 'mount_fs__errors.py'];

// The upstream fixture corpus, which is NOT vendored into this repo. It is
// read from MONTY_TEST_CASES when set, so this tool is usable by someone
// whose checkout is not at the author's path — which is what the literal
// below used to hardcode. Without the override it still defaults to that
// path, so the existing setup keeps working.
final _dir = Platform.environment['MONTY_TEST_CASES'] ??
    '/Users/runyaga/dev/monty_0_0_19/crates/monty/test_cases';

Future<String?> _run(String name) async {
  // REFUSE WITH A SENTENCE, not a PathNotFoundException stack. The corpus
  // lives outside this repo, so "it is not here" is the expected failure for
  // anyone who has not fetched it, and it deserves an instruction rather than
  // a dart:io trace from frame #0.
  final f = File('$_dir/$name');
  if (!f.existsSync()) {
    stderr.writeln('FAIL: fixture corpus not found at $_dir');
    stderr.writeln('  This tool reads upstream monty test_cases, which are');
    stderr.writeln('  NOT vendored here. Point it at a checkout:');
    stderr.writeln('    MONTY_TEST_CASES=/path/to/crates/monty/test_cases \\');
    stderr.writeln('      bash tool/check_vfs_regression.sh');
    exit(2);
  }
  final body = f.readAsStringSync();
  final r = await Monty(
    "from pathlib import Path as _P\nroot = _P('/mnt')\n$body",
  ).run(
    osHandler: memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: conformanceMountFsVfs(),
    ),
  );
  if (r.error == null) return null;

  return '${r.error!.excType}: ${r.error!.message}'.trim();
}

Future<void> main() async {
  var regressed = 0;
  stdout.writeln('--- MUST STAY GREEN ---');
  for (final f in _mustStayGreen) {
    final e = await _run(f);
    if (e == null) {
      stdout.writeln('  PASS  $f');
    } else {
      stdout.writeln('  REGRESSED  $f  -> $e');
      regressed++;
    }
  }
  stdout.writeln('--- TARGETS (red until Phase 3) ---');
  for (final f in _targets) {
    final e = await _run(f);
    stdout.writeln(e == null ? '  PASS  $f  <- target met' : '  red   $f  -> $e');
  }
  if (regressed > 0) {
    stdout.writeln('\nFAIL: $regressed fixture(s) that passed before now fail.');
    exit(1);
  }
  stdout.writeln('\nPASS — no regression in the must-stay-green set.');
}
DART

cp "$PROBE" "$PKG/tool/_vfs_regression_probe.dart"
trap 'rm -f "$PROBE" "$PKG/tool/_vfs_regression_probe.dart"' EXIT
dart run "$PKG/tool/_vfs_regression_probe.dart"
