// 14 — open() / file I/O + typed OS exceptions (monty v0.0.18)
//
// monty v0.0.18 adds Python's `open()` builtin with buffered read/write and
// `with open(...) as f:` context managers. The host services the open-time
// effect through the same OsCallHandler used for `pathlib.Path` — here,
// memoryMountedOsHandler. The interpreter then drives reads/writes through the
// usual Path.read_text / write_text / append_text calls, so no extra wiring is
// needed beyond a mount.
//
// This release also delivers OS errors to Python as their real exception
// class, so scripts can `except FileNotFoundError:` / `except PermissionError:`
// instead of catching a generic RuntimeError.
//
// Covers: open() read/write/append, `with open(...)`, binary mode,
//         catchable typed OS exceptions, the MontyFileHandle value.
//
// Run: dart run example/14_file_io.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _readWriteAppend();
  await _withBlock();
  await _binary();
  await _typedErrors();
  await _fileHandleValue();
}

// ── open() read, write, append ───────────────────────────────────────────────
Future<void> _readWriteAppend() async {
  print('\n── open(): read / write / append ──');

  final vfs = <String, String>{'/data/poem.txt': 'roses are red\n'};
  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    vfs: vfs,
  );

  final read = await Monty('''
f = open("/data/poem.txt")
text = f.read()
f.close()
text
''').run(osHandler: handler);
  print('read:     ${(read.value.dartValue! as String).trim()}');

  // 'w' truncates then writes; a second write appends within the same handle.
  await Monty('''
f = open("/data/poem.txt", "w")
f.write("violets are blue\\n")
f.write("monty runs python\\n")
f.close()
''').run(osHandler: handler);
  print('rewrote:  ${vfs["/data/poem.txt"]!.trim().split("\n")}');

  // 'a' preserves existing content.
  await Monty('''
f = open("/data/poem.txt", "a")
f.write("and so do you\\n")
f.close()
''').run(osHandler: handler);
  print('appended: ${vfs["/data/poem.txt"]!.trim().split("\n").last}');
}

// ── with open(...) as f: — context manager closes automatically ──────────────
Future<void> _withBlock() async {
  print('\n── with open(...) as f: ──');

  final vfs = <String, String>{};
  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    vfs: vfs,
  );

  final r = await Monty('''
with open("/data/log.txt", "w") as f:
    n = f.write("first line\\n")
    inside = f.closed
out = (n, inside, f.closed)
out
''').run(osHandler: handler);

  final t = r.value.dartValue! as List<Object?>;
  print('wrote ${t[0]} chars; closed inside=${t[1]} after=${t[2]}');
  print('file:     ${vfs["/data/log.txt"]!.trim()}');
}

// ── binary mode (rb / wb) ────────────────────────────────────────────────────
// Note: memoryMountedOsHandler is text-backed (Map<String, String>), so it
// round-trips bytes that are valid UTF-8 (here, the ASCII range). For files
// with arbitrary high bytes, supply a custom OsCallHandler with a byte store.
Future<void> _binary() async {
  print('\n── binary (rb / wb) ──');

  final vfs = <String, String>{};
  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    vfs: vfs,
  );

  final r = await Monty('''
with open("/data/blob.bin", "wb") as f:
    f.write(b"\\x00\\x01\\x02PNG")
with open("/data/blob.bin", "rb") as f:
    data = f.read()
(list(data), len(data))
''').run(osHandler: handler);
  print('round-trip: ${r.value.dartValue}');
}

// ── typed OS exceptions — Python catches the real class ──────────────────────
Future<void> _typedErrors() async {
  print('\n── typed exceptions ──');

  final handler = memoryMountedOsHandler(
    mounts: const [
      MountDir(virtualPath: '/data'),
      MountDir(virtualPath: '/ro', mode: MountMode.readOnly),
    ],
    vfs: {'/ro/secret.txt': 'sk-123'},
  );

  // FileNotFoundError is now catchable in Python (was RuntimeError before).
  final missing = await Monty('''
try:
    open("/data/missing.txt")
    out = "no error"
except FileNotFoundError as e:
    out = f"caught FileNotFoundError: {e}"
out
''').run(osHandler: handler);
  print('missing:  ${missing.value.dartValue}');

  // PermissionError from a read-only mount, caught by class.
  final ro = await Monty('''
try:
    open("/ro/secret.txt", "w")
    out = "no error"
except PermissionError:
    out = "caught PermissionError"
out
''').run(osHandler: handler);
  print('readonly: ${ro.value.dartValue}');

  // Uncaught, it propagates to Dart with the typed excType.
  final uncaught = await Monty(
    'open("/data/nope.txt")',
  ).run(osHandler: handler);
  print('uncaught: excType=${uncaught.error?.excType}');
}

// ── the MontyFileHandle value ────────────────────────────────────────────────
// Returning an open file surfaces a MontyFileHandle (path, mode, position).
Future<void> _fileHandleValue() async {
  print('\n── MontyFileHandle ──');

  final handler = memoryMountedOsHandler(
    mounts: const [MountDir(virtualPath: '/data')],
    vfs: {'/data/poem.txt': 'hello'},
  );

  final r = await Monty('open("/data/poem.txt")').run(osHandler: handler);
  final v = r.value;
  if (v is MontyFileHandle) {
    print('handle:   path=${v.path} mode=${v.mode} position=${v.position}');
  } else {
    print('handle:   ${v.runtimeType} -> ${v.dartValue}');
  }
}
