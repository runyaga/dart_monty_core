# Upstream divergences

pydantic-monty 1.3.0 is the specification for everything Python code can observe. This page lists every known place where dart_monty_core 0.130.0 behaves differently, and why. A behaviour that differs from upstream and is missing from this list is a bug.

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

| Id | Case | Upstream 1.3.0 | dart_monty_core | Class | Pinned by |
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

## The deep-feed rejection

Upstream 1.3.0 adds a public item the port does not mirror:
`monty::type_check_nesting_exception` (`crates/monty/src/parse.rs`), the
preflight a worker runs before it type-checks a feed. It refuses a source
whose expressions nest deeper than the parser's limit, with the syntax
error `Source is too deeply nested`.

The port answers such a feed the same way, and at once: the worker is
upstream's own code, so the refusal comes from the same check. On 1.2.0 the
type check walked the deep AST instead, and the feed ran into its deadline:
the worker was killed after the limit plus its grace (finding 39).
`test/unit/worker/_migration_130_cases.dart` pins the answer.

The Dart API has no counterpart to call, and the new public item has no row
in the capability manifest: the manifest counts capabilities, and the owner
decided that this one does not get a row.

## The working directory

The working directory follows upstream 1.3.0's rule, not the rule the 1.1.0
specification had. The driver counts the directory as established once a
feed reaches the worker, a feed the type check refuses included, so a later
feed without an explicit `cwd` sends none and the worker keeps the
directory it has (`os.chdir` included). Upstream 1.1.0's driver treated a
refused feed as leaving the directory unset and sent the default again.

The worker adopts the directory before it type-checks the snippet, so a
feed the type check refuses keeps the directory it was given: the explicit
`cwd` when one was given, the first mount's virtual path when a mount
chose it, `/` otherwise (upstream 1.3.0, measured). A feed the
source-nesting check refuses is answered before the worker adopts the
directory, so it leaves the session where it was (upstream 1.3.0,
measured).

`test/unit/worker/_mount_cwd_cases.dart` and
`test/unit/worker/_session_cases.dart` pin the rule.

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

## External modules: the Dart model

Upstream's `ExternalModule` is a Python object (`monty-proto`
`src/python/external_module.rs`): a frozen class whose `attrs` dict is
copied and checked once, at construction, whose `id` is a `uuid.UUID`, and
whose `__eq__` compares the id, the stubs and the attrs dict. The model
here is the same one, as a Dart class,
[`ExternalModule`](../../lib/src/platform/monty_value_structured.dart),
exported from the package. The guide to the module API itself is
[host modules](host-modules.md). The differences are these; they are against
upstream 1.3.0, the version that carries the module model, as is every
other table on this page.

