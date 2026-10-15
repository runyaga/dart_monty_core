/// `runMontyWorkerIfChild` where there is no `dart:ffi`: a browser never
/// relaunches itself as a worker, so the call returns at once.
library;

/// Returns at once: on the web the worker is a Web Worker, never a
/// relaunch of this program, so [args] never name the worker's flag.
void runMontyWorkerIfChild(List<String> args) {
  if (args.isEmpty) return;
}
