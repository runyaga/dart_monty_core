# Host modules

A host module is a named bundle of values and host functions that the host
hands to a session and the sandbox imports by name. The host builds one with
[`ExternalModule`](../../lib/src/platform/monty_value_structured.dart) and
registers it through the `externalModules` parameter of
[`Monty.withSession`](../../lib/src/worker/monty.dart) or
[`Monty.checkout`](../../lib/src/worker/monty.dart). The sandbox then reaches
it with an ordinary Python `import`, and calls its functions by their dotted
name.

## A module the sandbox imports

This example builds a module with a constant and a host function, gives it to
a session, and calls it from Python.

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final tools = ExternalModule({
    'VERSION': 3,
    'add': MontyHostFunction('add', (arguments, keywords) {
      final left = arguments[0] as MontyInt;
      final right = arguments[1] as MontyInt;

      return MontyInt(left.value + right.value);
    }),
  });

  final result = await Monty.withPool(
    (monty) => monty.withSession(
      (session) => session.feedRun('import tools\ntools.add(2, 3)'),
      externalModules: {'tools': tools},
    ),
  );
  print(result); // MontyInt(5)
}
```

The Python the sandbox runs is two lines long:

```python
import tools

tools.add(2, 3)
```

The VERSION attribute is a value the module carries, and `add` is a
[`MontyHostFunction`](../../lib/src/platform/monty_value_structured.dart): the
sandbox calls it through its dotted name, `tools.add`, and the host's answer
comes back as a value. A module is a value of its own: it enters the sandbox
through the session's module map, and the arena writer refuses one that
arrives as an ordinary value.

The attributes are copied once, when the module is built, and the copy is
shallow: the values are the very objects the host gave, so a change the host
makes to one of them reaches the sandbox the next time the value is
converted. A value the sandbox already imported is not changed by it.

## The checkout parameter

`externalModules` is the same parameter on both ways into a session:
[`Monty.withSession`](../../lib/src/worker/monty.dart) takes it for a body
that owns the session, and
[`Monty.checkout`](../../lib/src/worker/monty.dart) takes it for a session the
caller keeps. The map is the very one the host gave: it is read live, so an
entry added, replaced or removed after the session opened is seen by the next
import. Nothing is checked when the map is given; a name and the entry under
it are checked when a request reaches them.

## Nested modules

An attribute whose value is another module is a submodule of its own. It is
imported by its dotted path, and its host functions keep their dotted names:

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

final tools = ExternalModule({
  'add': MontyHostFunction('add', (arguments, keywords) {
    final left = arguments[0] as MontyInt;
    final right = arguments[1] as MontyInt;

    return MontyInt(left.value + right.value);
  }),
  'text': ExternalModule({
    'upper': MontyHostFunction('upper', (arguments, keywords) {
      final text = arguments[0] as MontyString;

      return MontyString(text.value.toUpperCase());
    }),
  }),
});
```

```python
import tools.text

tools.text.upper('abc')
```

A submodule is a value inside its parent's attributes, not an entry of the
map: it crosses with its parent, and the map holds no entry and no factory
for it. A component of a dotted path that is missing, or that names
something other than a module, is not found, and the sandbox raises
ModuleNotFoundError, the error Python raises for a module it cannot find.

## Protected attributes

An attribute whose name starts with an underscore is protected: it is not
part of the module's public surface, the sandbox never sees it, and reading
it fails as a missing attribute does. A protected submodule is left out as
well. The host keeps them: the module's own `attrs` map holds every
attribute, protected ones included.

The module object the sandbox holds is read-only too: assigning one of its
attributes fails, as it does for the modules the sandbox provides itself.

## Stubs

A module may carry the `.pyi` source the type checker needs, in its `stubs`
field. The worker scans the source of a feed for the modules it imports that
the sandbox does not provide itself, and asks the host for their stubs
before it type checks that feed, and before the feed runs.

Two sets of names are left out of that ask. The modules the sandbox provides
itself never reach the host at all. The names the type checker vendors for
itself — `abc`, `builtins`, `enum`, `types`, `typing_extensions` and the
rest of that set — are never asked for either, although a host may offer a
module under one of them: the import of such a module reaches the module map
as usual, but the worker asks for no stubs of it, and the type checker
keeps the ones it has.

The ask belongs to a session that type checks: a session without a type
checker never asks for stubs, and a feed that skips the type check asks for
nothing either. A module is asked for once per session: the worker marks it
as asked only after the answer has come back, so a module whose answer was
an error is asked for again by the next feed. A reset of the session starts
the asks over as well: the record of the asked modules goes with the type
checker. An answer that is an error ends the feed with it, and the modules
the ask named stay unasked. The names one ask carries are the top-level
modules of the source, in source order. The answer is the stub source of
every module that was asked for, keyed by its dotted path. A module without
stubs answers with no source for its path.

The ask does not follow an import: it is made from the source, before
anything runs. A factory can therefore run for a module the feed then fails
to type check, because the ask reaches the map first and the type check
rejects the feed afterwards.

## Factories and their lifetime

