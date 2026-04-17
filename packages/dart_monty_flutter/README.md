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

**Supported platforms**: iOS · Android · macOS · Linux · Windows · **Web**

Live demo: **https://runyaga.github.io/dart_monty_core/flutter/**

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
  case MontyNone():               print('None');
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
- `repl.feed(code)` — execute Python, returns `MontyResult`
- `repl.feed(code, inputs: {'x': 10})` — inject per-invocation variables
- `result.value` — `MontyValue?` (null = expression with no return value)
- `result.error` — `MontyScriptError?` (non-throwing; TypeError, NameError, …)
- `result.printOutput` — captured `print()` output
- `repl.dispose()` — free Rust heap resources (call in `State.dispose()`)

### Snapshot and restore

Use `Monty.snapshot()` and `Monty.restore()` to persist Python session state
across app restarts via `shared_preferences`:

```dart
import 'dart:convert';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _snapshotKey = 'monty_session';

// Save state when app goes to background
Future<void> saveState(Monty monty) async {
  final prefs = await SharedPreferences.getInstance();
  final bytes = await monty.snapshot();
  await prefs.setString(_snapshotKey, base64Encode(bytes));
}

// Restore state on app launch
Future<Monty> loadOrCreate() async {
  final prefs = await SharedPreferences.getInstance();
  final encoded = prefs.getString(_snapshotKey);
  final monty = Monty();
  if (encoded != null) {
    monty.restore(base64Decode(encoded));
  }
  return monty;
}
```

The snapshot captures all JSON-serializable Python variables (int, float, str,
bool, list, dict, None). Variables are restored into the Python scope on the
next `monty.run(...)` call.

### Passing Flutter state into Python

Use `inputs:` to inject widget state or user data into Python without
string-formatting:

```dart
final result = await repl.feed(
  'score = base * multiplier',
  inputs: {
    'base': widget.score,       // int from Flutter state
    'multiplier': widget.level, // int from Flutter state
  },
);
```

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

## Flutter web

The app runs on the web too. The CI build scaffolds the web target with
`flutter create --platforms web` and substitutes the `MontyWasm` backend
(WASM Worker) in place of `MontyFfi`, which requires a native dylib not
available in the browser. Everything else — the UI, the REPL loop, the
`MontyRepl` API — is identical.

Live: **https://runyaga.github.io/dart_monty_core/flutter/**
