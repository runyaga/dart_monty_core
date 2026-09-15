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

      for (final sub in _cargoPaths(os, arch, libName)) {
        final f = File.fromUri(nativeDir.resolve(sub));
        if (f.existsSync() && f.lengthSync() > 0) {
          _publishAtomically(f, outFile);
          _addAsset(output, input.packageName, outFile.uri);
          _declareInputs(output, nativeDir, testHooksMarker);

          return;
        }
      }

      throw StateError(
        'cargo build succeeded but $libName not found in target directories.',
      );
    }

    throw StateError(
      'native/Cargo.toml not found — clone the full monorepo to build from source.',
    );
  });
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

/// Publishes [src] to [dest] WITHOUT ever truncating [dest] in place.
///
/// `File.copySync` opens the destination `O_TRUNC`, shortening the EXISTING
/// inode. Linux permits that even when the file is a `dlopen`ed library mapped
/// `PROT_EXEC` -- `ETXTBSY` guards only the running executable. The truncation
/// returns success, any process holding that inode mapped keeps a mapping whose
/// pages no longer have backing, and its next touch dies with `SIGBUS` /
/// `si_code=BUS_ADRERR`. REPRODUCED: dlopen, hold a mapping, truncate from a
/// second process (rc=0, silent), read a page past EOF -> `Bus error (core
/// dumped)`, exit 135.
///
/// SCOPE -- READ THIS BEFORE TRUSTING IT. This protects the file written HERE,
/// under `outputDirectoryShared`. **That is not the file the VM `dlopen`s.**
///
/// Measured on this tree, three consecutive cached `dart test` runs:
///
///     run 1  .dart_tool/lib/...so   ino=467553  mtime=...385
///     run 2  .dart_tool/lib/...so   ino=467553  mtime=...386
///     run 3  .dart_tool/lib/...so   ino=467553  mtime=...386
///     shared output                 ino=473399  unchanged
///
/// The mapped copy keeps the SAME inode and is rewritten in place on every
/// `dart run`/`dart test`, including runs where this hook never executes --
/// dartdev bundles native assets unconditionally and copies with an
/// `O_TRUNC` open. So the `SIGBUS`/`BUS_ADRERR` hazard is NOT closed by this
/// function; it lives one layer up, outside this repo's control. core#161.
///
/// Keep this anyway: it removes a truncation window on the file dartdev copies
/// FROM, and the `$variant` keying above is independent of all of it.
///
/// WHY IT IS STILL NEEDED EVEN THOUGH THE RUNNER SERIALISES HOOKS. The runner
/// serialises hook-against-hook. It does nothing for a process that finished
/// its hook and is now EXECUTING a mapped library -- that lock was released
/// long before its tests started. Deleting the artefact is safe (`unlink`
/// leaves a mapped inode valid); overwriting it in place is not.
///
/// The exposure GREW when this hook started declaring dependencies:
/// `dart build` and Flutter honour them, so they re-run the hook on a source
/// change while the artefact still exists and may be mapped -- exactly the
/// case `copySync` mishandles. (`dart test` does not honour them; measured.)
///
/// `rename(2)` swaps the DIRECTORY ENTRY rather than editing the inode, so a
/// holder of the old inode keeps a complete mapping until it unmaps. The temp
/// file is created in the destination's own directory because rename is atomic
/// only within a filesystem. core#161.
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