| Id | Case | Upstream 1.3.0 | dart_monty_core | Class | Pinned by |
|---|---|---|---|---|---|
| E-1 | Attribute values compared | The two `attrs` dicts are compared with Python's `==`, so two lists with the same contents match | The id, the stubs and the attribute names are compared first, and then the values, structurally: a list element by element in order, a map entry by entry with the keys equal and the values equal, whatever order the entries come in, and any other value with its own Dart `==`, as is a map key. Two containers that are the very same object are equal without being walked into. A value that holds itself ends the comparison with a StateError whose message is `recursive ExternalModule equality`, as Python's RecursionError does. Not covered: an identity map holding several Python-equal keys, a list or a map used as a key, an arbitrary iterable, and Python's own scalar equality, so a Dart `1` and a Dart `true` are not equal | PLATFORM | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs", `test/unit/platform/external_module_equality_test.dart` "ExternalModule structurally compares Python-shaped attribute values" |
| E-2 | Hashing | Python's `ExternalModule` is unhashable: `TypeError: unhashable type: 'ExternalModule'` | The hash is Object.hash(id, stubs, Object.hashAllUnordered(keys)): the id, the stubs and the attribute names, never the values. Two modules that differ only in a value share a hash | PLATFORM | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-3 | Identity | The id is a `uuid.UUID` | The id is the canonical lowercase uuid string, made when it is absent | API-TYPING | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-4 | Parameters | `stubs` is an optional `str` and `id` an optional `uuid.UUID`, both checked by their types | Both are typed by Dart: `stubs` is a `String?` and `id` a `String?` | API-TYPING | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-5 | Construction errors | `TypeError` or `ValueError` with Python's text; a bad id is refused with `ExternalModule id must be a uuid.UUID` | A Dart `ArgumentError`. The attribute errors keep upstream's wording, but the id error keeps Dart's: `not a uuid`, in the Dart argument-error text. A key that is not a string names its Dart runtime type, where Python names its own | TEXT | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-6 | Attribute copies | `attrs` is a copy of the dict given, taken at construction, and the getter hands out a copy of it | The same: the map given is copied once, shallowly, and `attrs` and `publicAttrs` hand out fresh copies of it. The values are the very objects given | — | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-7 | Conversion | Every attribute is a Python object already | An ordinary value is converted when it is read, not at construction, so a value the sandbox cannot hold is refused late | — | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-8 | Text | `ExternalModule({...}, stubs=None, id=UUID('...'))`: the whole attrs dict | `ExternalModule(<count> attrs, stubs=<stubs or None>, id=UUID('<id>'))`: the count of the attributes, not their text | TEXT | `test/unit/platform/monty_value_test.dart` "ExternalModule copies attributes and validates names identity and stubs" |
| E-9 | Value subtype | Upstream's `ExternalModule` is a Python object (upstream's Rust type behind that Python class), not one of monty's values: the sandbox knows a module only as the module a session imported | It is a [`MontyValue`](../../lib/src/platform/monty_value_structured.dart) subtype here: `MontyValue.fromDart` hands a module back unchanged, and the value family counts it as one of its subtypes | API-TYPING | `test/unit/platform/external_module_value_test.dart` "ExternalModule is a MontyValue with opaque projection and import-only input" (E-9) |
| E-10 | Dart projection | A module that crosses back out of the sandbox decodes to a Python `ExternalModule` object | The `dartValue` projection is opaque: it is the module itself, not a copy of it and not a plain Dart value, so a host keeps the very module it built | NO-ANALOGUE | `test/unit/platform/external_module_value_test.dart` "ExternalModule is a MontyValue with opaque projection and import-only input" (E-10) |
| E-11 | Tagged JSON projection | A module is not one of monty's value nodes, so it has no tagged JSON form | There is none either, and the projection says so: `toJson` throws `UnsupportedError('ExternalModule has no tagged JSON representation')`, for the module on its own and for a container that holds one | NO-ANALOGUE | `test/unit/platform/external_module_value_test.dart` "ExternalModule is a MontyValue with opaque projection and import-only input" (E-11) |
| E-12 | Encoding as an ordinary input | `TypeError: an ExternalModule enters the sandbox only through external_modules, not as a value` (`monty-proto` `python/encode.rs`) | The same refusal, with the same text and the same Python `TypeError`, raised by the arena writer as a package-private class (`lib/src/worker/arena_writer.dart:1075`): a module sent on its own, and a module reached inside an ordinary container, are both refused | TEXT | `test/unit/platform/external_module_value_test.dart` "ExternalModule is a MontyValue with opaque projection and import-only input" (E-12) |
| E-13 | The type a module call names when the leaf is not callable | `TypeError: '<type>' object is not callable`, with CPython's own type name (`int`, `bytes`, `datetime.datetime`, `complex`; a binding class by its class name) | The same text, with the type of the leaf's Python counterpart: a builtin by its own name, the binding's own classes by their qualified name (`pydantic_monty.MontyClassProxy`, `pydantic_monty.ExternalModule`), and a value with no Python counterpart by its Dart type | TEXT | `test/unit/worker/host_answers_test.dart` "dotted calls resolve only public module functions and preserve async dispatch" |
| E-14 | The shape of a module factory | Any callable of no arguments that returns a module: a function, a bound method, a callable object, a lambda | A function of no arguments: the entry must be callable with zero arguments and return the module. A callable object is not one: it needs an explicit `.call` tear-off, so the factory reads `tools.call` and not `tools` | API-TYPING | `test/unit/worker/proto_session_test.dart` "module factories cache successes and retry failed resolutions" |
| E-15 | A factory that returns an awaitable | The synchronous pool refuses it: `RuntimeError: external_modules['tools']() returned an awaitable; async module factories require AsyncMonty`. The asynchronous pool awaits it | The driver is asynchronous, so a factory may return a future. It is awaited before the import or the call is answered, and its result is the module | API-TYPING | `test/unit/worker/proto_session_test.dart` "module factories cache successes and retry failed resolutions" |
| E-16 | The type a factory's refusal names | `TypeError: external_modules['tools']() returned int, not an ExternalModule`, with the Python type of the result | The same text, with the Dart type of the result instead of the Python one, and the same refusal for an entry that is neither a module nor a factory: `external_modules['tools'] must be an ExternalModule or a callable returning one, not <Dart type>` | TEXT | `test/unit/worker/proto_session_test.dart` "module factories cache successes and retry failed resolutions" |
| E-17 | The exception a factory's failure raises | The Python exception the factory raised, with its own type: a `ValueError` for a module whose attribute key upstream refuses, a `TypeError` for a key that is not a string | The Dart exception the factory raised, converted as any host failure is. A factory that builds a module upstream refuses keeps upstream's type: a `ValueError` for an attribute key it refuses, a `TypeError` for a key that is not a string | TEXT | `test/unit/worker/proto_session_test.dart` "module factories cache successes and retry failed resolutions" |
| E-18 | What a factory's result is checked against | The result must be a module, checked when the import that needs it runs | The same, and at the same time: the result is checked when it is reached, never when the mapping is given. A module the sandbox cannot hold is installed all the same: the conversion of its attributes happens later, and its failure does not undo the installation | — | `test/unit/worker/proto_session_test.dart` "module factories cache successes and retry failed resolutions" |

