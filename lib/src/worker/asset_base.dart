/// Where the browser worker's script and module are served from.
///
/// Pure Dart, so the search order is tested on every backend.
///
/// Internal to the package; nothing here is exported.
library;

/// The worker assets in a Flutter web build, which serves a package's
/// declared assets under `assets/packages/<package>/<path>`.
const String flutterAssetBase = 'assets/packages/dart_monty_core/lib/assets';

/// The worker assets as `dart test` and a plain Dart web build serve them:
/// the package's lib/ under `packages/<package>/`.
const String packageAssetBase = 'packages/dart_monty_core/assets';

/// The asset bases [resolveAssetBase] tries, in order.
const List<String> assetBases = [flutterAssetBase, packageAssetBase];

/// The worker script under [base].
String workerScriptUrl(String base) => '$base/dart_monty_core_proto_worker.js';

/// The worker module under [base].
String workerWasmUrl(String base) => '$base/dart_monty_core_proto_worker.wasm';

/// The first of [assetBases] whose worker script [exists]; throws
/// [StateError] naming every URL tried when none does.
Future<String> resolveAssetBase(
  Future<bool> Function(String url) exists,
) async {
  for (final base in assetBases) {
    if (await exists(workerScriptUrl(base))) return base;
  }

  throw StateError(
    'No dart_monty_core worker assets found. Tried: '
    '${assetBases.map(workerScriptUrl).join(', ')}. Pass the asset base '
    'as workerLocation.',
  );
}
