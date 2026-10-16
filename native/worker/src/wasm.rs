//! wasm32-wasip1 turn exports: one framed request in, that turn's framed events
//! out, through the owned streaming dispatcher. Mirrors the turn loop of
//! `crates/monty-wasm-runtime/src/lib.rs`: warm the clock and RNG before the
//! first session, re-arm the allocator after every turn, and answer a refused
//! arm with one `FatalError` and Shutdown.
use std::{
    cell::{Cell, RefCell},
    collections::hash_map::RandomState,
    mem,
    time::Instant,
};

use monty_proto::{
    FrameError, pb,
    worker::{Child, EventSink, HandleOutcome, fatal_error_event},
    write_frame,
};
use monty_types::memory_limit_with_headroom;

use crate::turn::dispatch_owned;

thread_local! {
    static BACKPRESSURE: Cell<bool> = const { Cell::new(false) };
    static CHILD: RefCell<Child> = RefCell::new(new_child());
    static OUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static OUTCOME: RefCell<u32> = const { RefCell::new(0) };
}

const PRINT_WINDOW: u32 = 4 * 1024 * 1024;

#[link(wasm_import_module = "dmw_host")]
unsafe extern "C" {
    // Plain import: returns outstanding bytes after posting this frame.
    fn emit(ptr: *const u8, len: usize) -> u32;
    fn wait();
}

/// Enable waits only after the host has successfully probed JSPI.
#[unsafe(no_mangle)]
pub extern "C" fn dmw_set_backpressure(enabled: u32) {
    BACKPRESSURE.set(enabled != 0);
}

#[derive(Default)]
struct StreamingSink {
    end: Vec<u8>,
}

impl EventSink for StreamingSink {
    fn send(&mut self, event: &pb::ChildEvent) -> Result<(), FrameError> {
        if matches!(event.kind, Some(pb::child_event::Kind::Print(_))) {
            let mut frame = Vec::new();
            write_frame(&mut frame, event)?;
            // SAFETY: emit copies this frame before returning, retaining no pointer.
            let outstanding = unsafe { emit(frame.as_ptr(), frame.len()) };
            drop(frame);
            if BACKPRESSURE.get() && outstanding > PRINT_WINDOW {
                // SAFETY: enabled only for a promising dispatch after the JSPI probe.
                unsafe { wait() };
            }
            Ok(())
        } else {
            write_frame(&mut self.end, event)
        }
    }
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
/// A nonempty buffer must come from dmw_alloc and is consumed exactly once.
/// Null or zero length denotes a non-owning empty probe.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dmw_dispatch(ptr: *const u8, len: usize) -> *const u8 {
    // Free the previous reply before the turn runs: the allocator charges every
    // live allocation to the session's memory budget, and the host has already
    // copied it. `take`, not `clear`, so the capacity goes too.
    drop(OUT.with_borrow_mut(mem::take));
    let request = if ptr.is_null() || len == 0 {
        Vec::new()
    } else {
        // SAFETY: the host transfers the allocation returned by dmw_alloc,
        // whose capacity is `len.max(1)`; `len` bytes are initialised.
        unsafe { Vec::from_raw_parts(ptr.cast_mut(), len, len.max(1)) }
    };
    let (mut frames, outcome, armed) = CHILD.with_borrow_mut(|child| {
        let mut sink = StreamingSink::default();
        let outcome = dispatch_owned(child, request, &mut sink);
        let frames = sink.end;
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
