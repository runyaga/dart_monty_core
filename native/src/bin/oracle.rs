//! Oracle binary — runs Python code via the Monty crate and emits JSON.
//!
//! Source of truth for the FFI conformance test suite (`oracle_ffi_test.dart`).
//!
//! Usage: echo "1 + 1" | oracle
//!
//! stdin  → Python code snippet
//! stdout → one JSON line (same schema as the FFI handle's result JSON)
//! stderr → empty (all errors encoded in the JSON output)
//! exit   → always 0 (Python errors are encoded in JSON, not exit code)
//!
//! The JSON schema mirrors `build_result_json` in `handle.rs`:
//! ```json
//! {
//!   "value": <MontyObject as JSON>,
//!   "usage": {"memory_bytes_used": 0, "time_elapsed_ms": 0, "stack_depth_used": 0},
//!   "print_output": "...",   // omitted when empty
//!   "error": { ... }         // omitted on success
//! }
//! ```
//!
//! `NoLimitTracker` is used so the oracle never diverges from Dart's default
//! execution (which uses its own resource tracker independently).

use std::io::{self, Read};

use monty::{MontyException, MontyRun, NoLimitTracker, PrintWriter};
use serde_json::{Value, json};

// Re-use the crate's MontyObject → JSON conversion directly.
// convert.rs only imports external crates (monty, num_bigint, num_traits, serde_json)
// so it compiles cleanly as an included path module with no changes.
// dead_code fires on the items inside convert.rs (not the mod item itself), so
// #[expect] would always be "unfulfilled"; suppress allow_attributes for this one site.
#[allow(clippy::allow_attributes)]
#[allow(dead_code)]
#[path = "../convert.rs"]
mod convert;

fn main() {
    let mut code = String::new();
    io::stdin()
        .read_to_string(&mut code)
        .expect("failed to read stdin");
    let result = run_oracle(&code);
    println!("{}", serde_json::to_string(&result).unwrap());
}

fn run_oracle(code: &str) -> Value {
    let mut print_buf = String::new();
    let runner = match MontyRun::new(code.to_owned(), "oracle.py", vec![]) {
        Ok(r) => r,
        Err(e) => return build_error_json(&e, &print_buf),
    };
    match runner.run(
        vec![],
        NoLimitTracker,
        PrintWriter::CollectString(&mut print_buf),
    ) {
        Ok(value) => {
            let mut result = json!({
                "value": convert::monty_object_to_json(&value),
                "usage": {
                    "memory_bytes_used": 0,
                    "time_elapsed_ms": 0,
                    "stack_depth_used": 0,
                },
            });
            if !print_buf.is_empty() {
                result
                    .as_object_mut()
                    .unwrap()
                    .insert("print_output".into(), json!(print_buf));
            }

            result
        }
        Err(e) => build_error_json(&e, &print_buf),
    }
}

fn build_error_json(e: &MontyException, print_buf: &str) -> Value {
    let mut result = json!({
        "value": Value::Null,
        "usage": {
            "memory_bytes_used": 0,
            "time_elapsed_ms": 0,
            "stack_depth_used": 0,
        },
        "error": exception_to_json(e),
    });
    if !print_buf.is_empty() {
        result
            .as_object_mut()
            .unwrap()
            .insert("print_output".into(), json!(print_buf));
    }

    result
}

/// Mirrors `monty_exception_to_json` in `error.rs` exactly.
fn exception_to_json(e: &MontyException) -> Value {
    let mut obj = json!({
        "message": e.message().unwrap_or(""),
        "exc_type": e.exc_type().to_string(),
    });
    let map = obj.as_object_mut().unwrap();
    let traceback = e.traceback();

    if let Some(frame) = traceback.last() {
        map.insert("filename".into(), json!(frame.filename));
        map.insert("line_number".into(), json!(frame.start.line));
        map.insert("column_number".into(), json!(frame.start.column));
        if let Some(ref preview) = frame.preview_line {
            map.insert("source_code".into(), json!(preview));
        }
    }

    if !traceback.is_empty() {
        let frames: Vec<Value> = traceback
            .iter()
            .map(|frame| {
                let mut f = json!({
                    "filename": frame.filename,
                    "start_line": frame.start.line,
                    "start_column": frame.start.column,
                    "end_line": frame.end.line,
                    "end_column": frame.end.column,
                });
                let fm = f.as_object_mut().unwrap();
                if let Some(ref name) = frame.frame_name {
                    fm.insert("frame_name".into(), json!(name));
                }
                if let Some(ref preview) = frame.preview_line {
                    fm.insert("preview_line".into(), json!(preview));
                }
                if frame.hide_caret {
                    fm.insert("hide_caret".into(), json!(true));
                }
                if frame.hide_frame_name {
                    fm.insert("hide_frame_name".into(), json!(true));
                }
                f
            })
            .collect();
        map.insert("traceback".into(), json!(frames));
    }

    obj
}