A module is a value in Dart (E-9), but not one the sandbox can hold: it
enters the sandbox through the session's `external_modules` mapping, and the
arena writer refuses one that arrives as an ordinary value, on its own or
inside a container (E-12). Its `dartValue` is the module itself (E-10), and
the tagged JSON projection has no form for it (E-11).

Both refuse a hard Python keyword as an attribute name, and both refuse a
nested module under a name the sandbox provides itself (upstream's
SANDBOX_MODULE_NAMES); the names only the type checker uses may still
name a host module.

The attribute values are compared structurally, as Python compares the
values of two dicts. The comparison follows the values, so it walks into
the containers a value holds; a pair of containers met again on the way is
a cycle, and the comparison ends with a StateError whose message is
`recursive ExternalModule equality`, as Python's RecursionError does. A
difference found before the cycle is answered first: the comparison stops at
the first difference and never walks into the cycle. A value that is
neither a list, a map nor a module is compared with its own Dart `==`, as
is a map key: Python's own scalar equality is not emulated.

## Module calls: the dispatch rules

A call the sandbox makes by a name that carries a dot is a module call: it
names an attribute of one of the session's host modules. The dispatch is
the one upstream's `callable` performs (monty-python 1.3.0
`src/external.rs`), and it runs after the call's arguments are checked and
after a call that names a host object has been dispatched to that object.

- The name is split at its **last** dot. The part before it is the module
  path; the part after it is the attribute's name.
- The first component of the path names the host module, and it is
  resolved as an import resolves it: the name is checked (a name that is
  not an identifier, or one the sandbox provides itself, is refused with
  `ValueError`), a factory is run, and its result is cached for the
  session.
- The rest of the path is walked through the module the first component
  named, one component at a time. Every other component names a public
  attribute of the module before it, and that attribute must itself be a
  module. A component that is missing, protected (its name starts with
  `_`), or not a module ends the walk: the call is then not found, as
  upstream stops at the first missing component.
- The leaf is the public attribute the module that path names holds. A name
  the module does not hold, or holds under a protected name, is not found.
