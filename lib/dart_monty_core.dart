/// dart_monty_core — thin Dart binding for pydantic/monty.
///
/// No plugins. No bridge. No registry.
///
/// ## Quick start
///
/// ```dart
/// import 'package:dart_monty_core/dart_monty_core.dart';
///
/// // One-shot execution
/// final platform = createPlatformMonty();
/// final result = await platform.run('1 + 1');
/// print(result.value); // MontyInt(2)
///
/// // Stateful REPL — variables, functions, imports persist across calls
/// final repl = MontyRepl();
/// await repl.feedRun('x = 42');
/// final r = await repl.feedRun('x + 1');
/// print(r.value); // MontyInt(43)
/// await repl.dispose();
/// ```
library;

// Every export line names what it exports, so a name added to a file under
// src/ stays internal until it is listed here.
export 'src/externals.dart'
    show
        MontyCallback,
        OsCallException,
        OsCallHandler,
        OsCallNotHandledException,
        osCallNoHandlerDefault;
export 'src/monty.dart' show Monty;
export 'src/monty_factory.dart' show createPlatformMonty;
export 'src/mount/memory_mounted_os_handler.dart' show memoryMountedOsHandler;
export 'src/mount/monty_memory_file.dart' show MontyMemoryFile;
export 'src/mount/mount_dir.dart' show MountDir;
export 'src/mount/mount_mode.dart' show MountMode;
export 'src/mount/open_call.dart' show resolveOpenCall;
export 'src/mount/vfs_content.dart' show VfsBytes, VfsContent, VfsText;
// `VfsAccountant` (src/mount/vfs_accountant.dart) is deliberately NOT exported: it is the handler's internal
// bookkeeping, and exposing it would make the accounting model — which nothing
// outside depends on — public API.
export 'src/mount/vfs_limits.dart'
    show defaultMemoryUsageLimit, entryMemoryUsage, formatBytesPretty;
export 'src/mount/vfs_node.dart' show VfsDir, VfsFile, VfsNode;
export 'src/platform/code_capture.dart'
    show
        assignmentPattern,
        captureLastExpression,
        extractAssignmentTargets,
        isExpression,
        statementPrefixes;
export 'src/platform/inputs_encoder.dart' show inputsToCode, toPythonLiteral;
// The backend-adapter layer is not exported: monty_core_bindings.dart,
// repl_bindings.dart and wire_json.dart. Consumers use MontyProgress /
// MontyResult instead. See a5c8b4d.
export 'src/platform/monty_error.dart'
    show
        MontyCrashError,
        MontyDisposedError,
        MontyError,
        MontyPanicError,
        MontyResourceError,
        MontyScriptError,
        MontySuspensionBudgetExceeded,
        MontySyntaxError;
export 'src/platform/monty_exception.dart' show MontyException;
export 'src/platform/monty_future_capable.dart' show MontyFutureCapable;
export 'src/platform/monty_internal_error.dart' show MontyInternalError;
export 'src/platform/monty_limits.dart' show MontyLimits;
export 'src/platform/monty_platform.dart' show MontyPlatform;
export 'src/platform/monty_progress.dart'
    show
        MontyComplete,
        MontyNameLookup,
        MontyOsCall,
        MontyPending,
        MontyProgress,
        MontyResolveFutures;
export 'src/platform/monty_resource_usage.dart' show MontyResourceUsage;
export 'src/platform/monty_result.dart' show MontyResult;
export 'src/platform/monty_stack_frame.dart' show MontyStackFrame;
export 'src/platform/monty_typing_error.dart' show MontyTypingError;
export 'src/platform/monty_value.dart'
    show
        MontyBigInt,
        MontyBool,
        MontyBytes,
        MontyClassInstance,
        MontyClassType,
        MontyDataclass,
        MontyDate,
        MontyDateTime,
        MontyDict,
        MontyEllipsis,
        MontyExceptionValue,
        MontyFileHandle,
        MontyFloat,
        MontyFrozenSet,
        MontyInt,
        MontyList,
        MontyNamedTuple,
        MontyNone,
        MontyNotImplemented,
        MontyOpaque,
        MontyOpaqueKind,
        MontyPath,
        MontySet,
        MontyString,
        MontyTime,
        MontyTimeDelta,
        MontyTimeZone,
        MontyTuple,
        MontyValue;
export 'src/platform/os_call_exception.dart'
    show OsCallException, OsCallNotHandledException, osCallNoHandlerDefault;
export 'src/repl/monty_repl.dart' show MontyRepl, ReplContinuationMode;
export 'src/repl/repl_platform.dart' show ReplPlatform;
