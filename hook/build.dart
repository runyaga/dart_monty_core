import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final code = input.config.code;
    final os = code.targetOS;
    final arch = code.targetArchitecture;

    final libName = switch (os) {
      OS.macOS => 'libdart_monty_core_native.dylib',
      OS.linux => 'libdart_monty_core_native.so',
      OS.windows => 'dart_monty_core_native.dll',
      _ => null,
    };

    // Graceful fallback for iOS/Android — no native assets for now.
    if (libName == null) return;

    final nativeDir = input.packageRoot.resolve('native/');

    // Testing-only opt-in: a `native/.test-hooks` marker file makes the hook
    // build the dylib with monty's `test-hooks` feature. Read HERE, before the
    // output path is chosen, because it is part of the cache key -- see below.
    final testHooksMarker = File.fromUri(nativeDir.resolve('.test-hooks'));
    final wantsTestHooks = testHooksMarker.existsSync();

    // THE OUTPUT PATH MUST ENCODE EVERYTHING THAT CHANGES THE ARTEFACT.
    //
    // `hooks` documents the requirement (hooks/lib/src/config.dart, on
    // `outputDirectoryShared`): "Use a sub directory of [outputDirectoryShared]
    // with a checksum of the parts on the [config] that influence your assets."
    //
    // This used to be keyed on ARCHITECTURE ALONE. The `test-hooks` cargo
    // feature produces a materially different dylib -- it adds monty's
    // synthetic `_test_cm()` -- and both variants resolved to the SAME cached
    // path, so whichever built last won and the other was silently served a
    // binary it did not ask for. Currently latent only because the single
    // caller that sets the marker (tool/test_cm.sh) is invoked by nothing and
    // clears it in an EXIT trap; it becomes real the moment a second
    // configuration is used.
    final variant = wantsTestHooks ? '$arch-test-hooks' : arch;
    final outFile = File.fromUri(
      input.outputDirectoryShared.resolve('$variant/$libName'),
    );
    outFile.parent.createSync(recursive: true);
    final cargoToml = File.fromUri(nativeDir.resolve('Cargo.toml'));

    if (cargoToml.existsSync()) {
      // Contributor path: always run cargo (handles incremental builds).
      final triple = _rustTriple(os, arch);
      final targetArgs = triple != null ? ['--target', triple] : <String>[];
      if (triple != null) {
        await _ensureRustTarget(triple, Directory.fromUri(nativeDir).path);
      }
      // A marker file (not an env var) is used because native-assets build
      // hooks run hermetically and don't inherit host env vars. The file is
      // gitignored and only tool/test_cm.sh creates it — never in shipped
      // builds. Read above, where it also selects the output subdirectory.
      final testHooks = wantsTestHooks
          ? ['--features', 'test-hooks']
          : <String>[];
      // `--locked` makes the committed native/Cargo.lock authoritative: cargo
      // fails rather than silently re-resolving if the lockfile is missing or
      // out of date. Without it a consumer whose archive lacked the lockfile
      // would re-resolve and hit a known-broken combination (a get-size2 whose
      // GetSize impl targets a different compact_str major than
      // ruff_python_ast uses), failing deep inside a dependency they do not
      // control. Failing here instead names the real problem.
      final result = await Process.run('cargo', [
        'build',
        '--locked',
        '--release',
        '--lib',
        ...targetArgs,
        ...testHooks,
      ], workingDirectory: Directory.fromUri(nativeDir).path);
      if (result.exitCode != 0) {
        throw StateError(
          'cargo build failed.\n'
          'stdout:\n${result.stdout}\n'
          'stderr:\n${result.stderr}',
        );
      }

      final built = _firstBuilt(nativeDir, _cargoPaths(os, arch, libName));
      if (built == null) {
        throw StateError(
          'cargo build succeeded but $libName not found in target directories.',
        );
      }
      _publishAtomically(built, outFile);
      _addAsset(output, input.packageName, outFile.uri);
      _declareInputs(output, nativeDir, testHooksMarker);

      // The worker cdylib, for `dart build cli` self-relaunch. Built ONLY
      // when the root package opts in; every other consumer runs exactly the
      // one cargo build above and gets exactly the one asset.
      if (_wantsWorker(input)) {
        await _buildWorker(input, output, nativeDir, os, arch, targetArgs);
      }

      return;
    }

    throw StateError(
      'native/Cargo.toml not found — clone the full monorepo to build from source.',
    );
  });
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
  // `--lib` builds the cdylib (and the rlib the executable links), with the
  // release profile the executable ships with. `--locked`, as above:
  // native/worker/Cargo.lock is seeded from upstream's and a fresh resolve is
  // known to fail.
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
  final built = _firstBuilt(workerDir, _cargoPaths(os, arch, libName));
  if (built == null) {
    throw StateError(
      'cargo build succeeded but $libName not found in target directories.',
    );
  }
  // Its own directory: with native/.test-hooks present the in-process
  // library goes to `<arch>-test-hooks/`, so `<arch>/` may not exist yet.
  final outFile = File.fromUri(
    input.outputDirectoryShared.resolve('$arch/$libName'),
  );
  outFile.parent.createSync(recursive: true);
  _publishAtomically(built, outFile);
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/worker/self_relaunch.dart',
      linkMode: DynamicLoadingBundled(),
      file: outFile.uri,
    ),
  );
  _declareWorkerInputs(output, workerDir);
}

