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
