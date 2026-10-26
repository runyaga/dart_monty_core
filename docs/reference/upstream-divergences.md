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

## Upstream limitations

Iterator-consuming builtins cannot call external functions. Calls such as
`map(ext_fn, ...)`, `filter(ext_fn, ...)`, and `sorted(..., key=ext_fn)` raise
`RuntimeError` upstream.

| Id | Case | Upstream 1.1.0 | dart_monty_core | Class | Pinned by |
|---|---|---|---|---|---|
| C-1 | Host-directory mounts (`MountDir`) | Available | Unavailable on dart2js and dart2wasm, which have no `dart:ffi` or host filesystem | PLATFORM | `test/unit/mount/native_mounts_web_test.dart`, `test/unit/worker/mount_web_test.dart` |
| C-2 | A Python object passed as an input | Passed by reference | No Dart form; inputs are `MontyValue`s | NO-ANALOGUE | none (cannot be expressed) |
| C-3 | A host function returning a non-Monty object through the original `MontyHostFunction` constructor | `TypeError: Cannot convert ...` | Cannot happen: the callback is typed `FutureOr<MontyValue>`. `MontyHostFunction.parity` accepts `FutureOr<Object?>` and matches upstream | API-TYPING | `test/contract/_scenarios.dart` parity scenarios |
| C-4 | Unconvertible return on the parity path, type name | `Cannot convert __main__.Opaque to Monty value — wrap class instances in pydantic_monty.ClassInstance(...)` | Same text, with the Dart runtime type (`Opaque`) in place of the Python qualified name. A plain `Object()` gives `builtins.object`, as upstream | TEXT | `test/unit/worker/host_answers_test.dart` "C-4" test |
| C-5 | Unconvertible value from a `ClassType` attribute or a legacy coroutine | `TypeError: Cannot convert <qualified type> to Monty value — wrap class instances in pydantic_monty.ClassInstance(...)` | `TypeError: Cannot convert <Dart type> to Monty value — wrap class instances in ClassInstance(...)` | TEXT, LEGACY-KEPT | `test/contract/_scenarios.dart` mixed legacy and parity batch "C-5" |
| C-6 | A call to an undefined name | Records an external-function name lookup before the `NameError` | Raises the same `NameError` and records no lookup | ADDED-ABSENT | `test/contract/_scenarios.dart` "C-6" scenario |
| C-7 | A builtin type (`MontyStdTypeProxy`) called directly by name from `externalLookup` | Decodes the proxy to the Python builtin type and calls it on the host (`p('42')` returns `42`) | Raises `TypeError: builtin type '<name>' cannot be called from externalLookup by name; read the name first` (reading the name first binds it in the sandbox) | NO-ANALOGUE | `test/unit/worker/_session_cases.dart` "C-7" test |
| C-8 | Browser default print sink | — | [`MontySession.feedRun`](../../lib/src/worker/monty_session.dart) | PLATFORM | `test/unit/worker/spec_proto_print_defaults_web_test.dart` "C-8" test |
| C-9 | Host-wrapper (`ClassInstance`, `ClassType`) equality and hash | Dataclasses compare equal by field values and raise `TypeError` when hashed (`unhashable type`) | `==` and `hashCode` use object identity (every Dart `Object` is hashable). That is the Dart object's own hashability; the containers Python would accept as input are validated apart from it (see below) | PLATFORM | `test/unit/worker/host_objects_test.dart` "C-9" tests, `test/unit/worker/arena_writer_kinds_test.dart` "arena inputs reject Python-unhashable host wrapper keys" test |
| C-10 | `MontyFloat` and `MontyComplex` NaN equality | `float('nan') == float('nan')` is `False` | `MontyFloat(double.nan)` (and `MontyComplex` with NaN parts) equals itself so values holding NaN can be map keys | LEGACY-KEPT | `test/unit/platform/monty_value_equality_rules_test.dart`, `test/unit/platform/monty_value_oracle_test.dart` "C-10" tests |
| C-11 | [`MontyExceptionValue`](../../lib/src/platform/monty_value_structured.dart) and [`MontyFileHandle`](../../lib/src/platform/monty_value_structured.dart) | — | See the declarations | NO-ANALOGUE | `test/unit/platform/monty_value_equality_rules_test.dart`, `test/unit/platform/monty_file_handle_test.dart` "C-11" tests |
| C-12 | `MontyError.display(format)` with an unknown format | Raises `ValueError` with `"Invalid display format: '<format>'. Expected 'traceback', 'type-msg', or 'msg'"` | Throws Dart `ArgumentError` with the same message | NO-ANALOGUE | `test/unit/worker/raised_record_test.dart`, `test/unit/worker/monty_error_test.dart` "C-12" tests |

## Host wrappers: Dart hashability and Python input validation

A `ClassType` or a `ClassInstance` is hashable in Dart: `==` and `hashCode`
are its identity (C-9), as every Dart object's are. Upstream's wrappers are
dataclasses (`class_instance.py:162`, `:214`), so Python cannot hash them,
and a host that put one in a dict or a set there would have been refused
before the value ever reached Monty (`TypeError: unhashable type:
'ClassInstance'`).

The two facts are kept apart here. The wrapper itself crosses as a value: it
registers in the session's host-object registry, and the sandbox resolves it
to the object it wraps (upstream's decoder resolves a registered class to
the original class object and a registered instance to the wrapper's `value`,
`decode.rs:145` and `:166`). Only the container that holds a wrapper as a
key or as a set member is refused, by the writer, with Python's own
`TypeError`; the wrapper as a dict value, as a list member or on its own is
sent as it is. Values that come back from the sandbox are read by the
[reader](../../lib/src/worker/arena_reader.dart), where a registered object
is a key by its own `==` and `hashCode`
([python keys](../../lib/src/worker/python_keys.dart)), so a dict the sandbox
built with the original object as its key collapses the way Python collapses
it.
