### Internal

- The worker pool and session settings (unexported until the cutover) match
  pydantic-monty 1.1.0. Closing a pool lets a checkout already waiting or
  starting finish; its worker is killed at release. A negative
  `checkoutTimeout`, `requestTimeout` or duration-limit grace is an
  `ArgumentError` at pool start, and `maxCheckoutsPerWorker` takes
  0..2^32-1 (0 retires a worker at its first release). An unknown IANA zone
  name is refused before any worker is taken, checked against a generated
  list of the zones every worker's tz database holds
  (`tool/generate_tz_names.py`, checked by the gate and CI); an `Error`
  reply to `Configure` is raised as any error is. A `TypingError` event is
  `MontyTypingError` whatever the session's type check. A whole frame that
  does not decode is a protocol violation (`monty worker protocol error:
  invalid payload from worker: ...`), not a lost worker. A closed idle
  worker gets upstream's 500 ms to exit. `TimeZone` reports an offset
  outside `i32` and an unencodable name as upstream does; an integer and a
  float `RandomSeed` of equal value are equal; a string seed with no UTF-8
  form is refused. `SessionComplete.output` is decoded on each read and its
  `toString` is `MontyComplete(output=...)`. `SourceRange` takes
  `filename`, `start` and `end` by name and prints as upstream's repr, and a
  decoded position's file name is cut to 256 UTF-8 bytes on every
  suspension kind. Outcomes are recorded from pydantic-monty 1.1.0 by
  `tool/generate_config_oracle.py` and `tool/generate_worker_class_oracle.py`.
