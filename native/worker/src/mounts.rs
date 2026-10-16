//! Host-side monty-fs bridge. No interpreter runs here. With the process
//! channel, sessions have separate allocator counters. ARCH1a must isolate
//! this service from an in-process interpreter's LimitedAllocator (d10).
//!
//! ABI ownership: input pointers are borrowed for one synchronous call. Output
//! buffers belong to Rust until dmfs_free(pointer, length). Handles are positive
//! process-global IDs; zero and negative values are never handles. Errors are
//! thread-local and remain valid until the next failing call on that thread.

use std::{
    cell::RefCell,
    collections::HashMap,
    ffi::c_void,
    mem,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice, str,
    sync::{LazyLock, Mutex},
};

use monty_fs::{Mount, MountCallOutcome, MountError, MountMode, MountRoot, MountTable};
use monty_proto::{decode_frame, ext_result_to_proto, os_call_from_proto, pb};
use monty_types::ExtFunctionResult;
use prost::Message;

struct RootEntry {
    root: Option<MountRoot>,
    virtual_path: String,
    mode: String,
    write_limit: Option<u64>,
    memory_limit: u64,
}

#[derive(Default)]
struct State {
    next: i64,
    roots: HashMap<i64, RootEntry>,
    tables: HashMap<i64, MountTable>,
}

impl State {
    fn id(&mut self) -> Result<i64, String> {
        self.next = self.next.checked_add(1).ok_or("mount handle space exhausted")?;
        Ok(self.next)
    }
}

static STATE: LazyLock<Mutex<State>> = LazyLock::new(|| Mutex::new(State::default()));
/// Borrowed UTF-8, including embedded NULs. Valid until the call returns (or,
/// for last_error, until the next failed call on the same thread).
#[repr(C)]
#[derive(Default)]
pub(crate) struct MountString {
    pub(crate) data: *const u8,
    pub(crate) len: usize,
}

#[derive(Default)]
struct ErrorMessage {
    bytes: Vec<u8>,
    view: MountString,
}

thread_local! {
    static ERROR: RefCell<ErrorMessage> = RefCell::new(ErrorMessage::default());
}

fn attempt(f: impl FnOnce() -> Result<i64, String>) -> i64 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(value)) => value,
        outcome => {
            let message = match outcome {
                Ok(Err(message)) => message,
                _ => "native mount service panicked".to_owned(),
            };
            ERROR.with(|error| {
                error.borrow_mut().bytes = message.into_bytes();
            });
            -1
        }
    }
}

fn mount_error(error: MountError) -> String {
    // The Python binding exposes the exception message, not MountError's
    // diagnostic Display (which adds "invalid mount:" / "overlapping mounts:").
    error.into_exception().message().unwrap_or_default().to_owned()
}

unsafe fn text<'a>(ptr: *const MountString) -> Result<&'a str, String> {
    if ptr.is_null() {
        return Err("null mount string".to_owned());
    }
    // SAFETY: the ABI caller supplies a live string descriptor and len readable
    // bytes. Empty strings may carry null data, which is never dereferenced.
    let view = unsafe { &*ptr };
    let bytes = if view.len == 0 {
        &[]
    } else {
        if view.data.is_null() {
            return Err("null mount string data".to_owned());
        }
        // SAFETY: the caller owns this borrowed buffer until return.
        unsafe { slice::from_raw_parts(view.data, view.len) }
    };
    str::from_utf8(bytes).map_err(|e| e.to_string())
}

