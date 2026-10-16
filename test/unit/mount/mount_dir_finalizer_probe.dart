// Spawned by mount_dir_lookup_test.dart with its own VM service.
// Count directory descriptors: collection alone does not prove that the
// native finalizer released the directory capabilities.
// ignore_for_file: prefer-correct-test-file-name
import 'dart:developer';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main() async {
  final uri =
      (await Service.getInfo()).serverWebSocketUri ??
      (throw StateError('probe requires the VM service'));
  final service = await vmServiceConnectUri(uri.toString());
  final profile = service.getAllocationProfile;
  final isolate =
      Service.getIsolateId(Isolate.current) ??
      (throw StateError('probe requires an isolate ID'));
  final dir = Directory.systemTemp.createTempSync('mount-finalizer-');
  try {
    // Warm the library and the VM service before measuring descriptor counts.
    MountDir(hostPath: dir.path, virtualPath: '/warm').close();
    // A fresh GC request is needed at every measurement.
    await profile(isolate, gc: true);
    _openAndClose(dir.path);
    final before = _descriptors();
    final opened = _openAndDrop(dir.path);
    if (opened < before + 32) throw StateError('probe did not open 32 roots');
    var after = opened;
    for (var i = 0; i < 100 && after > before + 4; i++) {
      // Each iteration must trigger another collection to observe finalization.
      await profile(isolate, gc: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      after = _descriptors();
    }
    if (after > before + 4) {
      throw StateError(
        'native directory descriptors leaked: $before -> $after',
      );
    }
    stdout.writeln('finalized 32 mount roots');
  } finally {
    await service.dispose();
    dir.deleteSync();
  }
}

final int Function(int, int) _fcntl = DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'fcntl',
    );

// F_GETFD (1 on Darwin and Linux) reads flags without touching descriptor data.
int _descriptors() {
  var count = 0;
  for (var fd = 0; fd < 4096; fd++) {
    if (_fcntl(fd, 1) != -1) count++;
  }

  return count;
}

int _openAndDrop(String path) {
  final roots = List.generate(
    32,
    (_) => MountDir(
      hostPath: path,
      virtualPath: '/m',
    ),
  );
  final opened = _descriptors();
  // Keep every capability live through the measurement.
  if (roots.any((root) => root.virtualPath != '/m')) {
    throw StateError('unexpected mount path');
  }

  return opened;
}

void _openAndClose(String path) {
  final before = _descriptors();
  final roots = List.generate(
    32,
    (_) => MountDir(hostPath: path, virtualPath: '/m'),
  );
  for (final root in roots) {
    root.close();
  }
  final after = _descriptors();
  // Keep the closed objects live: this checks close, independently of GC.
  if (roots.any((root) => root.virtualPath != '/m') || after > before + 4) {
    throw StateError('explicit close leaked native directory descriptors');
  }
}
