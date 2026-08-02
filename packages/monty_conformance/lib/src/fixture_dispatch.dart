import 'package:dart_monty_core/dart_monty_core.dart';

import 'package:monty_conformance/src/fixture_externals.dart';

/// What running a `# call-external` fixture produced.
class DispatchOutcome {
  /// Creates a [DispatchOutcome].
  const DispatchOutcome({
    this.excType,
    this.value,
    this.skipped = false,
    this.skipReason,
  });

  /// The Python exception type raised, if any.
  final String? excType;

  /// The value the fixture evaluated to, when it completed.
  final MontyValue? value;

  /// True when the harness could not run the fixture at all.
  final bool skipped;

  /// Why it was skipped — shown to a reader rather than swallowed.
  final String? skipReason;
}

/// Runs a `# call-external` fixture, answering the sandbox's calls from
/// [conformanceDispatch].
///
/// **Parameterised by [platform] on purpose.** This loop was written twice —
/// once for FFI in `oracle_ffi_ext_test.dart` and once for the browser in
/// `wasm_runner.dart` — and the two drifted. Both backends implement
/// `MontyPlatform`, so there is no reason for two loops.
///
/// One real asymmetry survives and is handled here rather than hidden: FFI does
/// not implement `resumeNameLookupValue` (FB-5), so fixtures that inject a
/// named constant can only be asserted on the web. Rather than skip them
/// everywhere to match the weaker backend, this tries the injection and reports
/// a skip only when the backend refuses.
Future<DispatchOutcome> runCallExternalFixture(
  MontyPlatform platform,
  String source, {
  String? scriptName,
}) async {
  String? excType;
  MontyValue? value;

  MontyProgress? progress;
  try {
    progress = await platform.start(
      source,
      externalFunctions: conformanceExtFns.toList(),
      scriptName: scriptName,
    );
  } on MontyScriptError catch (e) {
    return DispatchOutcome(excType: e.excType);
  }

  while (progress != null) {
    switch (progress) {
      case MontyComplete(:final result):
        return DispatchOutcome(
          excType: result.error?.excType,
          value: result.value,
        );

      case MontyPending(:final functionName, :final args, :final kwargs):
        if (!conformanceExtFns.contains(functionName)) {
          return DispatchOutcome(
            skipped: true,
            skipReason: 'needs an external we do not model: $functionName',
          );
        }
        try {
          if (functionName == 'raise_error') {
            // Not a value-returning call: the fixture asks the HOST to raise
            // into the sandbox, which is a different resume verb entirely.
            progress = await platform.resumeWithException(
              (args.first as MontyString).value,
              (args[1] as MontyString).value,
            );
          } else {
            progress = await platform.resume(
              conformanceDispatch(functionName, args, kwargs),
            );
          }
        } on MontyScriptError catch (e) {
          return DispatchOutcome(excType: e.excType);
          // conformanceDispatch signals an unmodelled external this way;
          // reporting it as a skip is the point.
          // ignore: avoid_catching_errors
        } on StateError catch (e) {
          return DispatchOutcome(skipped: true, skipReason: e.message);
        }

      case MontyNameLookup(:final variableName):
        if (conformanceNameConstants.containsKey(variableName)) {
          try {
            progress = await platform.resumeNameLookup(
              variableName,
              conformanceNameConstants[variableName],
            );
            // FFI signals "not wired" with an UnimplementedError, and
            // reporting that honestly is the whole point of this branch (FB-5).
            // ignore: avoid_catching_errors
          } on UnimplementedError {
            // FFI: resumeNameLookupValue is not wired (FB-5).
            return const DispatchOutcome(
              skipped: true,
              skipReason: 'backend cannot inject a named constant (FB-5)',
            );
          } on MontyScriptError catch (e) {
            return DispatchOutcome(excType: e.excType);
          }
        } else {
          try {
            progress = await platform.resumeNameLookupUndefined(variableName);
          } on MontyScriptError catch (e) {
            return DispatchOutcome(excType: e.excType);
          }
        }

      case MontyOsCall() || MontyResolveFutures():
        return const DispatchOutcome(
          skipped: true,
          skipReason: 'needs OS calls or the futures path',
        );
    }
  }

  return DispatchOutcome(excType: excType, value: value);
}
