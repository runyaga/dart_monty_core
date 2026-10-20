part of 'self_relaunch.dart';

/// Describes whether this executable can serve a self-relaunched worker.
sealed class SelfRelaunchStatus {
  /// Creates a self-relaunch diagnosis.
  const SelfRelaunchStatus();
}

/// Reports that the worker library is present and its entry point resolves.
final class SelfRelaunchReady extends SelfRelaunchStatus {
  /// Creates a ready self-relaunch diagnosis.
  const SelfRelaunchReady();
}

/// Reports that this isolate did not arm self-relaunch before a worker was
/// located. Arming is isolate-local: `main`'s call arms only its own
/// isolate, so a pool in another isolate still finds this one unarmed.
final class SelfRelaunchNotArmed extends SelfRelaunchStatus {
  /// Creates an unarmed self-relaunch diagnosis.
  const SelfRelaunchNotArmed();
}

/// Reports that the expected bundled worker library is absent.
final class SelfRelaunchLibraryMissing extends SelfRelaunchStatus {
  /// Creates a missing-library diagnosis for [path].
  const SelfRelaunchLibraryMissing(this.path);

  /// The expected worker library path.
  final String path;
}

/// Reports that the expected worker library cannot resolve its entry point.
final class SelfRelaunchLibraryUnloadable extends SelfRelaunchStatus {
  /// Creates an unloadable-library diagnosis for [path] and [error].
  const SelfRelaunchLibraryUnloadable(this.path, this.error);

  /// The expected worker library path.
  final String path;

  /// The loader error produced while resolving the worker entry point.
  final String error;
}
