// Upstream's corpus harness answers a `__call__` on a host object with a
// TypeError naming the class: `crates/monty-datatest/src/main.rs:674-676`
// matches `(_, "__call__")` and raises
// `format!("'{class_name}' object is not callable")`, because the host
// decides callability and none of its fixtures is callable.
//
// The corpus pins that text: `dataclass__basic.py:390` calls the
// MutablePoint fixture and asserts
// "'MutablePoint' object is not callable".

@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
// The fixture host is imported from the package's `src` on purpose: the
// public barrel (`worker_conformance.dart`) also exports the generated corpus
// (`src/fixture_corpus_v1.dart`), which is produced from the pinned upstream
// checkout and is not part of the tree. This test needs the host alone.
import 'package:monty_conformance/src/worker_fixture_host.dart';
import 'package:test/test.dart';

void main() {
  test(
    'the fixture host answers __call__ on a fixture instance with TypeError '
    'not callable',
    () {
      final registry = WorkerFixtureRegistry();

      final outcome = registry.call('make_mutable_point', const [], const {});
      expect(outcome, isA<HostReturn>());

      final instance = switch (outcome) {
        HostReturn(:final value) => value,
        _ => throw StateError('make_mutable_point must answer a value'),
      };
      expect(instance, isA<ClassInstance<Object>>());

      final instanceId = switch (instance) {
        ClassInstance<Object>(:final id) => id,
        _ => throw StateError('the fixture must be a host instance'),
      };

      final result = registry.method(
        '__call__',
        instanceId,
        const [],
        const {},
      );

      expect(result, isA<HostRaise>());
      final raised = switch (result) {
        HostRaise(:final excType, :final message) => (excType, message),
        _ => throw StateError('the host must raise'),
      };
      expect(raised.$1, 'TypeError');
      expect(raised.$2, "'MutablePoint' object is not callable");
    },
  );
}
