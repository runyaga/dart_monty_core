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

PROBE="$(mktemp -t vfsreg).dart"
trap 'rm -f "$PROBE"' EXIT

cat > "$PROBE" <<'DART'
import 'dart:io';
import 'package:dart_monty_core/dart_monty_core.dart';

// Upstream's create_mount_fs_tempdir (monty-datatest/src/main.rs:371-382),
// which is what the fixtures are written against.
List<VfsFile> _seed() => [
  MontyMemoryFile('/mnt/hello.txt', 'hello world\n'),
  MontyMemoryFile('/mnt/empty.txt', ''),
  MontyMemoryFile('/mnt/data.bin', '\x00\x01\x02\x03'),
  MontyMemoryFile('/mnt/readonly.txt', 'readonly content'),
  MontyMemoryFile('/mnt/subdir/nested.txt', 'nested content'),
  MontyMemoryFile('/mnt/subdir/deep/file.txt', 'deep file'),
];

const _mustStayGreen = [
  'open__fs.py',
  'with__all.py',
  'pathlib__pure.py',
  'open__fs_windows.py',
];
const _targets = ['mount_fs__ops.py', 'mount_fs__errors.py'];

const _dir =
    '/Users/runyaga/dev/monty_0_0_19/crates/monty/test_cases';

Future<String?> _run(String name) async {
  final body = File('$_dir/$name').readAsStringSync();
  final r = await Monty(
    "from pathlib import Path as _P\nroot = _P('/mnt')\n$body",
  ).run(
    osHandler: memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/mnt')],
      files: _seed(),
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
