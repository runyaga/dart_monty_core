import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_install.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:dart_monty_core/src/worker/worker_manifest_data.dart';
import 'package:hooks/hooks.dart';
import 'package:meta/meta.dart';

Future<void> main(List<String> args) async {
  await runBuild(args);
}

/// Runs the hook with injectable release data for VM-level hook tests.
@visibleForTesting
Future<void> runBuild(
  List<String> args, {
  WorkerManifest? manifest,
  Map<String, String>? environment,
}) async {
  final workerManifest = manifest ?? bundledWorkerManifest;
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final prebuiltLibrary = await _installPrebuilt(
      input,
      output,
      manifest: workerManifest,
      environment: environment,
    );
    // The worker cdylib, for `dart build cli` self-relaunch. Built ONLY when
    // the root package opts in; every other consumer gets no native code from
    // this hook and runs the worker executable at `workerLocation`.
    final code = input.config.code;
    final os = code.targetOS;
    final arch = code.targetArchitecture;
    // Graceful fallback for iOS/Android: no native assets.
    if (os != OS.macOS && os != OS.linux && os != OS.windows) return;
    if (!_wantsWorker(input)) return;
    if (prebuiltLibrary) return;

    final nativeDir = input.packageRoot.resolve('native/');
    final triple = _rustTriple(os, arch);
    final targetArgs = triple != null ? ['--target', triple] : <String>[];
    if (triple != null) {
      await _ensureRustTarget(
        triple,
        Directory.fromUri(nativeDir.resolve('worker/')).path,
      );
    }
    await _buildWorker(input, output, nativeDir, os, arch, targetArgs);
  });
}

/// Installs published host artifacts and adds a copied prebuilt library.
///
///
/// Returns true when a prebuilt library replaces the contributor cargo build.
Future<bool> _installPrebuilt(
  BuildInput input,
  BuildOutputBuilder output, {
  required WorkerManifest manifest,
  Map<String, String>? environment,
}) async {
  final targetData = _prebuiltTarget(input, manifest);
  if (targetData == null) return false;
  _declareManifestDependency(input, output);
  var root = '<unavailable>';
  var workerUrl = Uri.parse('<unavailable>');
  try {
    final override = _workerMirror(input);
    root = workerCacheRoot(environment: environment);
    final manifestTarget = targetData.manifestTarget;
    workerUrl = workerArchiveUrl(
      manifest: manifest,
      target: targetData.target,
      artifact: manifestTarget.worker,
      mirrorOverride: override,
    );
    final worker = await _installArtifact(
      manifestTarget.worker,
      root,
      workerUrl,
    );
    _logInstall(worker);

    return await _installLibraryIfWanted(
      input,
      output,
      targetData,
      root,
      override,
      manifest,
    );
  } on Object catch (error) {
    throw StateError(
      'dart_monty_core: prebuilt worker install for ${targetData.target} '
      'from $workerUrl '
      'into $root failed: $error. Check the release asset, grant write access '
      'or set HOME, or configure worker_mirror.',
    );
  }
}

void _declareManifestDependency(BuildInput input, BuildOutputBuilder output) {
  output.dependencies.add(
    input.packageRoot.resolve('lib/src/worker/worker_manifest_data.dart'),
  );
}

Future<bool> _installLibraryIfWanted(
  BuildInput input,
  BuildOutputBuilder output,
  ({String target, Architecture arch, WorkerTarget manifestTarget}) targetData,
  String cacheRoot,
  String? mirrorOverride,
  WorkerManifest manifest,
) async {
  final library = targetData.manifestTarget.library;
  if (!_wantsWorker(input) || library == null) return false;
  await _installPrebuiltLibrary(
    input,
    output,
    installation: (
      target: targetData.target,
      arch: targetData.arch,
      cacheRoot: cacheRoot,
      mirrorOverride: mirrorOverride,
    ),
    library: library,
    manifest: manifest,
  );

  return true;
}

({String target, Architecture arch, WorkerTarget manifestTarget})?
_prebuiltTarget(BuildInput input, WorkerManifest manifest) {
  final code = input.config.code;
  final os = code.targetOS;
  if (os != OS.macOS && os != OS.linux && os != OS.windows) return null;
  final arch = code.targetArchitecture;
  final target = hookWorkerHostKey(os.toString(), arch.toString());
  final manifestTarget = manifest.targetFor(target);
  if (manifestTarget == null) return null;

  return (target: target, arch: arch, manifestTarget: manifestTarget);
}

