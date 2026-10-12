//! Writes OUTDIR/<probe>/ref-rust.json for the Rust-only parity probes, in the
//! event vocabulary of tool/parity/oracle/run_probes.py.
use std::{env, fs, path::Path};

use monty::{MontyRun, ReplContinuationMode, detect_repl_continuation_mode};
use monty_types::CompileOptions;
use serde_json::{Value, json};

/// The sources the continuation probe classifies (same list as api_probes.dart).
const CONTINUATION_SOURCES: [&str; 14] = [
    "x = 1",
    "def f():",
    "def f():\n    return 1",
    "def f():\n    return 1\n",
    "(1,",
    "[1, 2",
    "x = (",
    "if True:\n    pass\n",
    "s = '''abc",
    "1 +",
    "x = )",
    "",
    "for i in range(3):",
    "class A:\n    x = 1\n\n",
];

fn mode(m: ReplContinuationMode) -> &'static str {
    match m {
        ReplContinuationMode::Complete => "complete",
        ReplContinuationMode::IncompleteImplicit => "incompleteImplicit",
        ReplContinuationMode::IncompleteBlock => "incompleteBlock",
    }
}

fn write(out: &Path, probe: &str, events: Vec<Value>) {
    let dir = out.join(probe);
    fs::create_dir_all(&dir).expect("create probe dir");
    let doc = json!({"probe": probe, "engine": "ref-rust", "backend": "rust", "events": events, "runner_error": null});
    let text = serde_json::to_string_pretty(&doc).expect("encode") + "\n";
    fs::write(dir.join("ref-rust.json"), text).expect("write outcome");
}

fn main() {
    let out = env::args()
        .nth(1)
        .expect("usage: parity-rust-oracle OUTDIR");
    let out = Path::new(&out);

    let modes = CONTINUATION_SOURCES
        .iter()
        .map(|s| json!({"ev": "mode", "src": s, "mode": mode(detect_repl_continuation_mode(s))}))
        .collect();
    write(out, "api_interactive_continuation", modes);

    let compiled = MontyRun::new(
        "x = 1\nx + 1".to_string(),
        "main.py",
        vec![],
        CompileOptions::default(),
    );
    let ev = if compiled.is_ok() {
        json!({"ev": "compiled"})
    } else {
        json!({"ev": "compile_error"})
    };
    write(out, "api_compile_program", vec![ev]);

    let run = MontyRun::new(
        "x * 2".to_string(),
        "main.py",
        vec!["x".to_string()],
        CompileOptions::default(),
    )
    .expect("compile x * 2");
    write(
        out,
        "api_compiled_source",
        vec![json!({"ev": "code", "code": run.code()})],
    );
}
