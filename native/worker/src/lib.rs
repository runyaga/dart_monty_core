//! dart_monty_core's worker: upstream's `monty subprocess` loop, verbatim, plus
//! the two entry points upstream's binary does not need (the self-relaunch
//! library and the wasm turn exports).
#![expect(unsafe_code, reason = "C ABI entry points for Dart and the Web Worker")]

#[cfg(not(target_arch = "wasm32"))]
use std::process::ExitCode;

/// Bounds worker memory, as `crates/monty-runtime/src/main.rs` does. Declared
/// once, here, so the executable, the self-relaunch library and the wasm module
/// all get it.
#[global_allocator]
static ALLOC: monty_alloc::LimitedAllocator = monty_alloc::LimitedAllocator;

/// Byte-identical copy of `crates/monty-runtime/src/subprocess.rs` at the
/// pinned tag, checked by `tool/check_worker_mirror.py`. Never edited here.
#[cfg(not(target_arch = "wasm32"))]
#[path = "../upstream/subprocess.rs"]
mod subprocess;

pub mod turn;

#[cfg(target_arch = "wasm32")]
pub mod wasm;

/// The stdio worker loop. Exit codes are upstream's: 0 on EOF or `Shutdown`,
/// 3 when stdout is gone, 4 on a fatal error, 76 on a framing error, 101 on a
/// panic, and 65 when the allocator's hard limit is breached.
#[cfg(not(target_arch = "wasm32"))]
#[must_use]
pub fn run_stdio() -> ExitCode {
    subprocess::run()
}

/// Self-relaunch entry: a relaunched Dart process calls this before anything
/// else writes to stdout, then exits with the returned code.
#[cfg(not(target_arch = "wasm32"))]
#[unsafe(no_mangle)]
pub extern "C" fn dart_monty_worker_main() -> i32 {
    let code = run_stdio();
    // `ExitCode` exposes no integer, but it is `PartialEq`, so this is exact.
    (0..=255u8).find(|n| ExitCode::from(*n) == code).map_or(101, i32::from)
}