unsafe fn output(bytes: Vec<u8>, ptr: *mut *mut u8, len: *mut usize) -> Result<i64, String> {
    if ptr.is_null() || len.is_null() {
        return Err("null mount output".to_owned());
    }
    let mut bytes = bytes.into_boxed_slice();
    // SAFETY: the caller supplies writable output slots; the boxed slice is
    // leaked to the caller and reclaimed only by dmfs_free with this length.
    unsafe {
        *len = bytes.len();
        *ptr = bytes.as_mut_ptr();
    }
    mem::forget(bytes);
    Ok(1)
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn dmfs_open(
    virtual_path: *const MountString,
    host: *const MountString,
    mode: *const MountString,
    write_limit: i64,
    memory_limit: u64,
) -> i64 {
    attempt(|| {
        // SAFETY: all three strings are borrowed from the synchronous ABI caller.
        let (virtual_path, host, mode) = unsafe { (text(virtual_path)?, text(host)?, text(mode)?) };
        MountMode::from_mode_str(mode)?;
        let root = MountRoot::open(virtual_path, host).map_err(mount_error)?;
        let mut state = STATE.lock().map_err(|e| e.to_string())?;
        let id = state.id()?;
        state.roots.insert(
            id,
            RootEntry {
                virtual_path: root.virtual_path().to_owned(),
                root: Some(root),
                mode: mode.to_owned(),
                write_limit: if write_limit < 0 {
                    None
                } else {
                    Some(write_limit.cast_unsigned())
                },
                memory_limit,
            },
        );
        Ok(id)
    })
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn dmfs_root_info(id: i64, ptr: *mut *mut u8, len: *mut usize) -> i64 {
    attempt(|| {
        let state = STATE.lock().map_err(|e| e.to_string())?;
        let entry = state.roots.get(&id).ok_or("unknown mount root")?;
        let root = entry
            .root
            .as_ref()
            .ok_or_else(|| format!("mount '{}' is closed", entry.virtual_path))?;
        let mut bytes = root.host_path().to_string_lossy().as_bytes().to_vec();
        bytes.push(0);
        bytes.extend_from_slice(root.virtual_path().as_bytes());
        // SAFETY: output slots are supplied by the caller.
        unsafe { output(bytes, ptr, len) }
    })
}

#[unsafe(no_mangle)]
pub(crate) extern "C" fn dmfs_close(id: i64) {
    if let Ok(mut state) = STATE.lock()
        && let Some(entry) = state.roots.get_mut(&id)
    {
        entry.root = None;
    }
}

// NativeFinalizer's ABI takes a void pointer, not an integer. The pointer is
// only an opaque encoding of the handle, and is never dereferenced.
#[unsafe(no_mangle)]
pub(crate) extern "C" fn dmfs_finalize(token: *mut c_void) {
    if let Ok(id) = i64::try_from(token as usize)
        && let Ok(mut state) = STATE.lock()
    {
        // Release the descriptor (if still open) and the closed-root label.
        state.roots.remove(&id);
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn dmfs_begin_feed(ids: *const i64, count: usize) -> i64 {
    attempt(|| {
        let ids = if count == 0 {
            &[]
        } else {
            if ids.is_null() {
                return Err("null mount handles".to_owned());
            }
            // SAFETY: caller supplies count live i64 handles.
            unsafe { slice::from_raw_parts(ids, count) }
        };
        let mut state = STATE.lock().map_err(|e| e.to_string())?;
        let mut table = MountTable::new();
        for id in ids {
            let root = state.roots.get(id).ok_or("mount root is closed")?;
            let mount = Mount::with_root(
                root.root
                    .as_ref()
                    .ok_or_else(|| format!("mount '{}' is closed", root.virtual_path))?
                    .clone(),
                MountMode::from_mode_str(&root.mode)?,
                root.write_limit,
            )
            .with_memory_usage_limit(root.memory_limit);
            table.push_mount(mount).map_err(mount_error)?;
        }
        let id = state.id()?;
        state.tables.insert(id, table);
        Ok(id)
    })
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn dmfs_call(
    id: i64,
    bytes: *const u8,
    size: usize,
    ptr: *mut *mut u8,
    len: *mut usize,
) -> i64 {
    attempt(|| {
        if bytes.is_null() {
            return Err("null OS call".to_owned());
        }
        // SAFETY: caller supplies size readable bytes, live until return.
        let bytes = unsafe { slice::from_raw_parts(bytes, size) };
        let call = decode_frame::<pb::OsCall>(bytes).map_err(|e| e.to_string())?;
        let (call_id, call) = os_call_from_proto(call).map_err(|e| e.to_string())?;
        let mut state = STATE.lock().map_err(|e| e.to_string())?;
        let table = state.tables.get_mut(&id).ok_or("mount table is closed")?;
        let result = match table.handle_os_call(call) {
            MountCallOutcome::NotHandled(_) => return Ok(0),
            MountCallOutcome::Handled(Ok(value)) => ExtFunctionResult::Return(value),
            MountCallOutcome::Handled(Err(error)) => ExtFunctionResult::Error(error.into_exception()),
        };
        let (result, values) = ext_result_to_proto(result);
        let reply = pb::ResumeCall {
            call_id,
            result: Some(result),
            values,
        };
        // SAFETY: caller supplies writable output slots.
        unsafe { output(reply.encode_to_vec(), ptr, len) }
    })
}

#[unsafe(no_mangle)]
pub(crate) extern "C" fn dmfs_end_feed(id: i64) {
    if let Ok(mut state) = STATE.lock() {
        state.tables.remove(&id);
    }
}

#[unsafe(no_mangle)]
pub(crate) unsafe extern "C" fn dmfs_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        // SAFETY: caller returns exactly the allocation and length from output,
        // once only, after it has stopped accessing the buffer.
        unsafe { drop(Box::from_raw(ptr::slice_from_raw_parts_mut(ptr, len))) };
    }
}

#[unsafe(no_mangle)]
pub(crate) extern "C" fn dmfs_last_error() -> *const MountString {
    ERROR.with(|error| {
        let mut error = error.borrow_mut();
        error.view = MountString {
            data: error.bytes.as_ptr(),
            len: error.bytes.len(),
        };
        ptr::from_ref(&error.view)
    })
}
