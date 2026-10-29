/// Provides the manifest bundled with this package.
library;

import 'package:dart_monty_core/src/worker/worker_manifest.dart';

/// The manifest of the worker release assets this package version installs.
///
/// An empty `targets` map means no prebuilt worker is published.
///
/// It is empty here: the pinned upstream (see tool/upstream/upstream-pin.json)
/// moved on, and the published worker release this manifest's version names
/// was built against the PREVIOUS pin. Advertising it would install a worker
/// that answers the old upstream's behaviour, so the build hook installs
/// none and the locator falls through to the worker built from
/// `native/worker` (tool/build_worker.sh), which carries the pinned upstream.
const workerManifestJson = '{"schema":1,"version":"v0.120.0","targets":{}}';

/// The parsed manifest bundled with this package.
final bundledWorkerManifest = WorkerManifest.fromJson(workerManifestJson);

/// Default GitHub release mirror template for worker archives.
///
/// `{tag}` comes from [WorkerManifest.version], `{target}` names the host,
/// and `{archive}` names the archive file. A configured mirror overrides this
/// default.
const defaultWorkerMirrorTemplate =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';
