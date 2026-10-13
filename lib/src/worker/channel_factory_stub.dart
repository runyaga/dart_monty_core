/// The channel factory where no worker channel exists.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:dart_monty_core/src/worker/spawn_handle.dart';

/// Always throws [UnsupportedError]: this platform has no worker channel,
/// wherever [workerLocation] points.
SpawnHandle openChannel({String? workerLocation}) => throw UnsupportedError(
  'no monty worker channel on this platform '
  '(workerLocation: ${workerLocation ?? 'none'})',
);

/// One.
int defaultMaxProcesses() => 1;
