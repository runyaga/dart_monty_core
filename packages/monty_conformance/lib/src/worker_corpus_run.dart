/// What a corpus run did: every fixture it ran, in order, and the reason for
/// each one that failed.
final class WorkerCorpusRun {
  /// Creates a [WorkerCorpusRun].
  const WorkerCorpusRun(this.executed, this.failures);

  /// The fixture files run, each once, in corpus order.
  final List<String> executed;

  /// Why each failing fixture failed, by file.
  final Map<String, String> failures;

  /// How many of [executed] passed.
  int get passed => executed.length - failures.length;
}