/// What the worker library is built from: native/worker's manifest, lock and
/// build script, every Rust source under `src/` and `upstream/`, and the
/// toolchain file it shares with native/ (declared by [_declareInputs]).
void _declareWorkerInputs(BuildOutputBuilder output, Uri workerDir) {
  final deps = <Uri>[
    workerDir.resolve('Cargo.toml'),
    workerDir.resolve('Cargo.lock'),
    workerDir.resolve('build.rs'),
  ];
  final workerConfig = workerDir.resolve('.cargo/config.toml');
  if (File.fromUri(workerConfig).existsSync()) {
    deps.add(workerConfig);
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

void _addAsset(BuildOutputBuilder output, String packageName, Uri file) {
  output.assets.code.add(
    CodeAsset(
      package: packageName,
      name: 'dart_monty_core_ffi.dart',
      linkMode: DynamicLoadingBundled(),
      file: file,
    ),
  );
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

/// Tells the hooks runner WHAT THIS BUILD DEPENDS ON, so it can decide when to
/// re-run us.
///
/// Without this the runner is told nothing, its invalidation cannot fire, and
/// the job gets reimplemented elsewhere -- which is what happened:
/// `tool/gate.sh` grew a `native_source_hash` stamp that clears
/// `.dart_tool/hooks_runner` when `native/src` content changes. That is the
/// framework's job, and a substitute that only runs inside the gate leaves a
/// plain `dart test` with no invalidation at all.
///
/// `native/.test-hooks` is declared EVEN WHEN ABSENT, deliberately. It selects
/// the `test-hooks` cargo feature, so creating or deleting it changes the
/// artefact; declaring it is what makes the runner re-run us on that toggle
/// rather than serve the other variant. Observed before this was declared: a
/// run with the marker gone still loaded a test-hooks dylib, and the only thing
/// that caught it was one assertion that `gc` should raise ModuleNotFoundError.
void _declareInputs(
  BuildOutputBuilder output,
  Uri nativeDir,
  File testHooksMarker,
) {
  final deps = <Uri>[
    nativeDir.resolve('Cargo.toml'),
    nativeDir.resolve('Cargo.lock'),
    nativeDir.resolve('build.rs'),
    nativeDir.resolve('rust-toolchain.toml'),
  ];

  // `.cargo/config.toml` IS A BUILD INPUT and was not declared. It is where
  // rustflags, the linker and target settings live, so a change to it changes
  // the artefact while every declared dependency stays identical — the stale
  // -dylib class this hook's dependency list exists to prevent. Today the file
  // holds only a comment and an empty `[target.wasm32-wasip1]` section, so
  // this is a latent gap rather than a live defect; the cost of finding it
  // later is the hour already spent misdiagnosing a stale dylib.
  //
  // CONDITIONAL, for the reason recorded immediately below about
  // `native/.test-hooks`: declaring a file that does not exist makes the
  // runner re-run the hook on EVERY invocation. So it is added only when
  // present.
  final cargoConfig = nativeDir.resolve('.cargo/config.toml');
  if (File.fromUri(cargoConfig).existsSync()) {
    deps.add(cargoConfig);
  }
  // `native/.test-hooks` is NOT declared, and declaring it was a REGRESSION.
  // The runner records an absent declared dependency with a sentinel hash and
  // hashes it to a different value on the next check, so the two never compare
  // equal and the hook re-runs on EVERY invocation:
  //     "File modified during build. Build must be rerun."
  // Measured with nothing changed at all. Caching was not degraded, it was off.
  //
  // It does not need declaring: the marker selects the output SUBDIRECTORY
  // (`arm64` vs `arm64-test-hooks`), so toggling it changes the cache key and
  // the runner rebuilds for the new path on its own.
  if (testHooksMarker.existsSync()) {
    deps.add(testHooksMarker.uri);
  }
  final srcDir = Directory.fromUri(nativeDir.resolve('src/'));
  if (srcDir.existsSync()) {
    for (final e in srcDir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.rs')) {
        deps.add(e.uri);
      }
    }
  }
  output.dependencies.addAll(deps);
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