Future<WorkerInstall> _installArtifact(
  WorkerArtifact artifact,
  String cacheRoot,
  Uri archiveUrl,
) => installWorker(
  WorkerInstallRequest(
    artifact: artifact,
    cacheRoot: cacheRoot,
    archiveUrl: archiveUrl,
  ),
);

Future<void> _installPrebuiltLibrary(
  BuildInput input,
  BuildOutputBuilder output, {
  required ({
    String target,
    Architecture arch,
    String cacheRoot,
    String? mirrorOverride,
  })
  installation,
  required WorkerArtifact library,
  required WorkerManifest manifest,
}) async {
  final libraryUrl = workerArchiveUrl(
    manifest: manifest,
    target: installation.target,
    artifact: library,
    mirrorOverride: installation.mirrorOverride,
  );
  final installedLibrary = await _installArtifact(
    library,
    installation.cacheRoot,
    libraryUrl,
  );
  _logInstall(installedLibrary);
  final outputFile = File.fromUri(
    input.outputDirectoryShared.resolve('${installation.arch}/${library.file}'),
  );
  await copyVerifiedLibrary(
    source: File(installedLibrary.path),
    destination: outputFile,
    artifact: library,
  );
  await verifyWorkerFile(outputFile, library);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/worker/self_relaunch.dart',
      linkMode: DynamicLoadingBundled(),
      file: outputFile.uri,
    ),
  );
}

/// Reads the optional release-mirror override from the hook configuration.
String? _workerMirror(BuildInput input) {
  final value = input.userDefines['worker_mirror'];
  if (value == null) return null;
  if (value is String) return value;
  throw StateError(
    'dart_monty_core: the user_define worker_mirror must be a string, got '
    '${value.runtimeType} $value.',
  );
}

/// Logs one concise result for one worker cache installation.
void _logInstall(WorkerInstall install) {
  final outcome = install.alreadyInstalled ? 'already installed' : 'installed';
  stderr.writeln('dart_monty_core: worker $outcome at ${install.path}');
}

/// The root package's opt-in to the worker cdylib, from its pubspec:
///
/// ```yaml
/// hooks:
///   user_defines:
///     dart_monty_core:
///       build_worker: true
/// ```
///
/// Absent or `false` means no worker library. Any other value is a mistake
/// in that pubspec, reported rather than read as either answer.
bool _wantsWorker(BuildInput input) {
  final value = input.userDefines['build_worker'];
  if (value == null || value == false) return false;
  if (value == true) return true;
  throw StateError(
    'dart_monty_core: the user_define build_worker must be true or false, '
    'got ${value.runtimeType} $value.',
  );
}

/// Builds native/worker's cdylib and adds it as the code asset that
/// `lib/src/worker/self_relaunch.dart` binds `dart_monty_worker_main` from.
Future<void> _buildWorker(
  BuildInput input,
  BuildOutputBuilder output,
  Uri nativeDir,
  OS os,
  Architecture arch,
  List<String> targetArgs,
) async {
  final libName = switch (os) {
    OS.macOS => 'libdart_monty_worker.dylib',
    OS.windows => 'dart_monty_worker.dll',
    _ => 'libdart_monty_worker.so',
  };
  final workerDir = nativeDir.resolve('worker/');
  await _cargoBuildLib(workerDir, targetArgs);
  final built = _firstBuilt(workerDir, _cargoPaths(os, arch, libName));
  if (built == null) {
    throw StateError(
      'cargo build succeeded but $libName not found in target directories.',
    );
  }
  final outFile = File.fromUri(
    input.outputDirectoryShared.resolve('$arch/$libName'),
  );
  outFile.parent.createSync(recursive: true);
  _publishAtomically(built, outFile);
  _addWorkerAsset(input, output, outFile);
  _declareWorkerInputs(
    output,
    workerDir,
    toolchain: nativeDir.resolve('rust-toolchain.toml'),
  );
}

void _addWorkerAsset(
  BuildInput input,
  BuildOutputBuilder output,
  File outFile,
) {
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/worker/self_relaunch.dart',
      linkMode: DynamicLoadingBundled(),
      file: outFile.uri,
    ),
  );
}

