# dart_monty_flutter

Flutter integration for [dart_monty_core](https://github.com/runyaga/dart_monty_core) —
a sandboxed Python interpreter backed by [pydantic/monty](https://github.com/pydantic/monty)
(Rust + WASM).

> **Note for JS/npm users**: If you are building a JavaScript or TypeScript application,
> use [`@pydantic/monty`](https://www.npmjs.com/package/@pydantic/monty) directly —
> that is the canonical npm package. `dart_monty_flutter` exists for **Dart and Flutter**
> developers who want the same interpreter through Dart APIs.

---

## Quick start

### 1. Add the dependency

```yaml
# pubspec.yaml
dependencies:
  dart_monty_flutter:
    git:
      url: https://github.com/runyaga/dart_monty_core
      path: packages/dart_monty_flutter
      ref: main
```

### 2. Initialise in `main()`

```dart
import 'package:dart_monty_flutter/dart_monty_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On web: injects dart_monty_core_bridge.js (served automatically by Flutter
  // from packages/dart_monty_core/assets/).
  // On native: no-op — the Rust dylib is compiled at build time.
  await DartMontyFlutter.ensureInitialized();

  runApp(const MyApp());
}
```

### 3. Use the API

```dart
import 'package:dart_monty_flutter/dart_monty_flutter.dart';

// Persistent interpreter — Rust heap survives between calls
final repl = MontyRepl();

final result = await repl.feed('x = 42');
final r2    = await repl.feed('x * 2');      // MontyInt(84)

switch (r2.value) {
  case MontyInt(:final value):    print('int: $value');
  case MontyString(:final value): print('str: $value');
  case MontyNone():               print('None');
  default:                        print(r2.value);
}

if (r2.error != null) print('${r2.error!.excType}: ${r2.error!.message}');

repl.dispose(); // free Rust resources (call in State.dispose())
```

---

## How it works per platform

### Native (Android · iOS · macOS · Linux · Windows)

`dart_monty_core` ships a `hook/build.dart` Dart native-assets hook. When you
run `flutter pub get`, the hook runs `cargo build --release` on the consumer's
machine and links the resulting dylib. **You need Rust + cargo installed.**

`DartMontyFlutter.ensureInitialized()` is a no-op on native — the library is
already present at build time.

### Web (Flutter Web)

The Monty Python interpreter runs inside a Web Worker backed by a pre-built
`dart_monty_core_native.wasm` binary. `dart_monty_core` ships three pre-built
assets:

| Asset | Purpose |
|---|---|
| `dart_monty_core_bridge.js` | Main-thread bridge — exposes `window.DartMontyBridge` |
| `dart_monty_core_worker.js` | Web Worker — runs the WASM interpreter |
| `dart_monty_core_native.wasm` | Compiled Monty Rust interpreter |

Flutter serves package assets automatically at
`packages/dart_monty_core/assets/<file>`. `ensureInitialized()` injects a
`<script>` tag pointing at `dart_monty_core_bridge.js`; the bridge and worker
load the other two files relative to their own URL — no manual file copying
is needed.

---

## Passing Flutter state into Python

```dart
final result = await repl.feed(
  'score = base * multiplier',
  inputs: {
    'base': widget.score,
    'multiplier': widget.level,
  },
);
```

---

## VFS / OS calls

```dart
final monty = Monty(osHandler: (op, args, kwargs) async {
  if (op == 'Path.read_text') return myFs[args.first as String] ?? '';
  throw OsCallException('$op not supported');
});
await monty.run("import pathlib; pathlib.Path('/data/f.txt').read_text()");
```

---

## Demo app

`lib/main.dart` is a full three-panel Flutter REPL demonstrating concurrent
sessions, VFS/OsCall, and snapshot/restore. Run it with:

```bash
flutter pub get
flutter run -d macos   # or chrome, ios, android
```

Live web demo: **https://runyaga.github.io/dart_monty_core/flutter/**
