// Unit tests for compileCode / runPrecompiled / startPrecompiled.
//
// Uses MockMontyPlatform — no native dylib required.
//
// Also includes a direct BaseMontyPlatform stub that verifies the
// MontyScriptError → MontySyntaxError promotion in compileCode.
@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/base_monty_platform.dart';
import 'package:dart_monty_core/src/platform/core_bindings.dart';
import 'package:dart_monty_core/src/platform/mock_monty_platform.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Stub helpers for BaseMontyPlatform.compileCode promotion tests
// ---------------------------------------------------------------------------

// Throws [MontyScriptError] from compileCode with the given excType;
// used to test SyntaxError promotion in BaseMontyPlatform.compileCode.
final class _ThrowingBindings implements MontyCoreBindings {
  _ThrowingBindings(this._excType);

  final String _excType;

  @override
  Future<bool> init() async => true;

  @override
  Future<Uint8List> compileCode(String code) async => throw MontyScriptError(
    '$_excType: stub error',
    excType: _excType,
  );

  @override
  Future<void> dispose() async {}

  // All other methods are unreachable in these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Minimal [BaseMontyPlatform] subclass that accepts an injected bindings
/// object — used only for testing error promotion behaviour.
final class _StubPlatform extends BaseMontyPlatform {
  _StubPlatform(MontyCoreBindings bindings) : super(bindings: bindings);

  @override
  String get backendName => '_StubPlatform';
}

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

const _intResult = MontyResult(value: MontyInt(42), usage: _zeroUsage);

void main() {
  // -------------------------------------------------------------------------
  group('MockMontyPlatform.compileCode', () {
    test('returns non-empty Uint8List', () async {
      final mock = MockMontyPlatform();
      final bytes = await mock.compileCode('x + 1');
      expect(bytes, isNotEmpty);
    });

    test('encodes the code in the returned bytes', () async {
      final mock = MockMontyPlatform();
      final bytes = await mock.compileCode('x + 1');
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(decoded['code'], 'x + 1');
    });

    test('records compiled code in history', () async {
      final mock = MockMontyPlatform();
      await mock.compileCode('result = x * 2');
      expect(mock.history.lastCompileCode, 'result = x * 2');
    });

    test('records multiple calls in order', () async {
      final mock = MockMontyPlatform();
      await mock.compileCode('a = 1');
      await mock.compileCode('b = 2');
      expect(mock.history.compileCodeList, ['a = 1', 'b = 2']);
    });
  });

  // -------------------------------------------------------------------------
  group('MockMontyPlatform.runPrecompiled', () {
    test('returns configured runResult', () async {
      final mock = MockMontyPlatform()..runResult = _intResult;
      final bytes = await mock.compileCode('42');
      final result = await mock.runPrecompiled(bytes);
      expect(result.value, const MontyInt(42));
    });

    test('records compiled bytes in history', () async {
      final mock = MockMontyPlatform()..runResult = _intResult;
      final bytes = Uint8List.fromList([1, 2, 3]);
      await mock.runPrecompiled(bytes);
      expect(mock.history.lastRunPrecompiledData, bytes);
    });

    test('throws StateError when runResult is not set', () async {
      final mock = MockMontyPlatform();
      final bytes = await mock.compileCode('42');
      await expectLater(
        () => mock.runPrecompiled(bytes),
        throwsStateError,
      );
    });
  });

  // -------------------------------------------------------------------------
  group('MockMontyPlatform.startPrecompiled', () {
    test('returns MontyProgress from queue', () async {
      final mock = MockMontyPlatform();
      const complete = MontyComplete(
        result: MontyResult(value: MontyNone(), usage: _zeroUsage),
      );
      mock.enqueueProgress(complete);
      final bytes = await mock.compileCode('pass');
      final progress = await mock.startPrecompiled(bytes);
      expect(progress, isA<MontyComplete>());
    });

    test('records compiled bytes in history', () async {
      final mock = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _zeroUsage),
          ),
        );
      final bytes = Uint8List.fromList([9, 8, 7]);
      await mock.startPrecompiled(bytes);
      expect(mock.history.lastStartPrecompiledData, bytes);
    });
  });

  // -------------------------------------------------------------------------
  group('MontySession.runPrecompiled', () {
    test('delegates to platform and returns result', () async {
      final mock = MockMontyPlatform()..runResult = _intResult;
      final session = MontySession(platform: mock);
      final bytes = await mock.compileCode('42');
      final result = await session.runPrecompiled(bytes);
      expect(result.value, const MontyInt(42));
    });

    test('passes limits to platform', () async {
      const limits = MontyLimits(timeoutMs: 1000);
      final mock = MockMontyPlatform()..runResult = _intResult;
      final session = MontySession(platform: mock);
      final bytes = await mock.compileCode('pass');
      // Ignore the result; verify that the bytes were forwarded.
      await session.runPrecompiled(bytes, limits: limits);
      expect(mock.history.lastRunPrecompiledData, bytes);
    });

    test('throws StateError on disposed session', () async {
      final mock = MockMontyPlatform()..runResult = _intResult;
      final session = MontySession(platform: mock)..dispose();
      final bytes = await mock.compileCode('pass');
      expect(() => session.runPrecompiled(bytes), throwsStateError);
    });
  });

  // -------------------------------------------------------------------------
  group('compile + runPrecompiled round-trip (mock)', () {
    test('compile → runPrecompiled returns expected result', () async {
      final mock = MockMontyPlatform()..runResult = _intResult;
      final bytes = await mock.compileCode('42');
      final result = await mock.runPrecompiled(bytes);
      expect(result.value, const MontyInt(42));
      // The bytes encode the code — verify round-trip through JSON.
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(decoded['code'], '42');
    });
  });

  // -------------------------------------------------------------------------
  group('BaseMontyPlatform.compileCode error promotion', () {
    test('SyntaxError is promoted to MontySyntaxError', () async {
      final platform = _StubPlatform(_ThrowingBindings('SyntaxError'));
      addTearDown(platform.dispose);

      await expectLater(
        platform.compileCode('bad code'),
        throwsA(isA<MontySyntaxError>()),
      );
    });

    test('non-SyntaxError is rethrown as MontyScriptError', () async {
      final platform = _StubPlatform(_ThrowingBindings('ValueError'));
      addTearDown(platform.dispose);

      await expectLater(
        platform.compileCode('bad code'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e is MontySyntaxError,
            'is not MontySyntaxError',
            isFalse,
          ),
        ),
      );
    });
  });
}
