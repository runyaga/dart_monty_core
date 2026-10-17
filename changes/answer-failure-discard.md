### Fixed

- A failure while preparing a host answer to a suspended call, such as a host exception whose attributes cannot be read, discards the worker and finishes the session in `feedRun`, `FunctionSnapshot.resumeAuto` and `FutureSnapshot.resumeAuto`, as upstream does.
