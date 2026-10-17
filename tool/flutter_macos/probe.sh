#!/usr/bin/env bash
# Build a throwaway Flutter macOS app, add the worker after the build, and
# verify that the app-bundle location starts Monty. Flutter GUI apps cannot be
# opened in CI, so the final execution is a plain Dart driver that derives the
# same Contents/Helpers path a real app gets from Platform.resolvedExecutable.
#
# The post-build embed is intentional. It is the equivalent of the Xcode Run
# Script phase documented by embed_worker.sh, while avoiding brittle edits to
# Flutter's generated project.pbxproj.

set -euo pipefail

prefix='flutter_macos/probe'
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
embed="$here/embed_worker.sh"

fail() {
  printf 'PROBE %s fail %s\n' "$1" "$2" >&2
  exit 1
}

pass() {
  printf 'PROBE %s pass %s\n' "$1" "$2"
}

usage() {
  cat <<'EOF'
Usage: probe.sh --worker <path> --sha256 <64-hex>
EOF
}

worker=''
sha256=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --worker)
      [ "$#" -ge 2 ] || fail arguments '--worker needs a path'
      worker=$2
      shift 2
      ;;
    --sha256)
      [ "$#" -ge 2 ] || fail arguments '--sha256 needs a 64-hex digest'
      sha256=$2
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      fail arguments "unknown argument: $1"
      ;;
  esac
done

[ -n "$worker" ] || fail arguments '--worker is required'
[ -n "$sha256" ] || fail arguments '--sha256 is required'
[ -f "$worker" ] || fail arguments "worker does not exist: $worker"
[ -x "$embed" ] || fail arguments "embed script is not executable: $embed"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/dart-monty-flutter-macos.XXXXXX")
cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

project="$temporary_root/monty_macos_probe"
if ! flutter create --platforms=macos --empty \
  --project-name monty_macos_probe "$project"; then
  fail flutter-create 'flutter create failed'
fi
pass flutter-create "$project"

cat > "$project/pubspec.yaml" <<EOF
name: monty_macos_probe
description: Throwaway macOS app-bundle worker-delivery probe.
publish_to: none

environment:
  sdk: ^3.10.0

dependencies:
  dart_monty_core:
    path: $root
  flutter:
    sdk: flutter

# Deliberately no hook user_define: this app must not put a worker library in
# Contents/Frameworks. It receives only the executable in Contents/Helpers.
flutter:
  uses-material-design: false
EOF

mkdir -p "$project/lib"
cat > "$project/lib/main.dart" <<'EOF'
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final workerLocation =
      '${File(Platform.resolvedExecutable).parent.parent.path}/Helpers/dart_monty_worker';
  try {
    final result = await Monty.withPool(
      (monty) => monty.withSession(
        (session) => session.feedRun('1 + 1'),
      ),
      workerLocation: workerLocation,
    );
    if (result.dartValue != 2) {
      stderr.writeln('unexpected result: ${result.dartValue}');
      exit(1);
    }
    stdout.writeln('result=2');
    exit(0);
  } on Object catch (error, stackTrace) {
    stderr.writeln('$error\n$stackTrace');
    exit(1);
  }
}
EOF

if ! (cd "$project" && flutter pub get); then
  fail pub-get 'flutter pub get failed'
fi
pass pub-get 'path dependency resolved without hook opt-in'

if ! (cd "$project" && flutter build macos --release); then
  fail build 'flutter build macos --release failed'
fi
app="$project/build/macos/Build/Products/Release/monty_macos_probe.app"
[ -d "$app" ] || fail build "built app is missing: $app"
pass build "$app"

app_executable="$app/Contents/MacOS/monty_macos_probe"
[ -f "$app_executable" ] || fail app-executable "app executable is missing: $app_executable"
if ! app_architectures=$(lipo -archs "$app_executable" 2>&1); then
  fail app-architectures "lipo failed: $app_architectures"
fi
case "$app_architectures" in
  *x86_64*arm64* | *arm64*x86_64*)
    pass app-architectures "$app_architectures"
    ;;
  *)
    fail app-architectures "expected x86_64 arm64, got: $app_architectures"
    ;;
esac

if framework_worker=$(find "$app/Contents/Frameworks" -type f \( \
  -name libdart_monty_worker.dylib -o -name dart_monty_worker \
  \) -print -quit); then
  if [ -n "$framework_worker" ]; then
    fail no-hook-worker "unexpected worker library in Contents/Frameworks: $framework_worker"
  fi
else
  fail no-hook-worker 'cannot inspect Contents/Frameworks'
fi
pass no-hook-worker 'Contents/Frameworks has no dart_monty worker library'

if ! bash "$embed" --app "$app" --worker "$worker" --sha256 "$sha256"; then
  fail embed 'post-build embed failed'
fi
pass embed 'post-build Xcode-phase equivalent completed'

if ! bash "$embed" --check "$app"; then
  fail helper-check 'embedded helper did not pass check'
fi
pass helper-check 'helper exists, is executable, and is signed'

if ! codesign --verify --deep --strict "$app"; then
  fail app-signature 'whole app signature verification failed'
fi
pass app-signature 'codesign --verify --deep --strict'

wrong_sha256=0000000000000000000000000000000000000000000000000000000000000000
if bash "$embed" --app "$app" --worker "$worker" --sha256 "$wrong_sha256"; then
  fail mutant-wrong-sha256 'embedding unexpectedly accepted a wrong digest'
fi
pass mutant-wrong-sha256 'wrong digest was rejected'

helper="$app/Contents/Helpers/dart_monty_worker"
missing_helper="$app/Contents/Helpers/.dart_monty_worker.missing.$$"
mv "$helper" "$missing_helper"
if bash "$embed" --check "$app"; then
  mv "$missing_helper" "$helper"
  fail mutant-missing-helper '--check unexpectedly accepted a missing helper'
fi
mv "$missing_helper" "$helper"
pass mutant-missing-helper '--check rejected a missing helper'

headless="$project/build/macos/Build/Products/Release/headless_probe.dart"
cat > "$headless" <<'EOF'
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('usage: headless_probe.dart <App.app>');
    exitCode = 64;
    return;
  }

  final app = Directory(arguments.single);
  final resolvedExecutable =
      File('${app.path}/Contents/MacOS/monty_macos_probe');
  final workerLocation =
      '${resolvedExecutable.parent.parent.path}/Helpers/dart_monty_worker';
  final result = await Monty.withPool(
    (monty) => monty.withSession((session) => session.feedRun('1 + 1')),
    workerLocation: workerLocation,
  );
  if (result.dartValue != 2) {
    stderr.writeln('unexpected result: ${result.dartValue}');
    exitCode = 1;
    return;
  }
  stdout.writeln('result=2');
}
EOF

if ! headless_output=$(cd "$project" && dart run "$headless" "$app"); then
  fail headless 'plain Dart driver could not run the bundled helper'
fi
if [ "$headless_output" != result=2 ]; then
  fail headless "expected result=2, got: $headless_output"
fi
pass headless "$headless_output"

pass complete 'Flutter macOS worker delivery probe completed'
