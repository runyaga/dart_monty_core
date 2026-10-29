# dart_monty_core

<p align="center">
  <img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/assets/dart_monty.jpg" alt="dart_monty_core" width="280">
</p>

[![CI](https://github.com/runyaga/dart_monty_core/actions/workflows/ci.yaml/badge.svg)](https://github.com/runyaga/dart_monty_core/actions/workflows/ci.yaml)
[![codecov](https://codecov.io/gh/runyaga/dart_monty_core/graph/badge.svg)](https://codecov.io/gh/runyaga/dart_monty_core)

[GitHub](https://github.com/runyaga/dart_monty_core)

**dart_monty_core 0.130.0 · monty 1.3.0**

`dart_monty_core` runs Python in Dart through
[pydantic-monty](https://github.com/pydantic/monty), a sandboxed Python
interpreter written in Rust. Dart programs can provide typed inputs, host
functions, OS operations, host-directory mounts, resource limits, and type
checking. Results return as typed `MontyValue` objects.

Dart applications cannot load new behavior without shipping a new binary.
Monty lets an application run supplied Python under resource limits while
exposing only selected host functions and OS operations. Pydantic runs a
security bug bounty for the interpreter at
[hackmonty.com](https://hackmonty.com/).

Each session runs outside the application process. Native sessions use child
processes, and browser sessions use Web Workers. A sandbox crash ends its
worker and session without ending the application. The pool replaces the
worker for a later checkout.

## Installation

```bash
dart pub add dart_monty_core
```

## Quick start

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final value = await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await session.feedRun(
        'def fib(n): return n if n < 2 else fib(n - 1) + fib(n - 2)',
      );
      return session.feedRun('fib(10)');
    }),
  );
  print(value); // MontyInt(55)
}
```

The example evaluates Fibonacci in a pooled session.

## Platform support

| Platform | Worker | Setup |
|---|---|---|
| Dart VM and AOT on macOS, Linux, and Windows | Child process | Supply a worker or enable the native build hook |
| dart2js and dart2wasm | Web Worker | The package supplies the worker assets |

See [Native worker](docs/native-worker.md) for native worker setup, browser
asset serving, caching, integrity checks, Flutter packaging, and platform
details.

Host-directory mounts require the native mount library and are unavailable in
browsers. `OSAccess` provides an in-memory filesystem on every platform.

## Documentation

- [Documentation index](docs/README.md)
- [Execution model](docs/reference/execution-model.md)
- [Host functions and async](docs/deep-dives/async-matrix.md)
- [OS access](docs/reference/os-access.md)
- [Host directory mounts](docs/reference/host-directory-mounts.md)
- [Telemetry](docs/reference/telemetry.md)
- [Fake sessions](docs/reference/fake-session.md)
- [Upstream divergences and limitations](docs/reference/upstream-divergences.md)
- [Package versioning](docs/reference/versioning.md)

The API reference documents values, errors, snapshots, limits, callbacks, and
session methods. The package exports test doubles from
`package:dart_monty_core/dart_monty_core_testing.dart` and host-backed virtual
files from `package:dart_monty_core/unsafe_callback_file.dart`.

Contributor commands and repository rules are in [AGENTS.md](AGENTS.md).

## License

MIT.
