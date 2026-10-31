//! Native in-process sessions, one upstream child per owned worker thread.
//! Replies are framed `Uint8List`s followed by an integer outcome; integer 3
//! is the final `EXITED` notification.

use std::{
    any::Any,
    cell::Cell,
    collections::HashMap,
    ffi::{CStr, c_char, c_void},
    mem,
    panic::{AssertUnwindSafe, catch_unwind, set_hook, take_hook},
    ptr, slice,
    sync::{
        Arc, Mutex, MutexGuard, Once, OnceLock, PoisonError,
        atomic::{AtomicBool, AtomicI64, Ordering},
        mpsc,
    },
    thread,
};

use monty_proto::{
    FrameError, pb,
    worker::{Child, EventSink, HandleOutcome, fatal_error_event},
    write_frame,
};
use monty_types::{BASELINE_MEMORY, LIVE_MEMORY};

use crate::turn::dispatch_owned;

const WORKER_STACK_SIZE: usize = 16 * 1024 * 1024;
const OUTCOME_CONTINUE: i64 = 0;
const OUTCOME_SHUTDOWN: i64 = 1;
const OUTCOME_FATAL: i64 = 2;
const EXITED: i64 = 3;

thread_local! {
    static INPROC_THREAD: Cell<bool> = const { Cell::new(false) };
}

static PANIC_FILTER: Once = Once::new();

#[repr(C)]
struct DartApiEntry {
    name: *const c_char,
    function: *const c_void,
}

#[repr(C)]
struct DartApi {
    _major: i32,
    _minor: i32,
    functions: *const DartApiEntry,
}

#[repr(C)]
struct DartTypedData {
    kind: i32,
    length: isize,
    values: *mut u8,
}

#[repr(C)]
union DartCObjectValue {
    as_int64: i64,
    as_typed_data: mem::ManuallyDrop<DartTypedData>,
}

#[repr(C)]
struct DartCObject {
    kind: i32,
    value: DartCObjectValue,
}

type DartPostCObject = unsafe extern "C" fn(i64, *mut DartCObject) -> bool;

const DART_COBJECT_INT64: i32 = 3;
const DART_COBJECT_TYPED_DATA: i32 = 7;
const DART_TYPED_DATA_UINT8: i32 = 2;

trait Poster: Send + Sync {
    fn post_frame(&self, port: i64, frame: &[u8]) -> bool;
    fn post_int(&self, port: i64, value: i64) -> bool;
}

struct DartPoster {
    post: DartPostCObject,
}

impl Poster for DartPoster {
    fn post_frame(&self, port: i64, frame: &[u8]) -> bool {
        let Ok(length) = isize::try_from(frame.len()) else {
            return false;
        };
        let typed_data = DartTypedData {
            kind: DART_TYPED_DATA_UINT8,
            length,
            values: frame.as_ptr().cast_mut(),
        };
        let mut object = DartCObject {
            kind: DART_COBJECT_TYPED_DATA,
            value: DartCObjectValue {
                as_typed_data: mem::ManuallyDrop::new(typed_data),
            },
        };
        // SAFETY: Dart_PostCObject copies typed data before returning and retains no pointer.
        unsafe { (self.post)(port, &raw mut object) }
    }

    fn post_int(&self, port: i64, value: i64) -> bool {
        let mut object = DartCObject {
            kind: DART_COBJECT_INT64,
            value: DartCObjectValue { as_int64: value },
        };
        // SAFETY: the object is live for the synchronous Dart_PostCObject call.
        unsafe { (self.post)(port, &raw mut object) }
    }
}

enum Command {
    Dispatch(Vec<u8>),
    Shutdown,
    Wake,
    #[cfg(test)]
    Panic,
}

struct Session {
    parent: i64,
    mem_limit: i64,
    cancelled: Arc<AtomicBool>,
    tx: mpsc::Sender<Command>,
}

#[derive(Default)]
struct Registry {
    reserved: i64,
    sessions: HashMap<i64, Session>,
}

