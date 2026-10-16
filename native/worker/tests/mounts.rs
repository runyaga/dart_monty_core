//! ABI lifetime/error plumbing, independent of the Dart behavioral oracle tests.
#![expect(unsafe_code, reason = "exercise the internal C ABI with owned buffers")]

#[path = "../src/mounts.rs"]
mod service;

use std::{env, ptr, slice, thread};

use monty_proto::pb;
use prost::Message;

use service::{
    MountString, dmfs_begin_feed, dmfs_call, dmfs_close, dmfs_end_feed, dmfs_finalize, dmfs_free, dmfs_last_error,
    dmfs_open, dmfs_root_info,
};

fn text(value: &str) -> MountString {
    MountString {
        data: value.as_ptr(),
        len: value.len(),
    }
}

fn error() -> String {
    // SAFETY: last_error returns a live thread-local view, unchanged until the
    // next failed call on this thread.
    let message = unsafe { &*dmfs_last_error() };
    // SAFETY: the view describes message.len readable bytes.
    String::from_utf8(unsafe { slice::from_raw_parts(message.data, message.len) }.to_vec()).unwrap()
}

fn open_call(virtual_path: &str, host: &str, mode: &str) -> i64 {
    // SAFETY: descriptors and their UTF-8 buffers are live until return.
    unsafe {
        dmfs_open(
            ptr::from_ref(&text(virtual_path)),
            ptr::from_ref(&text(host)),
            ptr::from_ref(&text(mode)),
            -1,
            100_000_000,
        )
    }
}

fn open() -> i64 {
    let host = env::current_dir().unwrap();
    let id = open_call("/m", host.to_str().unwrap(), "overlay");
    assert!(id > 0, "{}", error());
    id
}

fn call_exists(table: i64) -> i64 {
    let call = pb::OsCall {
        call: Some(pb::os_call::Call::Exists("/m".to_owned())),
        ..Default::default()
    }
    .encode_to_vec();
    let mut output = ptr::null_mut();
    let mut length = 0;
    // SAFETY: the input buffer and output slots remain live until return.
    let status = unsafe { dmfs_call(table, call.as_ptr(), call.len(), &raw mut output, &raw mut length) };
    if status == 1 {
        // SAFETY: return the service's allocation exactly once.
        unsafe { dmfs_free(output, length) };
    }
    status
}

#[test]
fn close_retains_label_and_table_capability_until_finalization() {
    let id = open();
    // SAFETY: id is one live handle; the input slice is borrowed for this call.
    let table = unsafe { dmfs_begin_feed(&raw const id, 1) };
    assert!(table > 0, "{}", error());
    dmfs_close(id);
    dmfs_close(id);
    // SAFETY: closed is a valid state of an allocated root handle.
    assert_eq!(unsafe { dmfs_begin_feed(&raw const id, 1) }, -1);
    assert_eq!(error(), "mount '/m' is closed");
    assert_eq!(call_exists(table), 1, "the existing table keeps its root clone");
    dmfs_end_feed(table);
    dmfs_end_feed(table);
    assert_eq!(call_exists(table), -1);
    assert_eq!(error(), "mount table is closed");
    dmfs_finalize(ptr::without_provenance_mut(usize::try_from(id).unwrap()));
    // SAFETY: unknown handles must be refused, not dereferenced.
    assert_eq!(unsafe { dmfs_begin_feed(&raw const id, 1) }, -1);
}

#[test]
fn root_info_buffer_round_trip_and_free() {
    let id = open();
    let mut output = ptr::null_mut();
    let mut len = 0;
    // SAFETY: writable pointer/length slots are live until return.
    assert_eq!(unsafe { dmfs_root_info(id, &raw mut output, &raw mut len) }, 1);
    // SAFETY: the service returned exactly len readable bytes.
    let info = unsafe { slice::from_raw_parts(output, len) };
    let expected = format!("{}\0/m", env::current_dir().unwrap().canonicalize().unwrap().display());
    assert_eq!(info, expected.as_bytes());
    // SAFETY: return the allocation exactly once, with the returned length.
    unsafe { dmfs_free(output, len) };
    dmfs_finalize(ptr::without_provenance_mut(usize::try_from(id).unwrap()));
}

#[test]
fn null_inputs_are_refused() {
    assert_eq!(
        // SAFETY: these null pointers intentionally test the ABI's explicit guards.
        unsafe {
            dmfs_open(
                ptr::null(),
                ptr::from_ref(&text(".")),
                ptr::from_ref(&text("overlay")),
                -1,
                0,
            )
        },
        -1
    );
    assert_eq!(error(), "null mount string");
    // SAFETY: a nonempty count with null input is explicitly refused.
    assert_eq!(unsafe { dmfs_begin_feed(ptr::null(), 1) }, -1);
    assert_eq!(error(), "null mount handles");
    // SAFETY: a zero count borrows no storage, so null is accepted.
    let table = unsafe { dmfs_begin_feed(ptr::null(), 0) };
    assert!(table > 0);
    dmfs_end_feed(table);
}

#[test]
fn last_error_is_thread_local() {
    let threads: Vec<_> = (0..8)
        .map(|i| {
            thread::spawn(move || {
                let mode = format!("bad-{i}");
                assert_eq!(open_call("/m", ".", &mode), -1);
                thread::yield_now();
                assert_eq!(
                    error(),
                    format!("Invalid mode 'bad-{i}', expected 'read-only', 'read-write', or 'overlay'")
                );
            })
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
}
