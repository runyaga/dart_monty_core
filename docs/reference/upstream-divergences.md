# Upstream divergences

pydantic-monty 1.1.0 is the specification for everything Python code can observe. This page lists every known place where dart_monty_core behaves differently, and why. A behaviour that differs from upstream and is missing from this list is a bug.

Classes:

- **PLATFORM**: the runtime cannot provide the feature.
- **NO-ANALOGUE**: the upstream feature depends on a CPython object with no Dart form.
- **API-TYPING**: Dart's static types rule out the upstream case at compile time.
- **TEXT**: same exception type and behaviour, different message text.
- **LEGACY-KEPT**: an existing API keeps its released behaviour; an additive API matches upstream.
- **ADDED-ABSENT**: upstream reports something core does not record; the Python-visible error matches.

Each test that pins a divergent outcome names the row id in its description.

| Id | Case | Upstream 1.1.0 | dart_monty_core | Class | Pinned by |
|---|---|---|---|---|---|
| C-1 | Host-directory mounts (`MountDir`) | Available | Unavailable on dart2js and dart2wasm, which have no `dart:ffi` or host filesystem | PLATFORM | `test/unit/mount/native_mounts_web_test.dart`, `test/unit/worker/mount_web_test.dart` |
| C-2 | A Python object passed as an input | Passed by reference | No Dart form; inputs are `MontyValue`s | NO-ANALOGUE | none (cannot be expressed) |
| C-3 | A host function returning a non-Monty object through the original `MontyHostFunction` constructor | `TypeError: Cannot convert ...` | Cannot happen: the callback is typed `FutureOr<MontyValue>`. `MontyHostFunction.parity` accepts `FutureOr<Object?>` and matches upstream | API-TYPING | `test/contract/_scenarios.dart` parity scenarios |
| C-4 | Unconvertible return on the parity path, type name | `Cannot convert __main__.Opaque to Monty value — wrap class instances in pydantic_monty.ClassInstance(...)` | Same text, with the Dart runtime type (`Opaque`) in place of the Python qualified name. A plain `Object()` gives `builtins.object`, as upstream | TEXT | `test/unit/worker/host_answers_test.dart` "C-4" test |
| C-5 | Unconvertible value from a `ClassType` or `ClassInstance` method, a lazy attribute, or a legacy coroutine | `TypeError: Cannot convert <qualified type> to Monty value — wrap class instances in pydantic_monty.ClassInstance(...)` | `TypeError: Cannot convert <Dart type> to Monty value — wrap class instances in ClassInstance(...)` | TEXT, LEGACY-KEPT | `test/contract/_scenarios.dart` mixed legacy and parity batch "C-5" |
| C-6 | A call to an undefined name | Records an external-function name lookup before the `NameError` | Raises the same `NameError` and records no lookup | ADDED-ABSENT | none |
