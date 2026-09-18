// The native-backend half of the wire-format handshake.
//
// `test/integration/ffi_wire_format_test.dart` asserts that the REAL library
// agrees with `expectedWireFormatVersion`. It cannot assert what happens when
// they disagree, because it has no way to produce a disagreeing library — so
// until now the mismatch branch on the native backend was never executed by
// anything, and `FfiCoreBindings.init()` was `async => true`.
//
// The WASM backend has always thrown here (`wasm_bindings_js.dart`
// `_assertWireFormat`). These tests pin the same behaviour for FFI, in both
// directions, without needing a native library at all: `FfiCoreBindings` takes
// its `NativeBindings` by injection.
//
// `vm-only` because `FfiCoreBindings` imports `dart:ffi`, which cannot compile
// for the web (see tool/gate.sh:258).
@Tags(['unit', 'vm-only'])
library;

import 'package:dart_monty_core/src/ffi/ffi_core_bindings.dart';
import 'package:dart_monty_core/src/ffi/native_bindings.dart';
import 'package:test/test.dart';

/// Reports whatever version it is told to, and refuses everything else.
///
/// Deliberately NOT a permissive mock: any call `init()` makes beyond the
/// handshake fails loudly rather than returning a silent default, so this
/// stays a test of the handshake and not of an accidental code path.
class _StubBindings implements NativeBindings {
  _StubBindings(this._version);

  final int _version;

  @override
  int wireFormatVersion() => _version;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName} is not stubbed');
}

void main() {
  group('FfiCoreBindings wire-format handshake', () {
    test('init succeeds when the library reports the expected version', () {
      final bindings = FfiCoreBindings(
        bindings: _StubBindings(expectedWireFormatVersion),
      );

      expect(bindings.init(), completion(isTrue));
    });

    test('init throws when the library reports a different version', () {
      final bindings = FfiCoreBindings(
        bindings: _StubBindings(expectedWireFormatVersion + 1),
      );

      expect(bindings.init(), throwsA(isA<WireFormatMismatch>()));
    });

    test('the thrown mismatch names both versions', () async {
      final bindings = FfiCoreBindings(
        bindings: _StubBindings(expectedWireFormatVersion + 1),
      );

      // The message is the only instruction an embedder gets, so assert it
      // carries both numbers rather than just that something threw.
      await expectLater(
        bindings.init(),
        throwsA(
          isA<WireFormatMismatch>()
              .having((e) => e.expected, 'expected', expectedWireFormatVersion)
              .having((e) => e.actual, 'actual', expectedWireFormatVersion + 1),
        ),
      );
    });

    test('a zero version is a mismatch, not a pass', () {
      // Guards the never-wired-up shape: a symbol that resolves but returns 0.
      // Vacuously fine only if the constant were also 0, which it is not.
      final bindings = FfiCoreBindings(bindings: _StubBindings(0));

      expect(bindings.init(), throwsA(isA<WireFormatMismatch>()));
    });
  });
}
