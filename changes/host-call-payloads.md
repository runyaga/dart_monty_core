### Fixed

- A host function or method call whose argument arena upstream rejects (a node referencing one not below it, a class instance whose class is no class type, an argument or keyword root outside the arena) now ends the feed with `MontyCrashedError` (`monty worker protocol error: invalid payload from worker: <detail>`) and discards the worker, as upstream's conversion on arrival does. It used to raise `Exception` in the sandbox and keep the worker. A failure building the Python values from a valid arena still fails the call in Python.
- An OS call with no arm, or a `getenv` with no arena or a default root outside it, is a protocol violation in `feedRun` too (`monty worker protocol error: invalid OS call payload: <detail>`), with upstream's detail text (`missing required field OsCall.call`, `missing required field OsCall.values`). `feedStart`'s message no longer repeats the `invalid OS call payload` prefix.
- An OS handler's `Future` that fails with `OsCallNotHandledException` raises `TypeError` with upstream's conversion-refusal text, naming the Dart classes: `Cannot convert OsCallNotHandledException to Monty value — wrap class instances in ClassInstance(...)`.

### Internal

- `tool/generate_os_handler_oracle.py` records upstream's outcome for 24 OS-handler cases (sync and async declines, async values and raises, across file, env, clock and sleep calls) into `test/unit/worker/_os_handler_oracle.g.dart`; the pool suites run them on the VM, dart2js and dart2wasm.