struct Runtime {
    cap: AtomicI64,
    next_handle: AtomicI64,
    registry: Mutex<Registry>,
    poster: Arc<dyn Poster>,
}

impl Runtime {
    fn new(cap: i64, poster: Arc<dyn Poster>) -> Arc<Self> {
        install_inproc_panic_filter();
        // The in-process path establishes soft-limit accounting without arming a hard limit.
        let _ = BASELINE_MEMORY.fetch_min(LIVE_MEMORY.load(Ordering::Relaxed), Ordering::Relaxed);
        Arc::new(Self {
            cap: AtomicI64::new(cap.max(0)),
            next_handle: AtomicI64::new(1),
            registry: Mutex::new(Registry::default()),
            poster,
        })
    }

    fn registry(&self) -> MutexGuard<'_, Registry> {
        self.registry.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn open(self: &Arc<Self>, reply_port: i64, mem_limit: i64, parent_handle: i64) -> i64 {
        if mem_limit <= 0 {
            return -1;
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel();
        let handle;
        {
            let mut registry = self.registry();
            if parent_handle != 0 {
                match registry.sessions.get(&parent_handle) {
                    Some(parent) if !parent.cancelled.load(Ordering::Acquire) => {}
                    _ => return -2,
                }
            }
            let Some(reserved) = registry.reserved.checked_add(mem_limit) else {
                return -1;
            };
            if reserved > self.cap.load(Ordering::Acquire) {
                return -1;
            }
            handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
            if handle <= 0 {
                return -1;
            }
            registry.reserved = reserved;
            registry.sessions.insert(
                handle,
                Session {
                    parent: parent_handle,
                    mem_limit,
                    cancelled: Arc::clone(&cancelled),
                    tx,
                },
            );
        }

        let runtime = Arc::clone(self);
        let spawn = thread::Builder::new()
            .name(format!("monty-inproc-{handle}"))
            .stack_size(WORKER_STACK_SIZE)
            .spawn(move || runtime.run_session(handle, reply_port, &cancelled, &rx));
        if spawn.is_err() {
            let mut registry = self.registry();
            Self::cancel_descendants(&registry.sessions, handle);
            if let Some(session) = registry.sessions.remove(&handle) {
                registry.reserved -= session.mem_limit;
            }
            return -1;
        }
        handle
    }

    fn dispatch(&self, handle: i64, frame: Vec<u8>) -> i64 {
        let registry = self.registry();
        let Some(session) = registry.sessions.get(&handle) else {
            return -1;
        };
        if session.cancelled.load(Ordering::Acquire) {
            return -1;
        }
        session.tx.send(Command::Dispatch(frame)).map_or(-1, |()| 0)
    }

    fn cancel(&self, handle: i64) -> i64 {
        let registry = self.registry();
        let Some(session) = registry.sessions.get(&handle) else {
            return -1;
        };
        session.cancelled.store(true, Ordering::Release);
        let _ = session.tx.send(Command::Wake);
        Self::cancel_descendants(&registry.sessions, handle);
        0
    }

    fn close(&self, handle: i64) -> i64 {
        let registry = self.registry();
        let Some(session) = registry.sessions.get(&handle) else {
            return -1;
        };
        let _ = session.tx.send(Command::Shutdown);
        session.cancelled.store(true, Ordering::Release);
        let _ = session.tx.send(Command::Wake);
        Self::cancel_descendants(&registry.sessions, handle);
        0
    }

    fn cancel_descendants(sessions: &HashMap<i64, Session>, handle: i64) {
        for (child_handle, child) in sessions.iter().filter(|(_, session)| session.parent == handle) {
            child.cancelled.store(true, Ordering::Release);
            let _ = child.tx.send(Command::Wake);
            Self::cancel_descendants(sessions, *child_handle);
        }
    }

    fn run_session(
        self: Arc<Self>,
        handle: i64,
        reply_port: i64,
        cancelled: &AtomicBool,
        rx: &mpsc::Receiver<Command>,
    ) {
        INPROC_THREAD.set(true);
        let _exit = SessionExit {
            runtime: Arc::clone(&self),
            handle,
            reply_port,
        };
        let mut child = Child::default();
        loop {
            if cancelled.load(Ordering::Acquire) {
                break;
            }
            let Ok(command) = rx.recv() else {
                break;
            };
            if cancelled.load(Ordering::Acquire) {
                break;
            }
            match command {
                Command::Dispatch(frame) => {
                    if !self.run_turn(&mut child, reply_port, |child, sink| dispatch_owned(child, frame, sink)) {
                        break;
                    }
                }
                Command::Shutdown => break,
                Command::Wake => {}
                #[cfg(test)]
                Command::Panic => {
                    if !self.run_turn(&mut child, reply_port, |_, _| {
                        panic!("deliberate in-process test panic");
                    }) {
                        break;
                    }
                }
            }
        }
    }

    fn run_turn(
        &self,
        child: &mut Child,
        reply_port: i64,
        work: impl FnOnce(&mut Child, &mut PostingSink) -> HandleOutcome,
    ) -> bool {
        let mut sink = PostingSink {
            poster: Arc::clone(&self.poster),
            reply_port,
        };
        let result = catch_unwind(AssertUnwindSafe(|| work(child, &mut sink)));
        match result {
            Ok(outcome) => {
                let keep_running = outcome == HandleOutcome::Continue;
                self.poster.post_int(reply_port, outcome_code(outcome));
                keep_running
            }
            Err(payload) => {
                let message = format!("child panicked: {}", panic_message(payload.as_ref()));
                let _ = sink.send(&fatal_error_event(&message));
                self.poster.post_int(reply_port, OUTCOME_FATAL);
                false
            }
        }
    }

    fn exit_session(&self, handle: i64, reply_port: i64) {
        {
            let mut registry = self.registry();
            Self::cancel_descendants(&registry.sessions, handle);
            if let Some(session) = registry.sessions.remove(&handle) {
                registry.reserved -= session.mem_limit;
            }
        }
        self.poster.post_int(reply_port, EXITED);
    }

    #[cfg(test)]
    fn panic(&self, handle: i64) -> i64 {
        let registry = self.registry();
        let Some(session) = registry.sessions.get(&handle) else {
            return -1;
        };
        if session.cancelled.load(Ordering::Acquire) {
            return -1;
        }
        session.tx.send(Command::Panic).map_or(-1, |()| 0)
    }
}

struct SessionExit {
    runtime: Arc<Runtime>,
    handle: i64,
    reply_port: i64,
}

impl Drop for SessionExit {
    fn drop(&mut self) {
        self.runtime.exit_session(self.handle, self.reply_port);
    }
}

struct PostingSink {
    poster: Arc<dyn Poster>,
    reply_port: i64,
}

impl EventSink for PostingSink {
    fn send(&mut self, event: &pb::ChildEvent) -> Result<(), FrameError> {
        let mut frame = Vec::new();
        write_frame(&mut frame, event)?;
        self.poster.post_frame(self.reply_port, &frame);
        Ok(())
    }
}

fn outcome_code(outcome: HandleOutcome) -> i64 {
    match outcome {
        HandleOutcome::Continue => OUTCOME_CONTINUE,
        HandleOutcome::Shutdown => OUTCOME_SHUTDOWN,
        HandleOutcome::Fatal => OUTCOME_FATAL,
    }
}

fn panic_message(payload: &(dyn Any + Send)) -> &str {
    payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("unknown panic payload")
}

static RUNTIME: OnceLock<Arc<Runtime>> = OnceLock::new();

fn install_inproc_panic_filter() {
    PANIC_FILTER.call_once(|| {
        let previous = take_hook();
        set_hook(Box::new(move |info| {
            // The stdio hook writes a frame to stdout, so session threads never call it.
            if !INPROC_THREAD.get() {
                previous(info);
            }
        }));
    });
}

/// Stores Dart's dynamic API table and sets the process admission cap.
///
/// # Safety
/// `api_dl_data` must point to the table returned by `NativeApi.initializeApiDLData`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dmn_init(api_dl_data: *const c_void, cap_bytes: i64) -> i64 {
    if api_dl_data.is_null() {
        return -1;
    }
    if let Some(runtime) = RUNTIME.get() {
        runtime.cap.store(cap_bytes.max(0), Ordering::Release);
        return 0;
    }
    // SAFETY: the caller supplies Dart's live API table as required above.
    let mut entry = unsafe { (*api_dl_data.cast::<DartApi>()).functions };
    let mut post = ptr::null();
    // SAFETY: Dart terminates its API entry array with a null name.
    unsafe {
        while !entry.is_null() && !(*entry).name.is_null() {
            if CStr::from_ptr((*entry).name).to_bytes() == b"Dart_PostCObject" {
                post = (*entry).function;
                break;
            }
            entry = entry.add(1);
        }
    }
    if post.is_null() {
        return -1;
    }
    // SAFETY: Dart names this table entry Dart_PostCObject with this stable signature.
    let post = unsafe { mem::transmute::<*const c_void, DartPostCObject>(post) };
    let runtime = Runtime::new(cap_bytes, Arc::new(DartPoster { post }));
    let _ = RUNTIME.set(runtime);
    0
}

