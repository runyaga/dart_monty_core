/// Provides the self-relaunch entry point on platforms without `dart:ffi`.
library;

/// Returns immediately because browsers use Web Workers.
///
/// Cross-platform programs still call this as the first statement of `main`
/// with its arguments, matching the native entry-point contract.
void runMontyWorkerIfChild(List<String> args) {
  if (args.isEmpty) return;
}
