/// dart_monty_core: Dart bindings for pydantic/monty, a sandboxed Python
/// interpreter that runs in a worker process (native) or a Web Worker (web).
///
/// ## Quick start
///
/// ```dart
/// import 'package:dart_monty_core/dart_monty_core.dart';
///
/// final value = await Monty.withPool(
///   (monty) => monty.withSession((session) async {
///     await session.feedRun('x = 42');
///     return session.feedRun('x + 1');
///   }),
/// );
/// print(value); // MontyInt(43)
/// ```
library;

// Every export line names what it exports, so a name added to a file under
// src/ stays internal until it is listed here.
export 'src/mount/memory_mounted_os_handler.dart' show memoryMountedOsHandler;
export 'src/mount/monty_memory_file.dart' show MontyMemoryFile;
export 'src/mount/mount_dir.dart' show MountDir;
export 'src/mount/mount_mode.dart' show MountMode;
export 'src/mount/open_call.dart' show resolveOpenCall;
export 'src/mount/vfs_content.dart' show VfsBytes, VfsContent, VfsText;
// `VfsAccountant` (src/mount/vfs_accountant.dart) is deliberately NOT
// exported: it is the handler's internal bookkeeping.
export 'src/mount/vfs_node.dart' show VfsFile;
export 'src/platform/monty_value.dart'
    show
        MontyBigInt,
        MontyBool,
        MontyBytes,
        MontyClassProxy,
        MontyClassTypeProxy,
        MontyComplex,
        MontyDate,
        MontyDateTime,
        MontyDict,
        MontyEllipsis,
        MontyExceptionValue,
        MontyFileHandle,
        MontyFloat,
        MontyFrozenSet,
        MontyHostFunction,
        MontyInt,
        MontyList,
        MontyNamedTuple,
        MontyNone,
        MontyNotImplemented,
        MontyPath,
        MontySet,
        MontyStdTypeProxy,
        MontyString,
        MontyTime,
        MontyTimeDelta,
        MontyTimeZone,
        MontyTuple,
        MontyValue;
export 'src/platform/os_call_not_handled_exception.dart'
    show OsCallNotHandledException;
export 'src/worker/collect_streams.dart' show CollectStreams, CollectString;
export 'src/worker/host_answers.dart' show OsHandler, coroutine;
export 'src/worker/host_objects.dart' show ClassInstance, ClassType, HostClass;
export 'src/worker/monty.dart' show Monty;
export 'src/worker/monty_error.dart'
    show
        Frame,
        MontyCrashedError,
        MontyError,
        MontyRuntimeError,
        MontySyntaxError,
        MontyTypingError;
export 'src/worker/monty_session.dart' show MontySession;
export 'src/worker/monty_snapshot.dart'
    show
        ExternalException,
        ExternalFuture,
        ExternalResult,
        ExternalReturnValue,
        ExternalSettledResult,
        FunctionSnapshot,
        FutureSnapshot,
        MontyComplete,
        MontySnapshot,
        NameLookupSnapshot,
        SourceRange;
export 'src/worker/os_policy.dart' show OsPolicy, RandomSeed, TimeZone;
export 'src/worker/resource_limits.dart' show ResourceLimits;
export 'src/worker/self_relaunch_stub.dart'
    if (dart.library.ffi) 'src/worker/self_relaunch.dart'
    show runMontyWorkerIfChild;
