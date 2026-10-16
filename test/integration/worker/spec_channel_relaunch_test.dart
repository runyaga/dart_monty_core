// This suite also acts as a child entry point. Loading the already-built
// cdylib makes its real @Native entry point available without a Cargo build.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_connection.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';
import 'package:test/test.dart';

const _path = 'test/integration/worker/spec_channel_relaunch_test.dart';

void main([List<String> args = const []]) {
  if (args.isNotEmpty) {
    _child(args.single);

    return;
  }
  for (final req in [
    'REQ-runMontyWorkerIfChild-10',
    'REQ-runMontyWorkerIfChild-11',
    'REQ-runMontyWorkerIfChild-18',
  ]) {
    for (final shutdown in [false, true]) {
      test('$req: bundled entry point serves until '
          '${shutdown ? 'Shutdown' : 'EOF'}', () async {
        final process = await _start('bundled');
        final bytes = process.stdout.fold(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );
        final errors = process.stderr.fold(
          <int>[],
          (all, chunk) => all..addAll(chunk),
        );
        process.stdin.add(Frame.encode(_configure()));
        if (shutdown) {
          process.stdin.add(
            Frame.encode(pb.ParentRequest(shutdown: pb.Shutdown())),
          );
        }
        await process.stdin.close();
        expect(await process.exitCode, 0);
        expect(await errors, isEmpty);
        final decoder = FrameDecoder();
        final events = decoder
            .add(await bytes)
            .map(pb.ChildEvent.fromBuffer)
            .toList();
        decoder.close();
        expect(events.map((event) => event.whichKind()), [
          pb.ChildEvent_Kind.ok,
          if (shutdown) pb.ChildEvent_Kind.ok,
        ]);
      });
    }
  }
  test(
    'REQ-runMontyWorkerIfChild-19: native return 4 is process exit 4',
    () async {
      final process = await _start('bundled');
      final bytes = process.stdout.fold(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      final errors = process.stderr.fold(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      final configure = _configure()..configure.protocolVersion = 999;
      process.stdin.add(Frame.encode(configure));
      await process.stdin.close();
      expect(await process.exitCode, 4);
      expect(await errors, isEmpty);
      final decoder = FrameDecoder();
      final events = decoder
          .add(await bytes)
          .map(pb.ChildEvent.fromBuffer)
          .toList();
      decoder.close();
      expect(events.map((event) => event.whichKind()), [
        pb.ChildEvent_Kind.fatalError,
      ]);
      expect(events.singleOrNull?.fatalError.message, contains('999'));
    },
  );
  test(
    'REQ-runMontyWorkerIfChild-20: unresolved entry point propagates '
    'ArgumentError',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        _path,
        'missing',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'ArgumentError\n');
    },
  );
}

pb.ParentRequest _configure() => pb.ParentRequest(
  configure: pb.Configure(
    protocolVersion: workerProtocolVersion,
    scriptName: 'spec.py',
  ),
);

Future<Process> _start(String mode) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    _path,
    mode,
  ]);
  addTearDown(() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  });

  return process;
}

void _child(String mode) {
  if (mode == 'bundled') {
    _serveBundled();
  } else {
    try {
      runMontyWorkerIfChild(const [SelfRelaunch.flag]);
    } on Object catch (error) {
      stdout.writeln(error is ArgumentError ? 'ArgumentError' : '$error');

      return;
    }
  }
  stdout.writeln('application resumed');
  exit(99);
}

void _serveBundled() {
  runMontyWorkerIfChild(_loadBundled());
  stdout.writeln('application resumed');
  exit(99);
}

List<String> _loadBundled() {
  final uri = Uri.parse(
    'package:dart_monty_core/${workerPackagePath(Abi.current())}',
  );
  final executable = Isolate.resolvePackageUriSync(uri);
  if (executable == null) throw StateError('package did not resolve');
  final name = switch (Platform.operatingSystem) {
    'windows' => 'dart_monty_worker.dll',
    'macos' => 'libdart_monty_worker.dylib',
    _ => 'libdart_monty_worker.so',
  };
  DynamicLibrary.open(executable.resolve(name).toFilePath());

  return const [SelfRelaunch.flag];
}
