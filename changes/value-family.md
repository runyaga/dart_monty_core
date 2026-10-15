### Breaking

- `MontyValue` gains five subtypes, all in the value library: `MontyComplex`, `MontyClassTypeProxy`, `ClassInstance`, `ClassType` and `MontyHostFunction`. An exhaustive `switch` over `MontyValue` needs an arm for each. `MontyHostFunction` is input-only: a decoded result never holds one, so its arm may throw.
- Equality is Python's. The numeric classes (`MontyBool`, `MontyInt`, `MontyBigInt`, `MontyFloat`, `MontyComplex`) compare and hash as one tower: `MontyBool(true) == MontyInt(1) == MontyFloat(1) == MontyComplex(1, 0)`, exactly (an integer never goes through a double). A named tuple equals a tuple of the same items, a set equals a frozenset with the same members, aware datetimes and times compare by instant (a naive one never equals an aware one; `fold` is ignored), and time zones compare by offset. A set or dict built with repeated members or keys compares as Python builds it: each member once; each key once, at its first position, with its last value. NaN still equals NaN, and exception values and file handles still compare their fields.
- `MontyFileHandle(path, mode, {BigInt? position})`: positional path and mode, as upstream's constructor. The mode is parsed and stored in canonical form (`rt` is `r`); a mode upstream refuses, a path with an unpaired surrogate, or a position outside 0..2^64-1 throws `ArgumentError` with upstream's message. `position` is a `BigInt`. `toString` is upstream's repr, `MontyFileHandle(path='/x', mode='r')`.
- `MontyPath(value)` is no longer `const`: the path is normalised as `PurePosixPath` at construction, so `MontyPath('a//b') == MontyPath('a/b')`.
- `MontyClassTypeProxy` compares by class id only, as upstream's; `MontyClassProxy` compares class name, dataclass flag and attributes, not the instance id.
- `MontyDateTime.dartValue` of an aware datetime is a UTC `DateTime` at its instant (a naive one stays local from its fields). `MontyValue.fromDart(DateTime)` keeps the offset: a local `DateTime` arrives in Python with its UTC offset, a UTC one with offset zero.
- `MontyTimeDelta.dartValue` throws `StateError` when a `Duration` cannot hold the timedelta exactly, instead of truncating.
- A registered host object or class returned by the sandbox decodes to its `ClassInstance` or `ClassType` wrapper; an unregistered class sent as a value decodes to a `MontyClassTypeProxy`, and `complex` values decode, where they used to throw `UnsupportedError`.
- `resolveOpenCall` builds the handle before any side effect, as upstream: an update mode (`r+`) now raises `ValueError`, as upstream's `FileMode` does.

### Added

- `MontyComplex(real, imag)`, `MontyHostFunction(name, fn, {docstring})`, and `MontyFileHandle.binary`, `.readable` and `.writable`.
