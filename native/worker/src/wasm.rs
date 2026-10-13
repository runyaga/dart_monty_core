//! wasm32-wasip1 turn exports: one framed request in, that turn's framed events
//! out, through `monty_proto::worker::dispatch_frame`. Mirrors the turn loop of
//! `crates/monty-wasm-runtime/src/lib.rs`: warm the clock and RNG before the
//! first session, re-arm the allocator after every turn, and answer a refused
//! arm with one `FatalError` and Shutdown.
use std::{cell::RefCell, collections::hash_map::RandomState, mem, slice, time::Instant};

use monty_proto::{
    worker::{Child, HandleOutcome, dispatch_frame, fatal_error_event},
    write_frame,
};
use monty_types::memory_limit_with_headroom;

thread_local! {
    static CHILD: RefCell<Child> = RefCell::new(new_child());
    static OUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static OUTCOME: RefCell<u32> = const { RefCell::new(0) };
}

fn new_child() -> Child {
    // First use of the WASI clock and random source, before any limit applies.
    let _ = Instant::now();
    let _ = RandomState::new();
    Child::default()
}

/// Allocates `len` bytes for the host to write a request frame into.
#[unsafe(no_mangle)]
pub extern "C" fn dmw_alloc(len: usize) -> *mut u8 {
    let mut buf = vec![0u8; len.max(1)];
    let ptr = buf.as_mut_ptr();
    mem::forget(buf);
    ptr
}

/// Frees a buffer from [`dmw_alloc`].
///
/// # Safety
/// `ptr` and `len` must come from one `dmw_alloc` call, freed once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dmw_free(ptr: *mut u8, len: usize) {
    // SAFETY: the caller passes back the pointer and length of a `dmw_alloc`
    // allocation, whose capacity is exactly `len.max(1)`.
    drop(unsafe { Vec::from_raw_parts(ptr, len.max(1), len.max(1)) });
}

/// Length of the reply returned by the last [`dmw_dispatch`].
#[unsafe(no_mangle)]
pub extern "C" fn dmw_out_len() -> usize {
    OUT.with_borrow(Vec::len)
}

/// Outcome of the last [`dmw_dispatch`]: 0 = Continue, 1 = Shutdown, 2 = Fatal.
#[unsafe(no_mangle)]
pub extern "C" fn dmw_last_outcome() -> u32 {
    OUTCOME.with_borrow(|outcome| *outcome)
}

/// Protocol version this module speaks; the host refuses a mismatch before
/// `Configure`.
#[unsafe(no_mangle)]
pub extern "C" fn dmw_protocol_version() -> u32 {
    monty_proto::PROTOCOL_VERSION
}

/// One turn. Returns a pointer to `dmw_out_len()` bytes of framed events, valid
/// until the next call.
///
/// # Safety
/// `ptr` and `len` must describe a readable buffer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dmw_dispatch(ptr: *const u8, len: usize) -> *const u8 {
    // Free the previous reply before the turn runs: the allocator charges every
    // live allocation to the session's memory budget, and the host has already
    // copied it. `take`, not `clear`, so the capacity goes too.
    drop(OUT.with_borrow_mut(mem::take));
    let request = if len == 0 {
        &[][..]
    } else {
        // SAFETY: the caller guarantees `ptr` points at `len` readable bytes.
        unsafe { slice::from_raw_parts(ptr, len) }
    };
    let (mut frames, outcome, armed) = CHILD.with_borrow_mut(|child| {
        let (frames, outcome) = dispatch_frame(child, request);
        let budget = child.session_budget();
        let limit = memory_limit_with_headroom(budget.max_memory, budget.type_check);
        (frames, outcome, monty_alloc::set_hard_limit(limit))
    });
    // As monty-wasm-runtime: a refused arm replaces the turn's events with one
    // FatalError.
    let outcome = match armed {
        Ok(()) => outcome,
        Err(error) => {
            frames.clear();
            let _ = write_frame(&mut frames, &fatal_error_event(error));
            HandleOutcome::Shutdown
        }
    };
    OUTCOME.with_borrow_mut(|code| {
        *code = match outcome {
            HandleOutcome::Continue => 0,
            HandleOutcome::Shutdown => 1,
            HandleOutcome::Fatal => 2,
        }
    });
    OUT.with_borrow_mut(|out| {
        *out = frames;
        out.as_ptr()
    })
}
