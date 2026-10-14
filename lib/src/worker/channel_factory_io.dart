/// The native channel factory: a worker process per channel.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';

/// Starts a worker process: the executable at [workerLocation], or the one
/// `locateWorker` finds.
///
/// A process cannot be stopped while it is being started; cancelling then
/// kills it as soon as it exists.
SpawnHandle openChannel({String? workerLocation}) => PendingSpawn((_) async {
  final launch = await locateWorker(
    explicit: workerLocation == null ? null : WorkerExecutable(workerLocation),
  );

  return ProcessChannel.spawn(launch);
});

/// [channel]'s process id: a worker process's, else (a channel some test
/// or harness made) null.
int? channelPid(MontyChannel channel) =>
    channel is ProcessChannel ? channel.pid : null;

/// The processor count, as upstream's `available_parallelism`.
int defaultMaxProcesses() => Platform.numberOfProcessors;
