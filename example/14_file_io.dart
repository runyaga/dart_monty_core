// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 14 — open() and file I/O
//
// Python's open() builtin, with read, write and append modes, binary mode
// and `with open(...) as f:`, goes through the same OsHandler as pathlib;
// here OSAccess serves it. OS errors reach Python as their
// real exception classes, so scripts catch FileNotFoundError or
// PermissionError by name.
//
// Covers: open() read/write/append, `with open(...)`, binary mode, typed
//         OS exceptions, the MontyFileHandle value.
//
// Run: dart run example/14_file_io.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await _readWriteAppend(session);
      await _withBlock(session);
      await _binary(session);
      await _typedErrors(session);
      await _fileHandleValue(session);
    }),
  );
}

// ── open(): read, write, append ──────────────────────────────────────────────
Future<void> _readWriteAppend(MontySession session) async {
  print('\n── open(): read / write / append ──');

  final poem = MemoryFile('/data/poem.txt', 'roses are red\n');
  final os = OSAccess(files: [poem]);

  final read = await session.feedRun('''
f = open("/data/poem.txt")
text = f.read()
f.close()
text
''', os: os);
  print('read:     ${(read.dartValue?.toString() ?? 'null').trim()}');
  _check(read == const MontyString('roses are red\n'), 'read');

  // 'w' truncates, then each write appends within the same handle.
  await session.feedRun(r'''
f = open("/data/poem.txt", "w")
f.write("violets are blue\n")
f.write("monty runs python\n")
f.close()
''', os: os);
  final rewritten = poem.content as String;
  print('rewrote:  ${rewritten.trim().split("\n")}');
  _check(rewritten == 'violets are blue\nmonty runs python\n', 'w');

  // 'a' keeps the existing content.
  await session.feedRun(r'''
f = open("/data/poem.txt", "a")
f.write("and so do you\n")
f.close()
''', os: os);
  final appended = poem.content as String;
  print('appended: ${appended.trim().split("\n").lastOrNull}');
  _check(appended.endsWith('and so do you\n'), 'a');
}

// ── with open(...) as f: closes the file ─────────────────────────────────────
Future<void> _withBlock(MontySession session) async {
  print('\n── with open(...) as f: ──');

  final log = MemoryFile('/data/log.txt', '');
  final os = OSAccess(files: [log]);

  final r = await session.feedRun(r'''
with open("/data/log.txt", "w") as f:
    n = f.write("first line\n")
    inside = f.closed
(n, inside, f.closed)
''', os: os);
  final [count, inside, closed] = r.dartValue as List<Object?>;
  print('wrote $count chars; closed inside=$inside after=$closed');
  print('file:     ${(log.content as String).trim()}');
  _check(inside == false && closed == true, 'closed after the block');
}

// ── Binary mode (rb / wb) ────────────────────────────────────────────────────
// Bytes are stored as they are, so bytes that are not UTF-8 (0xFF) survive.
Future<void> _binary(MontySession session) async {
  print('\n── binary (rb / wb) ──');

  final blob = MemoryFile('/data/blob.bin', '');
  final os = OSAccess(files: [blob]);

  final r = await session.feedRun(r'''
with open("/data/blob.bin", "wb") as f:
    f.write(b"\x00\x01\xffPNG")
with open("/data/blob.bin", "rb") as f:
    data = f.read()
data
''', os: os);
  print('round trip: $r');
  print('stored:     ${blob.content}');
  _check(r == const MontyBytes([0, 1, 255, 80, 78, 71]), 'binary round trip');
}

// ── Typed OS exceptions ──────────────────────────────────────────────────────
Future<void> _typedErrors(MontySession session) async {
  print('\n── typed exceptions ──');

  final os = OSAccess(files: [MemoryFile('/ro/secret.txt', 'sk-123')]);

  final missing = await session.feedRun('''
try:
    open("/data/missing.txt")
    out = "no error"
except FileNotFoundError as e:
    out = f"caught FileNotFoundError: {e}"
out
''', os: os);
  print('missing:  ${missing.dartValue}');

  // Uncaught, it reaches Dart with its Python type.
  try {
    await session.feedRun('open("/data/nope.txt")', os: os);
    throw StateError('opening a missing file did not raise');
  } on MontyRuntimeError catch (e) {
    final type = e.exception.excType;
    print('uncaught: $type');
    _check(type == 'FileNotFoundError', 'uncaught');
  }
}

// ── The MontyFileHandle value ────────────────────────────────────────────────
// Returning an open file gives a MontyFileHandle (path, mode, position).
Future<void> _fileHandleValue(MontySession session) async {
  print('\n── MontyFileHandle ──');

  final os = OSAccess(files: [MemoryFile('/data/poem.txt', 'hello')]);

  final v = await session.feedRun('open("/data/poem.txt")', os: os);
  switch (v) {
    case MontyFileHandle(:final path, :final mode, :final position):
      print('handle:   path=$path mode=$mode position=$position');
      _check(path == '/data/poem.txt', 'handle path');
    default:
      throw StateError('expected a MontyFileHandle, got $v');
  }
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
