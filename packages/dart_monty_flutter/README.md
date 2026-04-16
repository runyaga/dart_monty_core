# dart_monty_flutter

Flutter REPL demo for [Monty](https://github.com/pydantic/monty) — a sandboxed
Python interpreter in Rust, wrapped by `dart_monty_core`.

This is a **cargo-culting example**: copy the patterns here to build your own
Flutter app on top of `dart_monty_core`.

---

## What it is

A dark-themed Material REPL app backed by `MontyRepl`. Enter Python expressions;
results appear in a scrollable output panel. State is persistent across inputs —
define a function, call it on the next line.

**Supported platforms**: iOS · Android · macOS · Linux · Windows

**Not supported here**: Flutter web — use [`packages/dart_monty_web`](../dart_monty_web/)
for the browser REPL.

---

## How dart_monty_core is used

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

// Create a persistent REPL (keeps the Rust heap alive between calls)
final repl = MontyRepl();

// Feed Python — result.value is a typed MontyValue
final result = await repl.feed('fib(10)');

switch (result.value) {
  case MontyInt(:final value):    print('int: $value');
  case MontyString(:final value): print('str: $value');
  case MontyNull():               print('None');
  default:                        print(result.value);
}

if (result.error != null) {
  print('${result.error!.excType}: ${result.error!.message}');
}

// Always dispose when done
await repl.dispose();
```

Key API surface used in `lib/main.dart`:
- `MontyRepl()` — creates a persistent interpreter (backed by FFI dylib on device)
- `repl.feed(code)` — execute Python, returns `MontyFeedResult`
- `result.value` — `MontyValue?` (null = expression with no return value)
- `result.error` — `MontyScriptError?` (non-throwing; TypeError, NameError, …)
- `result.printOutput` — captured `print()` output
- `repl.dispose()` — free Rust heap resources (call in `State.dispose()`)

---

## Prerequisites

```bash
# Flutter SDK 3.27+
flutter --version

# Rust toolchain (for the native dylib)
rustup --version
```

Build the native dylib for your target platform (one-time, or after Rust source changes):

```bash
cd ../../native && cargo build --release && cd -
```

Output:
- macOS: `native/target/release/libdart_monty_native.dylib`
- Linux: `native/target/release/libdart_monty_native.so`
- iOS/Android: cross-compile with `cargo build --release --target <triple>`

---

## Run

```bash
# Easiest — uses tool/run_flutter_demo.sh (auto-detects device)
bash ../../tool/run_flutter_demo.sh

# Specify a device
bash ../../tool/run_flutter_demo.sh --device macos
bash ../../tool/run_flutter_demo.sh --device ios

# Or directly with Flutter
flutter pub get
flutter run -d macos
```

---

## Note on Flutter web

This package targets native (mobile + desktop) platforms only. The `MontyFfi`
backend uses `dart:ffi` to load the native dylib — not available on the web.

For a browser REPL, see [`packages/dart_monty_web`](../dart_monty_web/), which
uses the `MontyWasm` backend backed by a WASM Worker.

The GitHub Pages demo at **https://runyaga.github.io/dart_monty_core/flutter/**
uses a separate Flutter web build (scaffolded with `flutter create --platforms web`)
that substitutes the WASM backend automatically.
