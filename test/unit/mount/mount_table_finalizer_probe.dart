// Isolate shutdown invokes native finalizers without a VM-service GC hook.
// The enclosing test launches this probe alone so fds cannot be reused by
// unrelated suites. No session or table close is allowed in the abandon path.
// ignore_for_file: prefer-correct-test-file-name
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';

Future<void> main() async {
  final directory = Directory.systemTemp.createTempSync(
    'mount-table-finalizer-',
  );
  final path = directory.path;
  try {
    MountDir(hostPath: path, virtualPath: '/warm').close();
    await Isolate.run(() => _suspend(path, closeSession: true));
    final before = _descriptors();
    for (var i = 0; i < 8; i++) {
      await Isolate.run(() => _suspend(path, closeSession: false));
    }
    // The isolate-exit notification can arrive before native finalization.
    var after = _descriptors();
    for (var i = 0; i < 100 && after > before; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      after = _descriptors();
    }
    if (after > before) {
      throw StateError(
        'abandoned feed tables leaked descriptors: $before -> $after',
      );
    }
    stdout.writeln('finalized 8 abandoned feed tables');
  } finally {
    directory.deleteSync();
  }
}

Future<void> _suspend(String path, {required bool closeSession}) async {
  final before = _descriptors();
  final mount = MountDir(hostPath: path, virtualPath: '/d');
  final session = FakeMontySession()
    ..willLookUp('waiting')
    ..willReturn(const MontyNone());
  final snapshot = await session.feedStart('waiting', mount: [mount]);
  mount.close();
  if (snapshot is! NameLookupSnapshot || _descriptors() <= before) {
    throw StateError(
      'probe must retain an opened capability in a suspended feed',
    );
  }
  if (closeSession) await session.close();
}

final int Function(int, int) _fcntl = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'fcntl',
    );

int _descriptors() {
  var count = 0;
  for (var fd = 0; fd < 4096; fd++) {
    if (_fcntl(fd, 1) != -1) count++;
  }

  return count;
}
