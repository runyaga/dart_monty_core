// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 12 — MountDir + memoryMountedOsHandler
//
// For the common case of "give Python a sandboxed filesystem",
// memoryMountedOsHandler builds an OsHandler from MountDir declarations and
// in-memory files (MontyMemoryFile). Writes update those file objects, so
// Dart reads the results directly.
//
// The handler enforces:
//  - Path normalisation (`.`, `..`, empty segments collapsed).
//  - The sandbox boundary: a path that resolves outside every mount is
//    absent (FileNotFoundError), `..` tricks included.
//  - MountMode: a readOnly mount rejects writes.
//  - writeBytesLimit (total bytes written through the mount) and
//    memoryUsageLimit (bytes currently held; 100 MB by default).
//
// Covers: MountDir, MountMode, MontyMemoryFile, memoryMountedOsHandler,
//         a fallthrough handler for calls outside the mounts.
//
// Run: dart run example/12_mount_dir.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await session.feedRun('import pathlib, os');
      await _readWrite(session);
      await _readOnly(session);
      await _writeLimit(session);
      await _fallthrough(session);
    }),
  );
}

// ── Read and write through a mount ───────────────────────────────────────────
Future<void> _readWrite(MontySession session) async {
  print('\n── read / write ──');

  final newFile = MontyMemoryFile('/data/new.txt', '');
  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    files: [MontyMemoryFile('/data/hello.txt', 'Hello from VFS!'), newFile],
  );

  final read = await session.feedRun(
    'pathlib.Path("/data/hello.txt").read_text()',
    os: handler,
  );
  print('read:   $read');
  _check(read == const MontyString('Hello from VFS!'), 'read');

  await session.feedRun(
    'pathlib.Path("/data/new.txt").write_text("written from Python")',
    os: handler,
  );
  print('wrote:  ${newFile.content.text}');
  _check(newFile.content.text == 'written from Python', 'write');

  final escape = await _error(
    session,
    'pathlib.Path("/data/../etc/passwd").read_text()',
    handler,
  );
  print('escape: $escape');
  _check(escape.exception.excType == 'FileNotFoundError', 'boundary');
}

// ── A readOnly mount rejects writes ──────────────────────────────────────────
Future<void> _readOnly(MontySession session) async {
  print('\n── readOnly ──');

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/secrets', mode: MountMode.readOnly)],
    files: [MontyMemoryFile('/secrets/api_key.txt', 'sk-12345')],
  );

  final ok = await session.feedRun(
    'pathlib.Path("/secrets/api_key.txt").read_text()',
    os: handler,
  );
  print('read:   $ok');

  final error = await _error(
    session,
    'pathlib.Path("/secrets/api_key.txt").write_text("hijacked")',
    handler,
  );
  print('write:  $error');
  _check(error.exception.excType == 'PermissionError', 'readOnly');
}

// ── writeBytesLimit caps the total written through the mount ─────────────────
// Deleting a file does not give that budget back; memoryUsageLimit, which
// bounds what is held, does.
Future<void> _writeLimit(MontySession session) async {
  print('\n── writeBytesLimit ──');

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/tmp', writeBytesLimit: 16)],
    files: const [],
  );

  await session.feedRun(
    'pathlib.Path("/tmp/ok.txt").write_text("short")',
    os: handler,
  );
  print('small:  ok');

  final error = await _error(
    session,
    'pathlib.Path("/tmp/big.txt").write_text("x" * 100)',
    handler,
  );
  print('big:    $error');
  _check(error.exception.excType == 'OSError', 'write limit');
}

// ── fallthrough: another handler for everything else ─────────────────────────
// The mount handler answers filesystem calls under its mounts. Anything else
// (os.getenv, datetime calls, paths outside every mount) goes to fallthrough.
Future<void> _fallthrough(MontySession session) async {
  print('\n── fallthrough ──');

  MontyValue env(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> _,
  ) {
    if (name == 'os.getenv') {
      const vars = {'APP_ENV': 'production', 'DEBUG': 'false'};
      final value = vars[(args.first as MontyString).value];

      return value == null ? const MontyNone() : MontyString(value);
    }
    throw const OsCallNotHandledException();
  }

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    files: [MontyMemoryFile('/data/hello.txt', 'Hello!')],
    fallthrough: env,
  );

  final read = await session.feedRun(
    'pathlib.Path("/data/hello.txt").read_text()',
    os: handler,
  );
  print('mount:  $read');

  final appEnv = await session.feedRun('os.getenv("APP_ENV")', os: handler);
  print('env:    $appEnv');
  _check(appEnv == const MontyString('production'), 'fallthrough');
}

Future<MontyRuntimeError> _error(
  MontySession session,
  String code,
  OsHandler handler,
) async {
  try {
    await session.feedRun(code, os: handler);
  } on MontyRuntimeError catch (e) {
    return e;
  }
  throw StateError('no error from: $code');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
