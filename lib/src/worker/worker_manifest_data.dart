/// Provides the manifest bundled with this package.
library;

// This direct import keeps the hook-visible dependency graph self-contained.
// ignore: always_use_package_imports
import 'worker_manifest.dart';

/// Bundled manifest JSON for releases that publish no worker yet.
///
/// Release automation supplies published artifacts. This empty manifest means
/// no prebuilt worker is published yet.
const workerManifestJson = '{"schema":1,"targets":{}}';

/// The parsed manifest bundled with this package.
final bundledWorkerManifest = WorkerManifest.fromJson(workerManifestJson);

/// Default GitHub release mirror template for worker archives.
///
/// `{tag}` comes from [WorkerManifest.version], `{target}` names the host,
/// and `{archive}` names the archive file. A configured mirror overrides this
/// default.
const defaultWorkerMirrorTemplate =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';