/// Opens one native session or returns -1 for admission and -2 for a dead parent.
#[unsafe(no_mangle)]
pub extern "C" fn dmn_open(reply_port: i64, mem_limit: i64, parent_handle: i64) -> i64 {
    RUNTIME
        .get()
        .map_or(-1, |runtime| runtime.open(reply_port, mem_limit, parent_handle))
}

/// Copies and enqueues one request frame without waiting for its turn.
///
/// # Safety
/// A nonzero `len` requires `ptr` to name `len` readable bytes for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn dmn_dispatch(handle: i64, ptr: *const u8, len: usize) -> i64 {
    let Some(runtime) = RUNTIME.get() else {
        return -1;
    };
    if len != 0 && ptr.is_null() {
        return -1;
    }
    let frame = if len == 0 {
        Vec::new()
    } else {
        // SAFETY: the caller keeps the documented readable range live for this copy.
        unsafe { slice::from_raw_parts(ptr, len) }.to_vec()
    };
    runtime.dispatch(handle, frame)
}

/// Cancels a session tree and wakes every idle session thread.
#[unsafe(no_mangle)]
pub extern "C" fn dmn_cancel(handle: i64) -> i64 {
    RUNTIME.get().map_or(-1, |runtime| runtime.cancel(handle))
}

/// Requests shutdown, then cancels the session tree.
#[unsafe(no_mangle)]
pub extern "C" fn dmn_close(handle: i64) -> i64 {
    RUNTIME.get().map_or(-1, |runtime| runtime.close(handle))
}

