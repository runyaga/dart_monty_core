/// `runMontyWorkerIfChild` where there is no `dart:ffi`: the same call as
/// native's, under the same contract — call it as the first statement of
/// `main`, with `main`'s arguments — where a browser never relaunches
/// itself as a worker, so the call always returns at once.
library;

/// Returns at once: on the web the worker is a Web Worker, never a
/// relaunch of this program, so [args] never name the relaunch flag. The
/// contract is native's — call it as the first statement of `main`, with
/// `main`'s arguments — and the same program then runs on both.
void runMontyWorkerIfChild(List<String> args) {
  if (args.isEmpty) return;
}