- A leaf that is a host function is called through the ordinary function
  machinery, coroutines included: a function marked with `coroutine` is
  started and answered with a pending future, as any other host function
  is, so `asyncio.gather` runs several of them at once.
- A leaf that is any other value raises CPython's `TypeError: '<type>'
  object is not callable` (E-13). The value is not converted to name it:
  the type is read from the value's own type, so a value the conversion
  would refuse still names the type it would have had, and a failed
  conversion never replaces the answer the walk gives.

A name without a dot is the lookup's own, as it always was: it is resolved
through `external_lookup`, which is never consulted for a dotted name. A
dotted name in the lookup is not a module attribute, and is not called.

## Module imports: the dispatch rules

An `import` of a name the sandbox does not provide itself is an OS call the
worker sends to the parent (`OsCall.import`, field 31 of the v1.3.0
`OsCall`). The driver answers it from the session's `external_modules`,
before the mounts and the OS handler see it, as upstream's binding answers
it (monty-python 1.3.0 `src/external.rs`, `import_module`). The
`import_stubs` arm (field 32) is answered from the same mapping, before the
mounts and the OS handler see it too, as upstream's `import_stubs` does
(`src/external.rs`).

- The name the call carries is looked up in the session's mapping, read
  live: an entry added, replaced or removed after the session opened is
  seen by the next import, as upstream reads `external_modules`.
- A direct entry is resolved as it is. A nested module is part of the
  module value the import binds, imported by its dotted path, as
  upstream's `resolve_module` resolves the top-level name alone.
- An entry that is a factory is run, and its result is the module the
  import binds (see the factories below).
- The module crosses as an import: its public attributes, in insertion
  order, a callable as a host function named by its dotted path, a nested
  module as a module of its own, and any other value as the value it is.
- A name the mapping does not hold is not found (the protocol field
  `not_found`), which raises `ModuleNotFoundError` in the sandbox.
- A name that is not an identifier, or one the sandbox provides itself,
  raises `ValueError` with upstream's text, as upstream's `check_entry`
  does. The name is checked when it is looked up, so a name that is never
  asked for is never checked.
- An attribute the sandbox cannot hold raises `TypeError`, as upstream's
  `value_conversion_err` makes it. Its text is the port's own late
  conversion refusal (E-7), `Cannot convert <Dart type> to MontyValue`,
  where upstream writes `Cannot convert <type> to Monty value — wrap class
  instances in pydantic_monty.ClassInstance(...)`.
- No failure of the mapping escapes the answer: an error the lookup or the
  encoding raises is answered as an exception, with no message when the
  error's own text cannot be read, as upstream's `exception_arg` gives none
  when `str()` fails.

## Module factories: the Dart model

An entry of the session's mapping is a module itself, or a factory that
builds one. Upstream calls such an entry a factory too, and the rules are
the ones upstream's `resolve_module` and `install_module` apply (monty-
python 1.3.0 `src/external.rs`).

- A factory is a function of no arguments that returns the module. It may
  return a future instead: the driver is asynchronous, so the future is
  awaited before the import or the call that needs it is answered (E-15).
  A callable object is not a factory: it needs an explicit `.call`
  tear-off, so the entry reads `tools.call` and not `tools` (E-14).
- Nothing is checked when the mapping is given. The name is checked, and
  the entry with it, when a request reaches it: a name that is not an
  identifier, or one the sandbox provides itself, is refused with
  `ValueError`, and an entry that is neither a module nor a factory is
  refused with `TypeError` (E-16). A name the mapping does not hold is
  not found, and a name it holds with no value is refused, not found.
- A factory's result is checked when it arrives, and only a module is
  kept: any other result is refused with `TypeError`, naming the factory
  and the Dart type of the result (E-16).
- The module a factory built is installed before the import that needed it
  converts its attributes, and before the call that needed it calls one of
  them. A conversion that fails afterwards does not undo the
  installation (E-18).
- The installed module serves the rest of the session: the next import,
  the next call and the next resume see it, whatever the mapping holds by
  then. A direct entry is never installed: the mapping is read live, so a
  replaced entry is seen by the next request and a removed one is not
  found.
- A factory that fails is not installed: the failure is answered where it
  happened (as the exception the factory raised, E-17), and the next
  request runs the factory again, which may succeed then.
- A reset clears the installed modules: the next request runs the factory
  again. The mapping itself is kept, and the host's own entries with it.
- A dump carries no module and no installed module: the session that
  loads it keeps its own mapping, and resolves its modules again, lazily,
  when a restored import or call needs one.

The refusals name the Dart type of what was found, where upstream names
the Python type (E-16): a factory that returns a number is refused with
`external_modules['tools']() returned int, not an ExternalModule`, and an
entry that is a class is refused with
`external_modules['tools'] must be an ExternalModule or a callable
returning one, not the class String`.

## Module stubs: the dispatch rules

An `import_stubs` of the names the sandbox does not provide itself is an
OS call the worker sends to the parent (`OsCall.import_stubs`, field 32 of
the v1.3.0 `OsCall`). The driver answers it from the session's
`external_modules`, before the mounts and the OS handler see it, as
upstream's `import_stubs` does (monty-python 1.3.0 `src/external.rs`).

- The names the call carries are resolved in the order they were asked
  for, through the same resolver an import uses: the cache of the installed
  modules first, then the session's mapping, read live. A name the mapping
  does not hold is left out of the answer; a name it holds is answered.
- A factory that answers at once is installed as soon as its result is a
  module, as an import installs it. A factory that returns a future is
  staged: every factory of the ask runs before any of them is awaited, as
  upstream's `import_stubs_or_coroutine` does.
- The answer is the stubs of every module that was asked for: a dict of
  the dotted path of a module to its `.pyi` source, or `None` for a module
  without one, as upstream's `collect_stubs` builds it. A module is
  followed by its public submodules, in insertion order, and a protected
  one (its name starts with `_`) is left out. An ordinary attribute is
  neither converted nor called.
- The answer keeps the order the names were asked for, whatever order the
  factories finished in.

Five failures end the ask, and each of them is answered with the
structured error of the failure it is: the answer is a `ResumeCall` under
the call's own id, and no failure escapes the OS call as a thrown
exception.

- **A factory that fails at once**, or answers a value that is not a
  module: the factories after it do not run at all, the modules installed
  before it stay installed, and the results of the futures staged before
  it are never installed.
- **A failure of the resolver itself**: the resolver refuses an entry that
  is neither a module nor a factory by naming the type it found, and an
  entry whose type cannot be read fails that refusal. The ask is answered
  with the structured error of the failure, under the call's own id, and
  the futures staged before it are abandoned: their failure is observed,
  and their results are never installed.
- **A staged future that fails**: the ask ends at once, without waiting
  for the futures that are still pending, and no result of the batch is
  installed, not even one that succeeded before the failure.
- **A staged future that answers a value that is not a module**: the
  results before it are installed, in the order the names were asked for,
  and the ones after it are not installed at all.
- **A stub source the wire cannot hold**: a source with an unpaired
  UTF-16 surrogate has no UTF-8 form, so the answer cannot be encoded.
  The ask is answered with the `UnicodeEncodeError` the encoder raises,
  under the call's own id.

Upstream closes the coroutines it abandons (`src/external.rs:337`, the
`close_coroutine` branch of `import_stubs_or_coroutine`). **A Dart future
cannot be closed**: the port observes the failure of an abandoned future,
so that it is not an unhandled asynchronous error, and it never installs
the result such a future brings. That is all it promises: it does **not**
promise that a Python coroutine is closed, and it does **not** cancel the
host work the abandoned future was doing. A host that wants the work
stopped must stop it itself.

The observation covers every future the ask meets: the ones the factories
of the ask returned, and the one a factory returns while the stubs are
collected, when the mapping changed under the ask and names a factory
that is pending again. Such a future is observed the same way, and its
result is never installed.
