### Changed

- A worker that cannot start throws `MontyCrashedError` with upstream's text,
  `failed to spawn monty worker: <detail>` (`timedOut` false, `exitStatus`
  null). This replaces the `ProcessException` from a native launch and the
  `StateError` raised when no worker executable or web asset was found.
- A checkout that waits past `checkoutTimeout` throws `TimeoutException` with
  upstream's fixed message, `no monty worker became available within the
  checkout timeout`. The limit is still on `TimeoutException.duration`.
- When a worker frame does not decode, the `MontyCrashedError` text now matches
  upstream's: `monty worker protocol error: invalid payload from worker:
  failed to decode Protobuf message: <fields>: <reason>`.
- A host call whose argument arena upstream rejects is a protocol violation
  when the call suspends. `feedStart` and `resume` throw `MontyCrashedError`
  and do not return a `FunctionSnapshot`. Before, the snapshot's `arguments`
  threw `FormatException` when read.
