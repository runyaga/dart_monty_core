### Added

- `MontyHostFunction.parity` and `parityCoroutine` convert host function and coroutine results under Monty 1.1.0 parity rules: `null` becomes Python `None`, and an unconvertible object raises Python `TypeError` with `Cannot convert <T> to Monty value — wrap class instances in pydantic_monty.ClassInstance(...)`.