/// Returns the framed worker protocol version.
#[unsafe(no_mangle)]
pub extern "C" fn dmn_protocol_version() -> u32 {
    monty_proto::PROTOCOL_VERSION
}

#[cfg(test)]
mod tests {
    use std::{
        collections::BTreeSet,
        io::Cursor,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, AtomicUsize, Ordering},
            mpsc::{self, Receiver},
        },
        thread,
        time::{Duration, Instant},
    };

    use monty_proto::{FrameReader, PROTOCOL_VERSION, pb, write_frame};

    use super::{EXITED, OUTCOME_CONTINUE, OUTCOME_FATAL, Poster, Runtime};

    static TEST_LOCK: Mutex<()> = Mutex::new(());
    const RECV_TIMEOUT: Duration = Duration::from_secs(3);

    #[derive(Debug)]
    enum Posted {
        Frame(i64, Vec<u8>),
        Int(i64, i64),
    }

    struct ChannelPoster {
        accepting: AtomicBool,
        rejected: AtomicUsize,
        tx: mpsc::Sender<Posted>,
    }

    impl ChannelPoster {
        fn new() -> (Arc<Self>, Receiver<Posted>) {
            let (tx, rx) = mpsc::channel();
            (
                Arc::new(Self {
                    accepting: AtomicBool::new(true),
                    rejected: AtomicUsize::new(0),
                    tx,
                }),
                rx,
            )
        }

        fn set_accepting(&self, accepting: bool) {
            self.accepting.store(accepting, Ordering::Release);
        }

        fn wait_rejected(&self, count: usize) {
            let deadline = Instant::now() + RECV_TIMEOUT;
            while self.rejected.load(Ordering::Acquire) < count {
                assert!(Instant::now() < deadline, "timed out waiting for rejected posts");
                thread::yield_now();
            }
        }

        fn accept(&self, posted: Posted) -> bool {
            if self.accepting.load(Ordering::Acquire) {
                self.tx.send(posted).is_ok()
            } else {
                self.rejected.fetch_add(1, Ordering::Release);
                false
            }
        }
    }

    impl Poster for ChannelPoster {
        fn post_frame(&self, port: i64, frame: &[u8]) -> bool {
            self.accept(Posted::Frame(port, frame.to_vec()))
        }

        fn post_int(&self, port: i64, value: i64) -> bool {
            self.accept(Posted::Int(port, value))
        }
    }

    fn runtime(cap: i64) -> (Arc<Runtime>, Arc<ChannelPoster>, Receiver<Posted>) {
        let (poster, rx) = ChannelPoster::new();
        let runtime = Runtime::new(cap, poster.clone());
        (runtime, poster, rx)
    }

    fn request(kind: pb::parent_request::Kind) -> Vec<u8> {
        let mut frame = Vec::new();
        write_frame(
            &mut frame,
            &pb::ParentRequest {
                kind: Some(kind),
                trace_parent: None,
            },
        )
        .unwrap();
        frame
    }

    fn configure(memory: u64, recursion: u64, turn_micros: Option<u64>) -> Vec<u8> {
        request(pb::parent_request::Kind::Configure(pb::Configure {
            script_name: "inproc.py".to_owned(),
            protocol_version: PROTOCOL_VERSION,
            limits: Some(pb::ResourceLimits {
                max_memory_bytes: Some(memory),
                max_recursion_depth: Some(recursion),
                max_turn_duration_micros: turn_micros,
                ..Default::default()
            }),
            ..Default::default()
        }))
    }

    fn feed(code: &str) -> Vec<u8> {
        request(pb::parent_request::Kind::Feed(pb::Feed {
            code: code.to_owned(),
            cwd: "/".to_owned(),
            ..Default::default()
        }))
    }

    fn shutdown() -> Vec<u8> {
        request(pb::parent_request::Kind::Shutdown(pb::Shutdown {}))
    }

    fn decode(frame: Vec<u8>) -> pb::ChildEvent {
        FrameReader::new(Cursor::new(frame)).read().unwrap().unwrap()
    }

    fn recv(rx: &Receiver<Posted>) -> Posted {
        rx.recv_timeout(RECV_TIMEOUT).expect("session reply")
    }

    fn turn(runtime: &Runtime, handle: i64, port: i64, frame: Vec<u8>, rx: &Receiver<Posted>) -> Vec<pb::ChildEvent> {
        assert_eq!(runtime.dispatch(handle, frame), 0);
        let mut events = Vec::new();
        loop {
            match recv(rx) {
                Posted::Frame(found_port, frame) => {
                    assert_eq!(found_port, port);
                    events.push(decode(frame));
                }
                Posted::Int(found_port, value) => {
                    assert_eq!(found_port, port);
                    assert_ne!(value, EXITED, "session exited before turn outcome");
                    assert_eq!(value, OUTCOME_CONTINUE);
                    break;
                }
            }
        }
        events
    }

    fn wait_exited(rx: &Receiver<Posted>, port: i64) {
        wait_exited_all(rx, &[port]);
    }

    fn wait_exited_all(rx: &Receiver<Posted>, ports: &[i64]) {
        let mut waiting: BTreeSet<_> = ports.iter().copied().collect();
        loop {
            if let Posted::Int(found_port, EXITED) = recv(rx) {
                waiting.remove(&found_port);
                if waiting.is_empty() {
                    return;
                }
            }
        }
    }

    fn configured(runtime: &Arc<Runtime>, port: i64, rx: &Receiver<Posted>, memory: u64, recursion: u64) -> i64 {
        let handle = runtime.open(port, i64::try_from(memory).unwrap(), 0);
        assert!(handle > 0);
        let events = turn(runtime, handle, port, configure(memory, recursion, None), rx);
        assert!(matches!(
            events.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Ok(_)),
                ..
            }]
        ));
        handle
    }

    #[test]
    fn panic_is_fatal_and_a_fresh_session_still_works() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(256 * 1024 * 1024);
        let handle = configured(&runtime, 1, &rx, 64 * 1024 * 1024, 1000);

        assert_eq!(runtime.panic(handle), 0);
        let mut fatal = 0;
        let mut saw_outcome = false;
        loop {
            match recv(&rx) {
                Posted::Frame(1, frame) => {
                    let event = decode(frame);
                    if matches!(event.kind, Some(pb::child_event::Kind::FatalError(_))) {
                        fatal += 1;
                    }
                }
                Posted::Int(1, OUTCOME_FATAL) => saw_outcome = true,
                Posted::Int(1, EXITED) => break,
                other => panic!("unexpected panic reply: {other:?}"),
            }
        }
        assert_eq!(fatal, 1);
        assert!(saw_outcome);

        let second = configured(&runtime, 2, &rx, 64 * 1024 * 1024, 1000);
        let events = turn(&runtime, second, 2, feed("1 + 1"), &rx);
        assert!(matches!(
            events.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Complete(_)),
                ..
            }]
        ));
        assert_eq!(runtime.close(second), 0);
        wait_exited(&rx, 2);
    }

    #[test]
    fn soft_memory_error_keeps_the_session_usable() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(64 * 1024 * 1024);
        let handle = configured(&runtime, 1, &rx, 16 * 1024 * 1024, 1000);

        let events = turn(&runtime, handle, 1, feed("\"x\" * 100000000"), &rx);
        assert!(matches!(
            events.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Error(_)),
                ..
            }]
        ));
        assert!(format!("{events:?}").contains("MemoryError"));
        let events = turn(&runtime, handle, 1, feed("2 + 2"), &rx);
        assert!(matches!(
            events.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Complete(_)),
                ..
            }]
        ));
        assert_eq!(runtime.close(handle), 0);
        wait_exited(&rx, 1);
    }

    #[test]
    fn deep_repr_uses_the_owned_thread_stack() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(512 * 1024 * 1024);
        let handle = configured(&runtime, 1, &rx, 256 * 1024 * 1024, 100_000_000);
        let events = turn(
            &runtime,
            handle,
            1,
            feed("x = 0\nfor _ in range(30000):\n    x = [x]\nrepr(x)"),
            &rx,
        );
        assert!(matches!(
            events.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Complete(_)),
                ..
            }]
        ));
        assert_eq!(runtime.close(handle), 0);
        wait_exited(&rx, 1);
    }

    #[test]
    fn cancel_during_execution_waits_for_the_duration_limit() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(128 * 1024 * 1024);
        let handle = runtime.open(1, 64 * 1024 * 1024, 0);
        assert!(handle > 0);
        let configured = turn(
            &runtime,
            handle,
            1,
            configure(64 * 1024 * 1024, 1000, Some(500_000)),
            &rx,
        );
        assert!(matches!(
            configured.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Ok(_)),
                ..
            }]
        ));

        let started = Instant::now();
        assert_eq!(runtime.dispatch(handle, feed("while True:\n    pass")), 0);
        thread::sleep(Duration::from_millis(50));
        let cancel_started = Instant::now();
        assert_eq!(runtime.cancel(handle), 0);
        assert!(cancel_started.elapsed() < Duration::from_millis(50));
        assert_eq!(runtime.dispatch(handle, feed("1 + 1")), -1);
        let mut duration_error = None;
        loop {
            match recv(&rx) {
                Posted::Frame(1, frame) => {
                    let event = decode(frame);
                    if let Some(pb::child_event::Kind::Error(error)) = event.kind {
                        duration_error = error.exception;
                    }
                }
                Posted::Int(1, EXITED) => break,
                Posted::Int(1, OUTCOME_CONTINUE) => {}
                other => panic!("unexpected cancel reply: {other:?}"),
            }
        }
        let duration_error = duration_error.expect("duration-limit error");
        assert_eq!(duration_error.exc_type, "TimeoutError");
        let message = duration_error.message.expect("duration-limit message");
        assert!(message.starts_with("turn time limit exceeded: "), "{message}");
        assert!(message.ends_with(" > 500ms"), "{message}");
        let elapsed = started.elapsed();
        assert!(
            elapsed >= Duration::from_millis(500),
            "exited too early after {elapsed:?}"
        );
        assert!(
            elapsed <= Duration::from_millis(1500),
            "exited too late after {elapsed:?}"
        );
    }

    #[test]
    fn cancelling_a_parent_cancels_its_tree() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(256 * 1024 * 1024);
        let parent = runtime.open(1, 64 * 1024 * 1024, 0);
        let first = runtime.open(2, 64 * 1024 * 1024, parent);
        let second = runtime.open(3, 64 * 1024 * 1024, parent);
        assert!(parent > 0 && first > 0 && second > 0);

        assert_eq!(runtime.cancel(parent), 0);
        assert_eq!(runtime.dispatch(first, Vec::new()), -1);
        assert_eq!(runtime.dispatch(second, Vec::new()), -1);
        assert_eq!(runtime.open(4, 1, parent), -2);
        wait_exited_all(&rx, &[1, 2, 3]);
    }

    #[test]
    fn parent_shutdown_cancels_live_children() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(256 * 1024 * 1024);
        let parent = configured(&runtime, 1, &rx, 64 * 1024 * 1024, 1000);
        let first = runtime.open(2, 64 * 1024 * 1024, parent);
        let second = runtime.open(3, 64 * 1024 * 1024, parent);
        assert!(first > 0 && second > 0);

        assert_eq!(runtime.dispatch(parent, shutdown()), 0);
        wait_exited_all(&rx, &[1, 2, 3]);
        assert_eq!(runtime.dispatch(first, Vec::new()), -1);
        assert_eq!(runtime.dispatch(second, Vec::new()), -1);
    }

    #[test]
    fn admission_is_released_only_when_a_session_exits() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, _poster, rx) = runtime(20);
        let first = runtime.open(1, 10, 0);
        let sibling = runtime.open(2, 10, 0);
        assert!(first > 0 && sibling > 0);
        assert_eq!(runtime.open(3, 1, 0), -1);

        assert_eq!(runtime.close(sibling), 0);
        wait_exited(&rx, 2);
        let replacement = runtime.open(3, 10, 0);
        assert!(replacement > 0);
        assert_eq!(runtime.close(first), 0);
        assert_eq!(runtime.close(replacement), 0);
        wait_exited_all(&rx, &[1, 3]);
    }

    #[test]
    fn a_rejected_post_drops_the_frame_without_ending_the_session() {
        let _test = TEST_LOCK.lock().unwrap();
        let (runtime, poster, rx) = runtime(128 * 1024 * 1024);
        let handle = configured(&runtime, 1, &rx, 64 * 1024 * 1024, 1000);

        poster.set_accepting(false);
        assert_eq!(runtime.dispatch(handle, feed("1 + 1")), 0);
        poster.wait_rejected(2);
        assert!(rx.try_recv().is_err());
        poster.set_accepting(true);
        let events = turn(&runtime, handle, 1, feed("2 + 2"), &rx);
        assert!(matches!(
            events.as_slice(),
            [pb::ChildEvent {
                kind: Some(pb::child_event::Kind::Complete(_)),
                ..
            }]
        ));
        assert_eq!(runtime.close(handle), 0);
        wait_exited(&rx, 1);
    }
}
