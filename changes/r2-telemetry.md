### Added

- Add `MontyTelemetry` and `instrumentTelemetry` for host telemetry adapters on native and web: session, execution and suspension spans, logs, callback context, and `SuspendedSnapshot.traceContext()`. Installation lasts for the isolate; adapter failures disable only the failing signal and report once without interrupting execution.

- Reject a queued worker completion when the process exits before its request
  finishes flushing, including when process cleanup masks the pipe's write error.
