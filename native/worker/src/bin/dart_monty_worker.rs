//! The worker executable. Arguments are ignored: configuration arrives in the
//! protocol's `Configure` request.
use std::process::ExitCode;

fn main() -> ExitCode {
    dart_monty_worker::run_stdio()
}
