// 12 — MountDir + memoryMountedOsHandler
//
// Python `pathlib.Path` operations route through an OsCallHandler. For
// the common case of "give Python access to a sandboxed filesystem,"
// memoryMountedOsHandler builds a handler from a list of MountDir
// declarations and an in-memory `Map<String, String>` backing store.
//
// The handler enforces:
//  - Path normalisation (`.`, `..`, empty segments collapsed).
//  - Sandbox boundary — `..` traversal that escapes raises
//    PermissionError.
//  - MountMode (readOnly rejects writes).
//  - Per-write writeBytesLimit (cumulative tracking is a follow-up).
//
// Compared to a hand-rolled OsCallHandler (see example 03), MountDir
// declares the policy once and lets the helper enforce it.
//
// Covers: MountDir, MountMode, memoryMountedOsHandler, fallthrough
//         handler chaining for non-Path operations.
//
// Run: dart run example/12_mount_dir.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _readWrite();
  await _readOnly();
  await _writeLimit();
  await _fallthrough();
}

// ── Basic read/write through a single mount ──────────────────────────────────
Future<void> _readWrite() async {
  print('\n── read / write ──');

  final vfs = <String, String>{
    '/data/hello.txt': 'Hello from VFS!',
  };

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    vfs: vfs,
  );

  final read = await Monty(
    'import pathlib\npathlib.Path("/data/hello.txt").read_text()',
  ).run(osHandler: handler);
  print('read:   ${read.value}');

  await Monty(
    'import pathlib\n'
    'pathlib.Path("/data/new.txt").write_text("written from Python")',
  ).run(osHandler: handler);
  print('wrote:  ${vfs["/data/new.txt"]}');
}

// ── readOnly mounts reject writes from Python ────────────────────────────────
// PermissionError surfaces to the caller via MontyResult.error.
Future<void> _readOnly() async {
  print('\n── readOnly ──');

  final handler = memoryMountedOsHandler(
    mounts: const [
      MountDir(virtualPath: '/secrets', mode: MountMode.readOnly),
    ],
    vfs: {'/secrets/api_key.txt': 'sk-12345'},
  );

  // Reads succeed.
  final ok = await Monty(
    'import pathlib\npathlib.Path("/secrets/api_key.txt").read_text()',
  ).run(osHandler: handler);
  print('read:   ${ok.value}');

  // Writes fail.
  final fail = await Monty(
    'import pathlib\n'
    'pathlib.Path("/secrets/api_key.txt").write_text("hijacked")',
  ).run(osHandler: handler);
  print('write:  error="${fail.error?.message}"');
}

// ── writeBytesLimit caps per-call write size ─────────────────────────────────
// Useful when accepting writes from Python you don't fully trust.
Future<void> _writeLimit() async {
  print('\n── writeBytesLimit ──');

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/tmp', writeBytesLimit: 16)],
    vfs: <String, String>{},
  );

  final small = await Monty(
    'import pathlib\npathlib.Path("/tmp/ok.txt").write_text("short")',
  ).run(osHandler: handler);
  print(
    'small:  error=${small.error == null ? "<none>" : small.error?.message}',
  );

  final big = await Monty(
    'import pathlib\n'
    'pathlib.Path("/tmp/big.txt").write_text("x" * 100)',
  ).run(osHandler: handler);
  print('big:    error="${big.error?.message}"');
}

// ── fallthrough — chain another handler for non-mount operations ────────────
// memoryMountedOsHandler only intercepts Path.* operations under a known
// mount. Anything else (os.getenv, datetime.now, paths outside any mount)
// is forwarded to fallthrough — typically your existing OsCallHandler.
Future<void> _fallthrough() async {
  print('\n── fallthrough ──');

  Future<Object?> envHandler(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    if (op == 'os.getenv') {
      const env = {'APP_ENV': 'production', 'DEBUG': 'false'};
      return env[args.first! as String];
    }
    return null;
  }

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    vfs: {'/data/hello.txt': 'Hello!'},
    fallthrough: envHandler,
  );

  // Routes through memoryMountedOsHandler.
  final read = await Monty(
    'import pathlib\npathlib.Path("/data/hello.txt").read_text()',
  ).run(osHandler: handler);
  print('mount:  ${read.value}');

  // Routes through fallthrough.
  final env = await Monty(
    'import os\nos.getenv("APP_ENV")',
  ).run(osHandler: handler);
  print('env:    ${env.value}');
}
