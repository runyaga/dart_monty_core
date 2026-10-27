// The owner-directed value contract of ExternalModule: a module is a
// MontyValue, so MontyValue.fromDart hands it back unchanged and its
// dartValue is the module itself; the internal tagged-JSON projection has
// no representation for a module; and the ordinary arena input refuses one,
// because a module enters the sandbox through external_modules only.
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:test/test.dart';

/// Upstream's refusal of a module sent as an ordinary value (monty-proto
/// `python/encode.rs`), which the writer answers with Python's `TypeError`.
const _notAValue =
    'an ExternalModule enters the sandbox only through external_modules, '
    'not as a value';

/// The message the internal tagged-JSON projection refuses a module with.
const _noTaggedJson = 'ExternalModule has no tagged JSON representation';

/// The writer's refusal of a module sent as an ordinary value: Python's
/// `TypeError`, with upstream's text.
final Matcher _refusedAsAValue = throwsA(
  isA<PythonRefusal>()
      .having((e) => e.excType, 'excType', 'TypeError')
      .having((e) => e.text, 'text', _notAValue),
);

/// The refusal of the tagged-JSON projection of a module.
final Matcher _noTaggedJsonProjection = isA<UnsupportedError>().having(
  (e) => e.message,
  'message',
  _noTaggedJson,
);

/// The error [body] threw, or null when it threw none.
Object? _thrown(Object? Function() body) {
  try {
    body();
  } on Object catch (error) {
    return error;
  }

  return null;
}

void main() {
  test(
    'ExternalModule is a MontyValue with opaque projection '
    'and import-only input',
    () {
      final module = ExternalModule({'VERSION': 1});
      final sameModule = same(module);

      // The module is a value of its own: fromDart hands it back as it is.
      expect(module, isA<MontyValue>());
      final value = MontyValue.fromDart(module);
      expect(value, sameModule);

      // Its dartValue is the module itself, not a copy of it.
      expect(value.dartValue, sameModule);

      // The tagged-JSON projection has no representation for a module.
      expect(_thrown(value.toJson), _noTaggedJsonProjection);

      // A list holding the module projects the same way.
      final list = MontyValue.fromDart(<Object?>[module]);
      expect(list, isA<MontyList>());
      expect(_thrown(list.toJson), _noTaggedJsonProjection);
      expect(list.dartValue, contains(sameModule));

      // The ordinary arena input refuses the module, on its own and inside a
      // list: it enters the sandbox through external_modules only.
      final writer = ArenaWriter();
      expect(() => writer.add(module), _refusedAsAValue);
      expect(() => writer.add(list), _refusedAsAValue);
    },
  );
}