/// Runs `cargo build --lib` in [workerDir]. `--lib` builds the cdylib (and the
/// rlib the executable links), with the release profile the executable ships
/// with. `--locked`: native/worker/Cargo.lock is seeded from upstream's and a
/// fresh resolve is known to fail.
Future<void> _cargoBuildLib(Uri workerDir, List<String> targetArgs) async {
  if (!File.fromUri(workerDir.resolve('Cargo.toml')).existsSync()) {
    throw StateError(
      'native/worker/Cargo.toml not found — the worker library '
      '(build_worker: true) builds from source in the full repository.',
    );
  }
  final result = await Process.run('cargo', [
    'build',
    '--locked',
    '--release',
    '--lib',
    ...targetArgs,
  ], workingDirectory: Directory.fromUri(workerDir).path);
  if (result.exitCode != 0) {
    throw StateError(
      'cargo build of the worker library failed.\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
}

/// What the worker library is built from: native/worker's manifest, lock and
/// build script, the Cargo configuration it inherits, every Rust source under
/// `src/` and `upstream/`, and [toolchain], native/rust-toolchain.toml.
void _declareWorkerInputs(
  BuildOutputBuilder output,
  Uri workerDir, {
  required Uri toolchain,
}) {
  final deps = [
    workerDir.resolve('Cargo.toml'),
    workerDir.resolve('Cargo.lock'),
    workerDir.resolve('build.rs'),
    toolchain,
  ];
  // Cargo reads `.cargo/config.toml` (or the older `.cargo/config`) from
  // native/worker/ and every directory above it: native/'s and the package
  // root's change the worker's rustflags and linker as much as its own does.
  // Only when present: the hooks runner re-runs a hook on every invocation
  // when a declared dependency is absent.
  for (final up in const ['', '../', '../../']) {
    for (final name in const ['.cargo/config.toml', '.cargo/config']) {
      final config = workerDir.resolve('$up$name');
      if (File.fromUri(config).existsSync()) {
        deps.add(config);
      }
    }
  }
  for (final sub in const ['src/', 'upstream/']) {
    final dir = Directory.fromUri(workerDir.resolve(sub));
    for (final e in dir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.rs')) {
        deps.add(e.uri);
      }
    }
  }
  output.dependencies.addAll(deps);
}

/// The first non-empty file among [candidates], relative to [crateDir].
File? _firstBuilt(Uri crateDir, List<String> candidates) {
  for (final sub in candidates) {
    final f = File.fromUri(crateDir.resolve(sub));
    if (f.existsSync() && f.lengthSync() > 0) return f;
  }

  return null;
}

/// Installs the std library for [triple] via rustup, if rustup is present.
///
/// native/rust-toolchain.toml lists no `targets`, so only the host's std is
/// guaranteed. The host case is a fast no-op; a cross-arch desktop build (an
/// x64 slice on an arm64 Mac, say) gets its target here. Failures are ignored
/// on purpose: without rustup, cargo's own missing-target error is the clearer
/// message.
Future<void> _ensureRustTarget(String triple, String workingDirectory) async {
  try {
    await Process.run('rustup', [
      'target',
      'add',
      triple,
    ], workingDirectory: workingDirectory);
  } on ProcessException {
    // rustup not on PATH (distro cargo); let cargo report the problem.
  }
}

List<String> _cargoPaths(OS os, Architecture? arch, String libName) {
  final triple = _rustTriple(os, arch);

  return [
    if (triple != null) 'target/$triple/release/$libName',
    'target/release/$libName',
  ];
}

String? _rustTriple(OS os, Architecture? arch) {
  final a = arch?.toString() ?? 'arm64';

  return switch ((os, a)) {
    (OS.macOS, 'arm64') => 'aarch64-apple-darwin',
    (OS.macOS, 'x64') => 'x86_64-apple-darwin',
    (OS.linux, 'arm64') => 'aarch64-unknown-linux-gnu',
    (OS.linux, 'x64') => 'x86_64-unknown-linux-gnu',
    (OS.windows, 'arm64') => 'aarch64-pc-windows-msvc',
    (OS.windows, 'x64') => 'x86_64-pc-windows-msvc',
    _ => null,
  };
}

/// Publishes [src] to [dest] without truncating [dest] in place.
///
/// `File.copySync` opens the destination `O_TRUNC`, shortening the EXISTING
/// inode. Linux allows that even for a `dlopen`ed library — `ETXTBSY` guards
/// only the running executable — so a concurrent reader of [dest] can see a
/// half-written file. `rename(2)` swaps the directory entry instead, so a
/// reader gets either the whole old file or the whole new one.
///
/// SCOPE: this is NOT the fix for core#161. The file the VM `dlopen`s is
/// `.dart_tool/lib/…`, which dartdev rewrites in place on every `dart` command
/// regardless of this hook (measured: same inode, new mtime, every run). This
/// only protects the file dartdev copies FROM.
void _publishAtomically(File src, File dest) {
  final tmp = File(
    '${dest.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    src.copySync(tmp.path);
    tmp.renameSync(dest.path);
  } on Object {
    if (tmp.existsSync()) {
      tmp.deleteSync();
    }
    rethrow;
  }
}