An entry of the map is a module, or a factory that builds one: a function of
no arguments that returns a module, or a future of one, since the driver is
asynchronous. A factory runs when a request first needs the module — an
import, a stub request, or a module call through a restored binding — and not
before, so a module no feed imports costs nothing to offer. A stub request
needs a module before the type check runs, so a factory can run for a module
the feed is then refused for.

A factory's result is cached once it is installed: an installed result
serves every later import, call and resume, whatever the map holds by
then. A factory that fails is not installed: the failure is answered where
it happened, and the next request runs the factory again, which may succeed
then. A direct entry is never cached, because the map is read live: a
replaced entry is seen by the next request and a removed one is not found. A
session reset, or a session restored from a dump, starts the factories over:
the map is kept, and the next request runs the factory again.

An installation is not a given inside a stub ask, because the ask resolves
the names it carries in order and a failure ends it. A factory that fails
at once, or that answers a value that is not a module, stops the ask, and
the factories after it do not run; a factory that returns a future is
staged, and the staged futures are awaited together, so a future that
fails ends the ask and the results of the other futures are discarded, and
a future that answers a value that is not a module ends it with the results
before it installed and the ones after it not installed at all. A result
that was not installed is not cached either, so the next request runs its
factory again. The failures of a stub ask, and what each of them leaves
behind, are listed in
[upstream divergences](upstream-divergences.md#module-stubs-the-dispatch-rules).

## A module is not a lookup value

A feed's `externalLookup` map holds one value per name, and it is the map
the feed was given: it belongs to that feed alone. A module is none of
that: it is imported by name, it carries a set of attributes, and it lives
for the session. The two never mix:

- a name in `externalLookup` is resolved by the lookup, whatever the module
  map holds, and a dotted name is never resolved through the lookup at all;
- inputs bind as globals before the code runs and take precedence over
  `externalLookup`;
- a module cannot travel as a value: the arena writer refuses one that
  arrives as an ordinary input, on its own or inside a container.

Only the map is per feed. A value it holds outlives the feed: a plain value
is converted when the name is read, and the read binds it as a global, so a
later feed reads the name and finds the value, with no lookup map of its own.
A host function binds the same way, under the name of its lookup key.

A host function supplied to `feedRun` through `externalLookup` and a
function of a host module are two different things:

- a lookup function is found by its bare name, when the sandbox reads a name
  it does not define itself, and it is called under the name of the lookup
  key. The map that carries it belongs to one feed, and the function is
  bound under its key as soon as the name has been read;
- a module function is found by its dotted name, `tools.add`, and it is
  resolved through the session's module map, never through the lookup. The
  map that carries it belongs to the session, so the function is there for
  every feed of it, and a call to it is answered like any other host
  function call.

See [host functions and async](../deep-dives/async-matrix.md) for how a host
function answers, and [OS access](os-access.md) for the calls an OS handler
answers.

## How an import is routed

An `import` of a name the sandbox does not provide itself is an OS call the
worker sends to the parent, and the driver answers it from the session's
module map, before the mounts and the OS handler see it. The stub request,
the `import_stubs` call, comes from the scan of the source the worker makes
before it type checks a feed, and it is answered from the same map, before
the mounts and the OS handler too. The Import and ImportStubs calls are the
only OS calls a module map answers, and the map is asked before the mounts
and the handler on both paths: a feed that runs, and a session that is
resumed through a snapshot.

The two system sleeps are the calls whose route depends on the path. While a
feed runs through `feedRun`, the driver waits for `systemSleep` and
`asyncSystemSleep` itself, up to the session's sleep limit, and answers them
before the module map is asked: they reach neither the mounts nor the OS
handler. A snapshot resumed with `resumeAuto`, the way `feedStart` hands
its suspensions out, is answered by the driver without a session-side wait:
an OS call of that resume goes to the mounts and then to the OS handler, so
the two sleeps reach them too. Every other call goes to the mounts and then
to the OS handler, as
[host directory mounts](host-directory-mounts.md) and
[OS access](os-access.md) describe.

A name the map does not hold is not found, and the sandbox raises
ModuleNotFoundError. The modules the sandbox provides itself, `json` or
`math` among them, never reach the map.

## The examples

[example/15_host_module.dart](../../example/15_host_module.dart) walks the
whole exposure boundary of a module: the import and the dotted calls, the
module id, the public attributes and the protected ones, the refusals it
collects (an assignment to a module attribute, a call of the module itself,
a missing attribute, an unknown module or submodule, and a name that cannot
name a module) and the host exception a call raises by name.

The demos that follow it are the debugger
([example/16_step_debugger.dart](../../example/16_step_debugger.dart)), the
restore limits
([example/17_restore_limits.dart](../../example/17_restore_limits.dart)) and
the durable agent
([example/18_durable_agent.dart](../../example/18_durable_agent.dart)).

## Where the rules live

[`ExternalModule`](../../lib/src/platform/monty_value_structured.dart) defines
the module itself, and [`Monty`](../../lib/src/worker/monty.dart) defines the
map that holds it. [Upstream divergences](upstream-divergences.md) lists
every place where the Dart model differs from pydantic-monty, and why.
