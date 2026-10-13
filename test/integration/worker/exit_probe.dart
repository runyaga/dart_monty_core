// A program that crashes one fake worker, closes the channel and returns from
// main. The test that spawns it checks that it exits, which it cannot while
// any of the worker's pipes is still subscribed.
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

Future<void> main(List<String> args) async {
  final fake = args.firstOrNull ?? 'hold-stderr';
  final channel = await ProcessChannel.spawn(
    WorkerExecutable(
      Platform.resolvedExecutable,
      args: [
        File.fromUri(Platform.script.resolve('fake_worker.dart')).path,
        fake,
      ],
    ),
  );
  // Through catchError, not a catch clause: MontyCrashedError is an Error.
  await channel.turn(pb.ParentRequest(configure: pb.Configure())).catchError((
    Object error,
  ) {
    stdout.writeln(error is MontyCrashedError ? 'crashed' : '$error');

    return pb.ChildEvent();
  });
  await channel.close();
}
