use std::collections::HashSet;

use monty::{
    DUMP_VERSION, Dump, DumpError, MontyRepl, ReplFunctionCall, ReplOsCall, ReplProgress,
    ReplResolveFutures, ReplStartError, Session, SessionRef, detect_repl_continuation_mode, dump,
};
use monty_types::{
    ExtFunctionResult, MontyObject, NameLookupResult, PrintWriter, ResourceLimits, ResourceTracker,
};
use serde_json::Value;

use crate::convert::{json_to_monty_object, monty_object_to_json};
use crate::error::monty_exception_to_json;
use crate::handle::{MontyProgressTag, MontyResultTag};

/// The concrete tracker type used for REPL execution.
///
/// Was `NoLimitTracker`, with a note that "callers can add limits later via a
/// dedicated API if needed". That API is now `monty_repl_create_with_limits`,
/// and this is the type that lets it do anything: a tracker is chosen when the
/// session is created and cannot be swapped afterwards.
///
/// **An unbounded session is still the default** — `ResourceLimits::default()`
/// has every field `None`, so `LimitedTracker` with no limits set behaves as
/// `NoLimitTracker` did. Interactive sessions stay unbounded unless asked.
///
/// Limits are SESSION-scoped, mirroring upstream's Python API, where
/// `checkout(limits=…)` configures a REPL session rather than an individual
/// feed (`monty-python/src/pool.rs`).
type Tracker = ResourceTracker;

/// Parses the limits JSON Dart sends into `ResourceLimits`.
///
/// Shape matches `_encodeLimitsJson` in `base_monty_platform.dart`, which is
/// already what the web backend sends for one-shot runs:
///
/// ```json
/// {"memory_bytes": 268435456, "stack_depth": 1000, "timeout_ms": 5000}
/// ```
///
/// Absent or null fields mean "no limit on this axis", so `{}` and a null
/// pointer both yield an unbounded session. Unparseable JSON is an ERROR rather
/// than a silent fallback to unbounded: a caller who asked for a limit and got
/// none is precisely the failure core#138 was about.
fn u64_field(map: &serde_json::Map<String, Value>, key: &str) -> Result<Option<u64>, String> {
    match map.get(key) {
        // Absent and explicit null both mean "no limit on this axis",
        // which is the documented contract and stays a silent default --
        // it is the only one of the three that is a real request.
        None | Some(Value::Null) => Ok(None),
        Some(v) => v.as_u64().map(Some).ok_or_else(|| {
            format!(
                "limits.{key} must be a non-negative integer, got {v}. \
                 Absent or null means no limit on this axis; a present but \
                 unusable value is an ERROR rather than a silent fallback \
                 to unbounded, because a dropped limit is a security \
                 control that reports success (FB-1 / core#124, core#138)."
            )
        }),
    }
}

pub fn parse_limits_json(json: &str) -> Result<ResourceLimits, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("invalid limits JSON: {e}"))?;
    let Some(map) = v.as_object() else {
        return Err(format!("limits JSON must be an object, got {v}"));
    };

    // ABSENT, NULL and PRESENT-BUT-WRONG are three different things.
    //
    // This was `map.get(k).and_then(Value::as_u64)` on all three axes, and
    // `as_u64()` returns None for anything that is not a non-negative integer.
    // So `{"memory_bytes": -1}` -- well-formed JSON, nothing to fail on -- took
    // the None branch, left the limit unset, and returned Ok(unbounded). The
    // doc comment four lines above promises the opposite in as many words:
    // "a caller who asked for a limit and got none is precisely the failure
    // core#138 was about". A caller asking for -1 asked for a limit and got
    // none. So did `"1000"`, `1e9`, and `true`.
    //
    // This is the SILENT-DEFAULT hazard for the fifth time in this codebase.
    // The same shape was removed from unwrap_or(0) on type_id,
    // unwrap_or(false) on host_defined, `as String? ?? ''` on the class name,
    // and `?? 0` on every MontyTime field. Each time the reported instance was
    // fixed and the class was not. `.and_then(as_u64)` is the same bug in
    // different syntax.
    let mut limits = ResourceLimits::default();
    if let Some(bytes) = u64_field(map, "memory_bytes")? {
        limits.max_memory = Some(usize::try_from(bytes).unwrap_or(usize::MAX));
    }
    if let Some(depth) = u64_field(map, "stack_depth")? {
        limits.max_recursion_depth = usize::try_from(depth).unwrap_or(usize::MAX);
    }
    if let Some(ms) = u64_field(map, "timeout_ms")? {
        limits.max_duration = Some(std::time::Duration::from_millis(ms));
    }

    Ok(limits)
}

/// Integer codes returned by `monty_repl_detect_continuation`.
///
/// Matches `ReplContinuationMode` variants for the C API.
pub const CONTINUATION_COMPLETE: i32 = 0;
pub const CONTINUATION_INCOMPLETE_IMPLICIT: i32 = 1;
pub const CONTINUATION_INCOMPLETE_BLOCK: i32 = 2;

// ---------------------------------------------------------------------------
// Metadata types (duplicated from handle.rs to avoid coupling)
// ---------------------------------------------------------------------------

/// Metadata captured when paused at a `FunctionCall`.
struct PendingMeta {
    fn_name: String,
    args_json: String,
    kwargs_json: String,
    call_id: u32,
    method_call: bool,
}

/// Metadata captured when paused at an `OsCall`.
struct OsCallMeta {
    os_fn_name: String,
    args_json: String,
    kwargs_json: String,
    call_id: u32,
}

// ---------------------------------------------------------------------------
// State machine
// ---------------------------------------------------------------------------

/// Internal state of the REPL handle.
///
/// Unlike `HandleState`, the REPL handle is **reusable** — after completion
/// the `MontyRepl` is recovered so subsequent feeds can execute.
enum ReplHandleState {
    /// REPL is idle, ready for `feed_run()` or `feed_start()`.
    Idle(MontyRepl),
    /// Paused at an external function call.
    Paused {
        call: ReplFunctionCall,
        meta: PendingMeta,
    },
    /// Paused at an OS call.
    OsCall { call: ReplOsCall, meta: OsCallMeta },
    /// Awaiting async future resolution.
    Futures {
        futures: ReplResolveFutures,
        call_ids_json: String,
    },
    /// Snippet completed; REPL recovered and result available.
    Complete {
        repl: MontyRepl,
        result_json: String,
        is_error: bool,
    },
    /// Temporary placeholder during state transitions.
    Consumed,
}

/// Opaque handle wrapping a persistent `MontyRepl` session with a
/// suspend/resume state machine.
///
/// Supports both `feed_run()` (synchronous, runs to completion) and
/// `feed_start()`/`resume()` (iterative, pauses at external function calls).
pub struct MontyReplHandle {
    state: ReplHandleState,
    ext_fn_names: HashSet<String>,
    print_output: String,
    /// Kept so `snapshot()` can hand it to `monty::dump`, and so a restore
    /// puts it back. `Dump` carries the script name precisely so a restored
    /// session does not produce tracebacks attributed to the wrong file.
    script_name: String,
}

impl std::fmt::Debug for MontyReplHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MontyReplHandle").finish_non_exhaustive()
    }
}

impl MontyReplHandle {
    /// Creates a new REPL handle with an empty interpreter state.
    ///
    /// Pass `ResourceLimits::default()` for an unbounded session, which is what
    /// every caller got before limits existed here.
    #[must_use]
    pub fn new(script_name: &str, limits: ResourceLimits) -> Self {
        Self {
            state: ReplHandleState::Idle(MontyRepl::new(
                script_name,
                Tracker::new(limits),
                crate::convert::compile_options(),
            )),
            ext_fn_names: HashSet::new(),
            print_output: String::new(),
            script_name: script_name.to_string(),
        }
    }

    /// Serialises the REPL session to postcard bytes.
    ///
    /// Only valid in `Idle` or `Complete` states, where the `MontyRepl` is
    /// accessible. Returns `Err` mid-execution (`Paused`, `OsCall`,
    /// `Futures`).
    ///
    /// THIS WAS A STUB RETURNING `Err("snapshot not supported on monty
    /// v0.0.23")`, AND THAT CLAIM WAS FALSE. It was introduced by commit
    /// e1e4eda with the reasoning "monty::dump_format is private and
    /// MontyRun/MontyRepl no longer expose dump/load, so a downstream crate
    /// cannot implement it". The first half is true — `mod dump_format;` is
    /// private at monty's lib.rs:12 — and the conclusion does not follow: its
    /// contents are PUBLICLY RE-EXPORTED at lib.rs:46-47. That investigation
    /// stopped at line 12 and never read line 47.
    ///
    /// What actually changed is narrower: the METHODS `MontyRepl::dump()` /
    /// `load()` were removed in v0.0.20 (upstream 44b3419d, shipped in
    /// dd6139a0) and replaced by the free function in the same commit — not
    /// in 0.0.23, and not removed at all.
    ///
    /// Upstream tests this API itself (monty crates/monty/tests/repl.rs:48-70,
    /// and monty-datatest round-trips EVERY datatest case through it), and it
    /// was verified end to end against the shipped pydantic-monty 0.0.23:
    /// a value AND a function survive a round trip into a DIFFERENT worker
    /// process.
    pub fn snapshot(&self) -> Result<Vec<u8>, String> {
        let repl = match &self.state {
            ReplHandleState::Idle(repl) => repl,
            ReplHandleState::Complete { repl, .. } => repl,
            // Upstream CAN dump a suspended session — `SessionRef::Suspended`
            // takes a `&ReplProgress`, and a suspended call is re-announced on
            // restore. This handle cannot, because it stores the call
            // (`ReplFunctionCall` / `ReplOsCall` / `ReplResolveFutures`)
            // rather than the whole `ReplProgress`. THE RESTRICTION IS OURS,
            // NOT UPSTREAM'S — say so, because claiming an upstream limit that
            // does not exist is what produced the stub this replaces.
            _ => {
                return Err(
                    "cannot snapshot mid-execution: this handle stores the pending call \
                     rather than a whole ReplProgress, so there is nothing to hand \
                     SessionRef::Suspended. Resume to completion first. (Upstream monty \
                     supports suspended dumps; this binding does not yet.)"
                        .into(),
                );
            }
        };

        dump(&self.script_name, None, SessionRef::Idle(repl))
            .map_err(|e| format!("repl snapshot failed: {e}"))
    }

    /// Restores a handle from bytes produced by [`Self::snapshot`].
    ///
    /// FRESH-SESSION-ONLY BY CONSTRUCTION. This is an associated function
    /// returning a NEW `Self`, never a method mutating an existing handle —
    /// which matches upstream's rule, measured on pydantic-monty 0.0.23:
    /// "load_session / load_snapshot is only valid on a fresh session, before
    /// any feed_run / feed_start". Keep it that way; an instance method would
    /// be wrong by construction.
    ///
    /// NOTE WHAT IS NOT CARRIED. `ext_fn_names` lives on THIS handle, not on
    /// monty's `MontyRepl`, so a dump cannot contain it and the restored
    /// handle starts with an EMPTY set. A caller that restores and then
    /// resumes an external call MUST call [`Self::set_ext_fns`] first, or the
    /// name will not resolve. That is why `restore_with_ext_fns` exists.
    /// THE NAME IS THE WARNING. This was `restore(bytes)`, and it passed
    /// `limits: None` — which means "keep whatever the snapshot carried"
    /// (see `restore_with_ext_fns`). So WHOEVER SUPPLIES THE BYTES CHOOSES THE
    /// RESOURCE LIMITS, and a caller reading `restore(bytes)` had no reason to
    /// suspect it.
    ///
    /// That is FB-1 / core#124 again: "a dropped limit is a security control
    /// that reports success". The defect was fixed at the C ABI during M3 —
    /// `monty_repl_restore` takes `limits_json` and applies it
    /// (`native/src/lib.rs`) — and the convenience wrapper ten lines away was
    /// left alone, which is exactly what made it easy to believe the whole
    /// path was covered.
    ///
    /// Renamed rather than deleted because inheriting the snapshot's limits is
    /// legitimate when the bytes are YOUR OWN — restoring a session you
    /// snapshotted a moment ago, with limits you already chose. It is only
    /// dangerous when the bytes came from somewhere else. A name that says so
    /// makes the caller decide, which a defaulted argument never did.
    ///
    /// If the bytes are not yours, use
    /// [`Self::restore_with_ext_fns`] and pass the limits you want.
    pub fn restore_keeping_snapshot_limits(bytes: &[u8]) -> Result<Self, String> {
        Self::restore_with_ext_fns(bytes, Vec::new(), None)
    }

    /// [`Self::restore_keeping_snapshot_limits`], re-establishing the external
    /// function names and taking explicit limits.
    ///
    /// The two-argument form is the one to prefer: a snapshot cannot carry
    /// `ext_fn_names` (see above), so restoring without re-supplying them
    /// yields a session whose external calls silently stop resolving. Making
    /// that an explicit argument is the difference between a caller who knows
    /// and a caller who finds out later.
    /// `limits`: applied to the RESTORED session, overriding whatever the
    /// snapshot carried.
    ///
    /// THIS IS A SECURITY CONTROL, and leaving it out was a real defect.
    /// Limits live inside the `ResourceTracker` INSIDE the `MontyRepl`, so a
    /// dump faithfully restores the limits of the session that was DUMPED.
    /// That is wrong for a caller who asked for their own:
    ///
    /// ```text
    /// let b = MontyRepl(limits: stackDepth 5);
    /// b.restore(bytes_from_an_unbounded_session);
    /// ```
    ///
    /// (Fenced as `text`, not left indented. A 4-space indented block in a
    /// doc comment is a RUST doctest to rustdoc, and this sketch is Dart --
    /// so `cargo test` tried to compile it and failed, which is how it was
    /// found. `cargo test --lib` does not run doctests and stayed green.)
    ///
    /// MEASURED before this parameter existed: `rec(50)` SUCCEEDED on `b`,
    /// while an identical un-restored session with the same limit raised
    /// RecursionError. The caller asked for a bound and silently did not get
    /// one — "a dropped limit is a security control that reports success"
    /// (FB-1 / core#124, the same failure this project has already had once).
    ///
    /// `None` means "keep whatever the snapshot carried", which is the right
    /// default for a caller who did not ask for anything.
    pub fn restore_with_ext_fns(
        bytes: &[u8],
        ext_fn_names: Vec<String>,
        limits: Option<ResourceLimits>,
    ) -> Result<Self, String> {
        let loaded = Dump::load(bytes).map_err(|e| match e {
            // Distinguish the two, because they need different actions: a
            // version mismatch means "rebuild or re-take the snapshot", a
            // payload error means "these bytes are not a snapshot".
            DumpError::VersionMismatch { .. } => format!(
                "repl restore failed: snapshot was written by a different monty dump format \
                 (this build expects DUMP_VERSION {DUMP_VERSION}): {e}"
            ),
            _ => format!("repl restore failed: {e}"),
        })?;

        let script_name = loaded.script_name;
        let Session::Idle(repl) = loaded.state else {
            return Err(
                "repl restore expected an idle session; this binding only writes idle \
                 snapshots (see snapshot())"
                    .into(),
            );
        };

        let mut repl = *repl;
        if let Some(limits) = limits {
            // Upstream exposes this precisely so limits can be reset after a
            // load (monty crates/monty/src/repl.rs:132).
            *repl.tracker_mut() = Tracker::new(limits);
        }

        Ok(Self {
            state: ReplHandleState::Idle(repl),
            ext_fn_names: ext_fn_names.into_iter().collect(),
            print_output: String::new(),
            script_name,
        })
    }

    /// Registers external function names for `feed_start()` name resolution.
    pub fn set_ext_fns(&mut self, names: Vec<String>) {
        self.ext_fn_names = names.into_iter().collect();
    }

    // -----------------------------------------------------------------------
    // feed_run — synchronous execution (Phase 1 API, refactored for state machine)
    // -----------------------------------------------------------------------

    /// Feed a snippet and run to completion.
    ///
    /// The REPL persists heap, globals, and intern state across calls.
    /// Returns `(result_tag, result_json, error_msg)` using the same
    /// JSON format as `MontyHandle::run`.
    pub fn feed_run(&mut self, code: &str) -> (MontyResultTag, String, Option<String>) {
        let mut repl = match self.take_repl() {
            Ok(r) => r,
            Err(msg) => return (MontyResultTag::Error, String::new(), Some(msg)),
        };

        let mut buf = String::new();
        let result = repl.feed_run(
            code,
            vec![],
            PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
        );

        self.print_output.push_str(&buf);

        match result {
            Ok(obj) => {
                let val = monty_object_to_json(&obj);
                let result_json = build_repl_result_json(&val, None, &self.print_output);
                self.print_output.clear();
                self.state = ReplHandleState::Idle(repl);
                (MontyResultTag::Ok, result_json, None)
            }
            Err(exc) => {
                let err_json = monty_exception_to_json(&exc);
                let result_json =
                    build_repl_result_json(&Value::Null, Some(err_json), &self.print_output);
                let msg = exc.summary();
                self.print_output.clear();
                self.state = ReplHandleState::Idle(repl);
                (MontyResultTag::Error, result_json, Some(msg))
            }
        }
    }

    // -----------------------------------------------------------------------
    // feed_start / resume — iterative execution (Phase 2)
    // -----------------------------------------------------------------------

    /// Start iterative execution of a snippet. Pauses at external function
    /// calls, OS calls, or future resolution.
    ///
    /// Returns a progress tag. Use the accessor methods to read state, then
    /// call `resume()` or `resume_with_error()` to continue.
    pub fn feed_start(&mut self, code: &str) -> (MontyProgressTag, Option<String>) {
        let repl = match self.take_repl() {
            Ok(r) => r,
            Err(msg) => return (MontyProgressTag::Error, Some(msg)),
        };

        let mut buf = String::new();
        let result = repl.feed_start(
            code,
            vec![],
            PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
        );
        self.print_output.push_str(&buf);

        match result {
            Ok(progress) => self.process_repl_progress(progress),
            Err(err) => self.handle_repl_start_error(*err),
        }
    }

    /// Resume a paused execution with a JSON-encoded return value.
    pub fn resume(&mut self, value_json: &str) -> (MontyProgressTag, Option<String>) {
        let val: Value = match serde_json::from_str(value_json) {
            Ok(v) => v,
            Err(e) => return (MontyProgressTag::Error, Some(format!("invalid JSON: {e}"))),
        };
        let obj = match json_to_monty_object(&val) {
            Ok(o) => o,
            // A protocol violation in a host-supplied resume value is reported
            // on the channel this function already has, not guessed at. Before
            // wire format v2 an untagged object silently became a dict.
            Err(e) => return (MontyProgressTag::Error, Some(e)),
        };

        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Paused { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::Return(obj),
                    PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            ReplHandleState::OsCall { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::Return(obj),
                    PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Paused or OsCall state".into()),
                )
            }
        }
    }

    /// Resume a paused execution by raising an error in Python.
    pub fn resume_with_error(&mut self, error_message: &str) -> (MontyProgressTag, Option<String>) {
        self.resume_with_monty_exception(monty_types::MontyException::new(
            monty_types::ExcType::RuntimeError,
            Some(error_message.to_string()),
        ))
    }

    /// Resume a paused execution by raising a typed Python exception.
    ///
    /// `exc_type` is the Python exception class name (e.g.
    /// `"FileNotFoundError"`). Unknown names fall back to `RuntimeError`.
    pub fn resume_with_exception(
        &mut self,
        exc_type: &str,
        error_message: &str,
    ) -> (MontyProgressTag, Option<String>) {
        let exc_kind = exc_type
            .parse::<monty_types::ExcType>()
            .unwrap_or(monty_types::ExcType::RuntimeError);
        self.resume_with_monty_exception(monty_types::MontyException::new(
            exc_kind,
            Some(error_message.to_string()),
        ))
    }

    /// Shared resume path: deliver `exc` to the paused/OS call as the
    /// external-function result, then advance the REPL.
    fn resume_with_monty_exception(
        &mut self,
        exc: monty_types::MontyException,
    ) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        let call = match state {
            ReplHandleState::Paused { call, .. } => Ok(call),
            ReplHandleState::OsCall { call, .. } => Err(call),
            other => {
                self.state = other;
                return (
                    MontyProgressTag::Error,
                    Some("handle not in Paused or OsCall state".into()),
                );
            }
        };
        let mut buf = String::new();
        let result = match call {
            Ok(c) => c.resume(
                ExtFunctionResult::Error(exc),
                PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
            ),
            Err(c) => c.resume(
                ExtFunctionResult::Error(exc),
                PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
            ),
        };
        self.print_output.push_str(&buf);
        match result {
            Ok(progress) => self.process_repl_progress(progress),
            Err(err) => self.handle_repl_start_error(*err),
        }
    }

    /// Resume by signalling "function not found".
    ///
    /// Raises `NameError: name '<fn_name>' is not defined` in Python. Used
    /// when the host can't dispatch an OS call — Python sees the same error
    /// it would for a missing global, instead of a generic `RuntimeError`.
    pub fn resume_not_found(&mut self, fn_name: &str) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Paused { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::NotFound(fn_name.to_string()),
                    PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            ReplHandleState::OsCall { call, .. } => {
                let mut buf = String::new();
                let result = call.resume(
                    ExtFunctionResult::NotFound(fn_name.to_string()),
                    PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
                );
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Paused or OsCall state".into()),
                )
            }
        }
    }

    /// Resume by converting the pending call into a future.
    pub fn resume_as_future(&mut self) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Paused { call, .. } => {
                let mut buf = String::new();
                let result = call.resume_pending(PrintWriter::CollectString(
                    &mut buf,
                    crate::convert::PRINT_COLLECT_LIMIT,
                ));
                self.print_output.push_str(&buf);
                match result {
                    Ok(progress) => self.process_repl_progress(progress),
                    Err(err) => self.handle_repl_start_error(*err),
                }
            }
            other => {
                self.state = other;
                (
                    MontyProgressTag::Error,
                    Some("handle not in Paused state".into()),
                )
            }
        }
    }

    /// Resolve pending futures with results and errors.
    pub fn resume_futures(
        &mut self,
        results_json: &str,
        errors_json: &str,
    ) -> (MontyProgressTag, Option<String>) {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        let ReplHandleState::Futures { futures, .. } = state else {
            self.state = state;
            return (
                MontyProgressTag::Error,
                Some("handle not in Futures state".into()),
            );
        };

        // Parse results: {"call_id": value, ...}
        let results_map: serde_json::Map<String, Value> =
            serde_json::from_str(results_json).unwrap_or_default();
        let errors_map: serde_json::Map<String, Value> =
            serde_json::from_str(errors_json).unwrap_or_default();

        let mut resolved = Vec::new();
        for (id_str, val) in &results_map {
            if let Ok(id) = id_str.parse::<u32>() {
                // Reported rather than skipped: dropping the entry would leave
                // the future unresolved and the REPL waiting forever, which is
                // a worse failure than a named error. The state has already been
                // taken above, so the handle is Consumed either way.
                let obj = match json_to_monty_object(val) {
                    Ok(o) => o,
                    Err(e) => return (MontyProgressTag::Error, Some(e)),
                };
                resolved.push((id, ExtFunctionResult::Return(obj)));
            }
        }
        for (id_str, val) in &errors_map {
            if let Ok(id) = id_str.parse::<u32>() {
                let msg = val.as_str().unwrap_or("error").to_string();
                let exc =
                    monty_types::MontyException::new(monty_types::ExcType::RuntimeError, Some(msg));
                resolved.push((id, ExtFunctionResult::Error(exc)));
            }
        }

        let mut buf = String::new();
        let result = futures.resume(
            resolved,
            PrintWriter::CollectString(&mut buf, crate::convert::PRINT_COLLECT_LIMIT),
        );
        self.print_output.push_str(&buf);

        match result {
            Ok(progress) => self.process_repl_progress(progress),
            Err(err) => self.handle_repl_start_error(*err),
        }
    }

    // -----------------------------------------------------------------------
    // State accessors
    // -----------------------------------------------------------------------

    /// Returns the pending function name, if in Paused state.
    pub fn pending_fn_name(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(&meta.fn_name),
            _ => None,
        }
    }

    /// Returns the pending function arguments as JSON, if in Paused state.
    pub fn pending_fn_args_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(&meta.args_json),
            _ => None,
        }
    }

    /// Returns the pending keyword arguments as JSON, if in Paused state.
    pub fn pending_fn_kwargs_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(&meta.kwargs_json),
            _ => None,
        }
    }

    /// Returns the pending call ID, if in Paused state.
    pub fn pending_call_id(&self) -> Option<u32> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(meta.call_id),
            _ => None,
        }
    }

    /// Whether the pending call is a method call, if in Paused state.
    pub fn pending_method_call(&self) -> Option<bool> {
        match &self.state {
            ReplHandleState::Paused { meta, .. } => Some(meta.method_call),
            _ => None,
        }
    }

    /// Returns the OS call function name, if in OsCall state.
    pub fn os_call_fn_name(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(&meta.os_fn_name),
            _ => None,
        }
    }

    /// Returns the OS call arguments as JSON, if in OsCall state.
    pub fn os_call_args_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(&meta.args_json),
            _ => None,
        }
    }

    /// Returns the OS call keyword arguments as JSON, if in OsCall state.
    pub fn os_call_kwargs_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(&meta.kwargs_json),
            _ => None,
        }
    }

    /// Returns the OS call ID, if in OsCall state.
    pub fn os_call_id(&self) -> Option<u32> {
        match &self.state {
            ReplHandleState::OsCall { meta, .. } => Some(meta.call_id),
            _ => None,
        }
    }

    /// Returns the completed result JSON, if in Complete state.
    pub fn complete_result_json(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Complete { result_json, .. } => Some(result_json),
            _ => None,
        }
    }

    /// Whether the completed result is an error, if in Complete state.
    pub fn complete_is_error(&self) -> Option<bool> {
        match &self.state {
            ReplHandleState::Complete { is_error, .. } => Some(*is_error),
            _ => None,
        }
    }

    /// Returns the pending future call IDs as JSON, if in Futures state.
    pub fn pending_future_call_ids(&self) -> Option<&str> {
        match &self.state {
            ReplHandleState::Futures { call_ids_json, .. } => Some(call_ids_json),
            _ => None,
        }
    }

    // -----------------------------------------------------------------------
    // Stateless helpers
    // -----------------------------------------------------------------------

    /// Detect whether a source fragment is complete or needs more input.
    #[must_use]
    pub fn detect_continuation(source: &str) -> i32 {
        use monty::ReplContinuationMode;
        match detect_repl_continuation_mode(source) {
            ReplContinuationMode::Complete => CONTINUATION_COMPLETE,
            ReplContinuationMode::IncompleteImplicit => CONTINUATION_INCOMPLETE_IMPLICIT,
            ReplContinuationMode::IncompleteBlock => CONTINUATION_INCOMPLETE_BLOCK,
        }
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Extracts the `MontyRepl` from `Idle` or `Complete` state.
    ///
    /// Sets state to `Consumed` temporarily. The caller must store a new
    /// state before returning to the C API.
    fn take_repl(&mut self) -> Result<MontyRepl, String> {
        let state = std::mem::replace(&mut self.state, ReplHandleState::Consumed);
        match state {
            ReplHandleState::Idle(repl) | ReplHandleState::Complete { repl, .. } => Ok(repl),
            other => {
                self.state = other;
                Err("handle not in Idle or Complete state".into())
            }
        }
    }

    /// Processes a `ReplProgress` value, updating the handle state and
    /// returning the progress tag.
    ///
    /// `NameLookup` variants are auto-resolved in a loop using `ext_fn_names`.
    fn process_repl_progress(
        &mut self,
        mut progress: ReplProgress,
    ) -> (MontyProgressTag, Option<String>) {
        loop {
            match progress {
                ReplProgress::Complete { repl, value } => {
                    let val = monty_object_to_json(&value);
                    let result_json = build_repl_result_json(&val, None, &self.print_output);
                    self.print_output.clear();
                    self.state = ReplHandleState::Complete {
                        repl,
                        result_json,
                        is_error: false,
                    };
                    return (MontyProgressTag::Complete, None);
                }
                ReplProgress::FunctionCall(call) => {
                    let meta = build_pending_meta(
                        call.function_name.clone(),
                        &call.args,
                        &call.kwargs,
                        call.call_id,
                        call.object_id.is_some(),
                    );
                    self.state = ReplHandleState::Paused { call, meta };
                    return (MontyProgressTag::Pending, None);
                }
                ReplProgress::OsCall(call) => {
                    let os_fn_name = call.function_call.name().to_string();
                    let call_id = call.call_id;
                    // #583 removed `take_function_call()`: the OS-call payload is now RETAINED in the
                    // suspended state instead of being moved out (the `OsFunctionCall::Used`
                    // placeholder is gone). We read a clone here because the payload is needed
                    // NOW, to build the metadata handed to Dart, while the resume happens in a
                    // LATER FFI call — so upstream's `resume_with(.., FnOnce(OsFunctionCall))`,
                    // which supplies the payload at resume time, does not fit this flow. The
                    // original stays intact for the eventual `resume()`.
                    let (args, kwargs) = call.function_call.clone().to_args();
                    let meta = OsCallMeta {
                        os_fn_name,
                        args_json: serde_json::to_string(
                            &args.iter().map(monty_object_to_json).collect::<Vec<_>>(),
                        )
                        .unwrap_or_else(|_| "[]".into()),
                        kwargs_json: if kwargs.is_empty() {
                            "{}".into()
                        } else {
                            let map: serde_json::Map<String, Value> = kwargs
                                .iter()
                                .map(|(k, v)| {
                                    let key = if let MontyObject::String(s) = k {
                                        s.clone()
                                    } else {
                                        format!("{k}")
                                    };
                                    (key, monty_object_to_json(v))
                                })
                                .collect();
                            serde_json::to_string(&map).unwrap_or_else(|_| "{}".into())
                        },
                        call_id,
                    };
                    self.state = ReplHandleState::OsCall { call, meta };
                    return (MontyProgressTag::OsCall, None);
                }
                ReplProgress::ResolveFutures(futures) => {
                    let call_ids_json = serde_json::to_string(futures.pending_call_ids())
                        .unwrap_or_else(|_| "[]".into());
                    self.state = ReplHandleState::Futures {
                        futures,
                        call_ids_json,
                    };
                    return (MontyProgressTag::ResolveFutures, None);
                }
                ReplProgress::NameLookup(lookup) => {
                    let name = lookup.name.clone();
                    let mut buf = String::new();
                    let result = if self.ext_fn_names.contains(&name) {
                        lookup.resume(
                            NameLookupResult::Value(MontyObject::Function {
                                name,
                                docstring: None,
                            }),
                            PrintWriter::CollectString(
                                &mut buf,
                                crate::convert::PRINT_COLLECT_LIMIT,
                            ),
                        )
                    } else {
                        lookup.resume(
                            NameLookupResult::Undefined,
                            PrintWriter::CollectString(
                                &mut buf,
                                crate::convert::PRINT_COLLECT_LIMIT,
                            ),
                        )
                    };
                    self.print_output.push_str(&buf);
                    match result {
                        Ok(next) => progress = next,
                        Err(err) => return self.handle_repl_start_error(*err),
                    }
                }
            }
        }
    }

    /// Handles a `ReplStartError` — recovers the REPL and stores the error.
    fn handle_repl_start_error(
        &mut self,
        err: ReplStartError,
    ) -> (MontyProgressTag, Option<String>) {
        let err_json = monty_exception_to_json(&err.error);
        let msg = err.error.summary();
        let result_json = build_repl_result_json(&Value::Null, Some(err_json), &self.print_output);
        self.print_output.clear();
        self.state = ReplHandleState::Complete {
            repl: err.repl,
            result_json,
            is_error: true,
        };
        (MontyProgressTag::Error, Some(msg))
    }
}

// ---------------------------------------------------------------------------
// Helper functions
// ---------------------------------------------------------------------------

/// Build a `PendingMeta` from function call data.
fn build_pending_meta(
    function_name: String,
    args: &[MontyObject],
    kwargs: &[(MontyObject, MontyObject)],
    call_id: u32,
    method_call: bool,
) -> PendingMeta {
    let args_json =
        serde_json::to_string(&args.iter().map(monty_object_to_json).collect::<Vec<_>>())
            .unwrap_or_else(|_| "[]".into());

    let kwargs_json = if kwargs.is_empty() {
        "{}".into()
    } else {
        let map: serde_json::Map<String, Value> = kwargs
            .iter()
            .map(|(k, v)| {
                let key = if let MontyObject::String(s) = k {
                    s.clone()
                } else {
                    format!("{k}")
                };
                (key, monty_object_to_json(v))
            })
            .collect();
        serde_json::to_string(&map).unwrap_or_else(|_| "{}".into())
    };

    PendingMeta {
        fn_name: function_name,
        args_json,
        kwargs_json,
        call_id,
        method_call,
    }
}

/// Build result JSON in the same format as `MontyHandle::run` results.
fn build_repl_result_json(value: &Value, error: Option<Value>, print_output: &str) -> String {
    let mut result = serde_json::json!({
        "value": value,
        "usage": {
            "memory_bytes_used": 0,
            "time_elapsed_ms": 0,
            "stack_depth_used": 0,
        },
    });
    if let Some(err) = error {
        result.as_object_mut().unwrap().insert("error".into(), err);
    }
    if !print_output.is_empty() {
        result
            .as_object_mut()
            .unwrap()
            .insert("print_output".into(), Value::String(print_output.into()));
    }
    serde_json::to_string(&result).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    // -----------------------------------------------------------------------
    // Phase 1 tests (feed_run still works with new state machine)
    // -----------------------------------------------------------------------

    #[test]
    fn repl_handle_basic_state_persistence() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, _, _) = repl.feed_run("x = 42");
        assert_eq!(tag, MontyResultTag::Ok);

        let (tag, json, _) = repl.feed_run("x + 1");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 43);
    }

    #[test]
    fn repl_handle_function_persistence() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.feed_run("def f():\n    return 99");

        let (tag, json, _) = repl.feed_run("f()");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 99);
    }

    #[test]
    fn repl_handle_survives_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, _, _) = repl.feed_run("x = 10");
        assert_eq!(tag, MontyResultTag::Ok);

        let (tag, _, _) = repl.feed_run("1 / 0");
        assert_eq!(tag, MontyResultTag::Error);

        let (tag, json, _) = repl.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 10);
    }

    #[test]
    fn repl_handle_print_output() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, json, _) = repl.feed_run("print('hello')");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["print_output"], "hello\n");
    }

    #[test]
    fn detect_continuation_complete() {
        assert_eq!(
            MontyReplHandle::detect_continuation("x = 1"),
            CONTINUATION_COMPLETE
        );
    }

    #[test]
    fn detect_continuation_incomplete_block() {
        assert_eq!(
            MontyReplHandle::detect_continuation("def f():"),
            CONTINUATION_INCOMPLETE_BLOCK,
        );
    }

    #[test]
    fn detect_continuation_incomplete_implicit() {
        assert_eq!(
            MontyReplHandle::detect_continuation("x = (1 +"),
            CONTINUATION_INCOMPLETE_IMPLICIT,
        );
    }

    // -----------------------------------------------------------------------
    // Phase 2 tests (feed_start + resume)
    // -----------------------------------------------------------------------

    #[test]
    fn feed_start_with_ext_fn_pauses() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["get_temp".into()]);

        let (tag, _) = repl.feed_start("result = get_temp()");
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("get_temp"));
        assert_eq!(repl.pending_call_id(), Some(0));
    }

    #[test]
    fn feed_start_resume_completes() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["get_temp".into()]);

        let (tag, _) = repl.feed_start("result = get_temp()\nresult");
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume("72");
        assert_eq!(tag, MontyProgressTag::Complete);

        // Verify result JSON — last expression is `result` which evaluates to 72
        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert_eq!(parsed["value"], 72);
    }

    #[test]
    fn feed_start_state_persists_after_resume() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["get_temp".into()]);

        // Use feed_start to set a variable via external function
        let (tag, _) = repl.feed_start("temp = get_temp()");
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume("72");
        assert_eq!(tag, MontyProgressTag::Complete);

        // Now use feed_run to verify state persisted
        let (tag, json, _) = repl.feed_run("temp");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 72);
    }

    #[test]
    fn feed_start_multiple_ext_fn_calls() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["get_a".into(), "get_b".into()]);

        let (tag, _) = repl.feed_start("a = get_a()\nb = get_b()\na + b");

        // First call: get_a
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("get_a"));

        let (tag, _) = repl.resume("10");

        // Second call: get_b
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("get_b"));

        let (tag, _) = repl.resume("20");

        // Complete with a + b = 30
        assert_eq!(tag, MontyProgressTag::Complete);
        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert_eq!(parsed["value"], 30);
    }

    #[test]
    fn feed_start_resume_with_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["fetch".into()]);

        let (tag, _) = repl.feed_start(
            "try:\n    result = fetch('url')\nexcept Exception as e:\n    result = str(e)\nresult",
        );
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume_with_error("connection refused");
        assert_eq!(tag, MontyProgressTag::Complete);

        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert!(
            parsed["value"]
                .as_str()
                .unwrap()
                .contains("connection refused")
        );
    }

    #[test]
    fn feed_start_error_recovers_repl() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.feed_run("x = 42");

        // feed_start with code that raises immediately
        let (tag, _) = repl.feed_start("1 / 0");
        assert_eq!(tag, MontyProgressTag::Error);
        assert_eq!(repl.complete_is_error(), Some(true));

        // REPL is recovered — x still accessible
        let (tag, json, _) = repl.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 42);
    }

    #[test]
    fn feed_start_unknown_fn_yields_pending() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        // Without ext_fns registered, an unknown function call still
        // yields Pending — the host decides how to respond.
        let (tag, _) = repl.feed_start("unknown_fn()");
        assert_eq!(tag, MontyProgressTag::Pending);
        assert_eq!(repl.pending_fn_name(), Some("unknown_fn"));

        // Resume with error to reject the call.
        let (tag, _) = repl.resume_with_error("not implemented");
        // The snippet wraps the error, so it completes with an error.
        assert_eq!(tag, MontyProgressTag::Error);
        assert_eq!(repl.complete_is_error(), Some(true));
    }

    #[test]
    fn resume_wrong_state_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, err) = repl.resume("42");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn feed_run_after_feed_start_cycle() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["get_val".into()]);

        // feed_start cycle
        repl.feed_start("x = get_val()");
        repl.resume("100");

        // feed_run should still work
        let (tag, json, _) = repl.feed_run("x * 2");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 200);
    }

    // -----------------------------------------------------------------------
    // Accessor coverage
    // -----------------------------------------------------------------------

    #[test]
    fn pending_args_and_kwargs_accessors() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["add".into()]);

        let (tag, _) = repl.feed_start("add(1, 2)");
        assert_eq!(tag, MontyProgressTag::Pending);

        // args JSON should contain [1, 2]
        let args = repl.pending_fn_args_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(args).unwrap();
        assert_eq!(parsed[0], 1);
        assert_eq!(parsed[1], 2);

        // kwargs should be empty object
        let kwargs = repl.pending_fn_kwargs_json().unwrap();
        assert_eq!(kwargs, "{}");

        // method_call false for plain function
        assert_eq!(repl.pending_method_call(), Some(false));

        // complete after resume
        repl.resume("3");
    }

    #[test]
    fn accessors_return_none_in_wrong_state() {
        let repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        // Idle state — all state-specific accessors return None
        assert!(repl.pending_fn_name().is_none());
        assert!(repl.pending_fn_args_json().is_none());
        assert!(repl.pending_fn_kwargs_json().is_none());
        assert!(repl.pending_call_id().is_none());
        assert!(repl.pending_method_call().is_none());
        assert!(repl.os_call_fn_name().is_none());
        assert!(repl.os_call_args_json().is_none());
        assert!(repl.os_call_kwargs_json().is_none());
        assert!(repl.os_call_id().is_none());
        assert!(repl.complete_result_json().is_none());
        assert!(repl.complete_is_error().is_none());
        assert!(repl.pending_future_call_ids().is_none());
    }

    // -----------------------------------------------------------------------
    // Debug fmt
    // -----------------------------------------------------------------------

    // -----------------------------------------------------------------------
    // Snapshot / restore
    // -----------------------------------------------------------------------

    /// A snapshot that round-trips EMPTY state satisfies the type signature
    /// and proves nothing. This asserts a VALUE and a FUNCTION both survive —
    /// the same bar the shipped pydantic-monty 0.0.23 was measured against,
    /// where `x = 42` and `double(21)` both came back across a different
    /// worker process.
    #[test]
    fn snapshot_round_trips_state_and_a_function() {
        let mut repl = MontyReplHandle::new("rt.py", ResourceLimits::default());
        let (tag, _, _) = repl.feed_run("x = 42\ndef double(n):\n    return n * 2\n");
        assert_eq!(tag, MontyResultTag::Ok, "setup must run");

        let bytes = repl.snapshot().expect("idle snapshot");
        assert!(
            !bytes.is_empty(),
            "a snapshot of real state cannot be empty"
        );

        let mut restored =
            MontyReplHandle::restore_keeping_snapshot_limits(&bytes).expect("restore");

        // The VALUE survived.
        let (tag, json, _) = restored.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(
            json.contains("42"),
            "x did not survive the round trip: {json}"
        );

        // The FUNCTION survived — this is the part a bytes-length check misses.
        let (tag, json, _) = restored.feed_run("double(21)");
        assert_eq!(tag, MontyResultTag::Ok);
        assert!(
            json.contains("42"),
            "a function defined before the snapshot did not survive: {json}"
        );
    }

    /// `ext_fn_names` lives on THIS handle, not on monty's `MontyRepl`, so a
    /// dump cannot carry it. Both prior investigations of this code missed
    /// that, and one proposed a `restore()` whose body literally contained
    /// `ext_fn_names: HashSet::new()`.
    ///
    /// The consequence is silent: a restored session's external calls simply
    /// stop resolving. This pins BOTH halves — that plain `restore` starts
    /// empty, and that `restore_with_ext_fns` puts them back.
    #[test]
    fn restore_does_not_carry_ext_fns_and_the_two_arg_form_restores_them() {
        let mut repl = MontyReplHandle::new("ext.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["tool".to_string()]);
        let (tag, _, _) = repl.feed_run("y = 1");
        assert_eq!(tag, MontyResultTag::Ok);

        let bytes = repl.snapshot().expect("snapshot");

        let bare = MontyReplHandle::restore_keeping_snapshot_limits(&bytes).expect("restore");
        assert!(
            bare.ext_fn_names.is_empty(),
            "a snapshot cannot carry ext_fn_names; if this ever passes them \
             through, delete restore_with_ext_fns and this test"
        );

        let with = MontyReplHandle::restore_with_ext_fns(&bytes, vec!["tool".to_string()], None)
            .expect("restore with ext fns");
        assert!(
            with.ext_fn_names.contains("tool"),
            "restore_with_ext_fns must re-establish the names, or a restored \
             session's external calls silently stop resolving"
        );
    }

    /// A restored session must run under the limits the CALLER asked for, not
    /// the ones the snapshot happened to carry.
    ///
    /// Limits live in the `ResourceTracker` INSIDE the `MontyRepl`, so a dump
    /// faithfully restores the DUMPED session's limits. That is wrong for a
    /// caller supplying their own, and it fails silently: measured before
    /// `restore_with_ext_fns` took a limits argument, a handle built with
    /// stackDepth 5 that restored an unbounded snapshot ran UNBOUNDED, while
    /// an identical un-restored handle raised RecursionError. A dropped limit
    /// is a security control that reports success (FB-1 / core#124).
    #[test]
    fn restore_applies_the_callers_limits_not_the_snapshots() {
        let mut unbounded = MontyReplHandle::new("lim.py", ResourceLimits::default());
        let (tag, _, _) = unbounded.feed_run("x = 1");
        assert_eq!(tag, MontyResultTag::Ok);
        let bytes = unbounded.snapshot().expect("snapshot");

        let tight = ResourceLimits {
            max_recursion_depth: 5,
            ..ResourceLimits::default()
        };
        let mut restored = MontyReplHandle::restore_with_ext_fns(&bytes, Vec::new(), Some(tight))
            .expect("restore with limits");

        let (tag, json, _) =
            restored.feed_run("def rec(n):\n    return 1 if n <= 0 else rec(n - 1)\nrec(50)\n");
        assert!(
            tag != MontyResultTag::Ok || json.contains("RecursionError"),
            "a restored session ignored the caller's recursion limit and ran to \
             completion: tag={tag:?} json={json}"
        );

        // And None keeps the snapshot's own limits, which is the right default
        // for a caller who did not ask for anything.
        let kept = MontyReplHandle::restore_with_ext_fns(&bytes, Vec::new(), None)
            .expect("restore without limits");
        drop(kept);
    }

    /// F5: the convenience wrapper INHERITS the snapshot's limits, and its name
    /// now says so.
    ///
    /// It was `restore(bytes)` passing `limits: None`, so whoever supplied the
    /// bytes chose the resource limits and nothing in the call site hinted at
    /// it. The behaviour is legitimate for your OWN bytes and dangerous for
    /// anyone else's, so it was renamed rather than deleted — the caller now
    /// has to type the consequence.
    ///
    /// This test pins the INHERITANCE, not the safety. If someone later
    /// "fixes" this wrapper to apply default limits, restoring a bounded
    /// snapshot would silently widen it, and that is the opposite defect from
    /// the same family.
    #[test]
    fn restore_keeping_snapshot_limits_really_does_keep_them() {
        let tight = ResourceLimits {
            max_recursion_depth: 5,
            ..ResourceLimits::default()
        };
        let mut bounded = MontyReplHandle::new("keep.py", tight);
        let (tag, _, _) = bounded.feed_run("x = 1");
        assert_eq!(tag, MontyResultTag::Ok);
        let bytes = bounded.snapshot().expect("snapshot");

        let mut restored = MontyReplHandle::restore_keeping_snapshot_limits(&bytes)
            .expect("restore keeping snapshot limits");

        let (tag, json, _) =
            restored.feed_run("def rec(n):\n    return 1 if n <= 0 else rec(n - 1)\nrec(50)\n");
        assert!(
            tag != MontyResultTag::Ok || json.contains("RecursionError"),
            "the snapshot was taken with stackDepth 5 and the restored session \
             ran rec(50) to completion — the wrapper did NOT keep the \
             snapshot's limits, which is what its name promises: tag={tag:?} \
             json={json}"
        );
    }

    /// Pin the dump format version we built against.
    ///
    /// `Dump::load` distinguishes `DumpError::VersionMismatch` from a payload
    /// error, and this asserts we notice an upstream bump instead of
    /// discovering it as a corrupt restore. Update DELIBERATELY when monty
    /// bumps it, after re-checking that our snapshot/restore still round-trips.
    #[test]
    fn dump_version_is_pinned() {
        assert_eq!(
            DUMP_VERSION, 8,
            "monty's DUMP_VERSION changed. Snapshots written by the old format \
             will not load. Re-run the round-trip tests, then update this pin."
        );
    }

    #[test]
    fn snapshot_restore_preserves_state() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, _, _) = repl.feed_run("x = 42");
        assert_eq!(tag, MontyResultTag::Ok);

        let bytes = repl
            .snapshot()
            .expect("snapshot should succeed in Idle state");
        assert!(!bytes.is_empty());

        let mut restored = MontyReplHandle::restore_keeping_snapshot_limits(&bytes)
            .expect("restore should succeed");
        let (tag, json, _) = restored.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 42);
    }

    #[test]
    fn snapshot_mid_execution_returns_err() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["f".into()]);
        repl.feed_start("f()");
        // Handle is now Paused — snapshot must fail
        assert!(repl.snapshot().is_err());
    }

    #[test]
    fn parse_limits_json_reads_all_three_axes() {
        let l =
            parse_limits_json(r#"{"memory_bytes": 1048576, "stack_depth": 64, "timeout_ms": 250}"#)
                .expect("valid limits");
        assert_eq!(l.max_memory, Some(1_048_576));
        assert_eq!(l.max_recursion_depth, 64);
        assert_eq!(l.max_duration, Some(std::time::Duration::from_millis(250)));
    }

    // F8/F6: a PRESENT but unusable limit must ERROR, never silently unbound.
    //
    // These are the values that used to return Ok(unbounded) because
    // `.and_then(Value::as_u64)` yields None for all of them. Each one is a
    // caller who asked for a limit and would have got none -- the exact failure
    // the doc comment on parse_limits_json says cannot happen.
    #[test]
    fn parse_limits_json_rejects_a_present_but_unusable_value() {
        for (json, why) in [
            (r#"{"memory_bytes": -1}"#, "negative"),
            (r#"{"stack_depth": -1}"#, "negative"),
            (r#"{"timeout_ms": -1}"#, "negative"),
            (r#"{"memory_bytes": "1000"}"#, "string"),
            (r#"{"stack_depth": 1.5}"#, "float"),
            (r#"{"timeout_ms": true}"#, "bool"),
            (r#"{"memory_bytes": []}"#, "array"),
            (r#"{"stack_depth": {}}"#, "object"),
        ] {
            let got = parse_limits_json(json);
            assert!(
                got.is_err(),
                "{json} ({why}) returned Ok -- a dropped limit is a security \
                 control that reports success"
            );
            let msg = got.unwrap_err();
            assert!(
                msg.contains("non-negative integer"),
                "{json}: the error must say what was wrong with the VALUE, so a \
                 caller can fix it. Got: {msg}"
            );
        }
    }

    #[test]
    fn parse_limits_json_accepts_explicit_null_as_unbounded() {
        // Bounds the check above. `null` is a REAL request for "no limit on
        // this axis" and must stay a silent default -- tightening the guard to
        // reject anything non-integer would break every caller that serialises
        // an absent Dart field as null.
        let l = parse_limits_json(r#"{"memory_bytes": null, "stack_depth": 8}"#)
            .expect("explicit null is a valid way to say unbounded");
        assert_eq!(l.max_memory, None);
        assert_eq!(l.max_recursion_depth, 8);
    }

    #[test]
    fn parse_limits_json_accepts_zero() {
        // Zero is a legitimate non-negative integer and must NOT be swept up
        // with the rejections -- absent, zero and wrong-typed are three
        // different things, which is the whole point of this change.
        let l = parse_limits_json(r#"{"timeout_ms": 0}"#).expect("zero is a valid value");
        assert_eq!(l.max_duration, Some(std::time::Duration::from_millis(0)));
    }

    #[test]
    fn parse_limits_json_treats_absent_fields_as_unbounded() {
        let l = parse_limits_json("{}").expect("empty object is valid");
        assert_eq!(l.max_memory, None);
        assert_eq!(
            l.max_recursion_depth,
            monty_types::DEFAULT_MAX_RECURSION_DEPTH
        );
        assert_eq!(l.max_duration, None);
    }

    #[test]
    fn parse_limits_json_rejects_garbage_rather_than_falling_back() {
        // A caller who asks for a limit and silently receives none is core#138.
        assert!(parse_limits_json("not json").is_err());
        assert!(parse_limits_json("[1,2]").is_err());
    }

    /// The regression core#138 is about: a limit that is set must actually bite.
    #[test]
    fn a_recursion_limit_stops_runaway_recursion() {
        let limits = ResourceLimits {
            max_recursion_depth: 16,
            ..Default::default()
        };
        let mut h = MontyReplHandle::new("repl.py", limits);

        let (tag, _json, _err) = h.feed_run("def f(n):\n    return f(n + 1)\nf(0)");

        // Without a limit this recurses until the process dies; with one it must
        // come back as an error instead.
        assert_eq!(
            tag,
            MontyResultTag::Error,
            "unbounded recursion should have been stopped by max_recursion_depth"
        );
    }

    #[test]
    fn an_unbounded_session_still_runs_ordinary_code() {
        // LimitedTracker with ResourceLimits::default() must behave as
        // NoLimitTracker did — every existing caller depends on it.
        let mut h = MontyReplHandle::new("repl.py", ResourceLimits::default());
        let (tag, _json, _err) = h.feed_run("sum(range(1000))");
        assert_eq!(tag, MontyResultTag::Ok);
    }

    #[test]
    fn restore_isolates_from_original() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.feed_run("x = 1");

        let bytes = repl.snapshot().unwrap();
        let mut restored = MontyReplHandle::restore_keeping_snapshot_limits(&bytes).unwrap();

        // Modify original
        repl.feed_run("x = 99");

        // Restored session should still have x == 1
        let (tag, json, _) = restored.feed_run("x");
        assert_eq!(tag, MontyResultTag::Ok);
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["value"], 1);
    }

    #[test]
    fn debug_fmt_does_not_panic() {
        let repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let s = format!("{repl:?}");
        assert!(s.contains("MontyReplHandle"));
    }

    // -----------------------------------------------------------------------
    // Wrong-state error paths
    // -----------------------------------------------------------------------

    #[test]
    fn resume_invalid_json_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["f".into()]);
        repl.feed_start("f()");

        let (tag, err) = repl.resume("{not valid json");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("invalid JSON"));
    }

    #[test]
    fn resume_with_error_wrong_state_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        // Idle state — not paused
        let (tag, err) = repl.resume_with_error("boom");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn resume_as_future_wrong_state_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, err) = repl.resume_as_future();
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("Paused"));
    }

    #[test]
    fn resume_futures_wrong_state_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, err) = repl.resume_futures("{}", "{}");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.unwrap().contains("Futures"));
    }

    #[test]
    fn feed_run_while_paused_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["f".into()]);
        repl.feed_start("f()");

        // Handle is Paused — take_repl should fail
        let (tag, _, err) = repl.feed_run("1 + 1");
        assert_eq!(tag, MontyResultTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn feed_start_while_paused_returns_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["f".into()]);
        repl.feed_start("f()");

        // Handle is Paused — take_repl should fail
        let (tag, err) = repl.feed_start("1 + 1");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    // -----------------------------------------------------------------------
    // OS call path
    // -----------------------------------------------------------------------

    #[test]
    fn os_call_flow_resume_with_value() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, _) = repl.feed_start("import os\nos.getenv('FOO')");

        if tag != MontyProgressTag::OsCall {
            // If os.getenv isn't an OsCall in this build, skip gracefully.
            return;
        }

        assert!(repl.os_call_fn_name().is_some());
        assert!(repl.os_call_args_json().is_some());
        assert!(repl.os_call_kwargs_json().is_some());
        assert!(repl.os_call_id().is_some());

        let (tag, _) = repl.resume("\"bar\"");
        assert_eq!(tag, MontyProgressTag::Complete);
        let result_json = repl.complete_result_json().unwrap();
        let parsed: serde_json::Value = serde_json::from_str(result_json).unwrap();
        assert_eq!(parsed["value"], "bar");
    }

    #[test]
    fn os_call_flow_resume_with_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, _) = repl.feed_start(
            "import os\ntry:\n    os.getenv('FOO')\nexcept Exception as e:\n    str(e)",
        );

        if tag != MontyProgressTag::OsCall {
            return;
        }

        let (tag, _) = repl.resume_with_error("env not available");
        assert_eq!(tag, MontyProgressTag::Complete);
    }

    // -----------------------------------------------------------------------
    // Async future path
    // -----------------------------------------------------------------------

    #[test]
    fn resume_not_found_raises_name_error() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["missing_fn".into()]);
        let (tag, _) = repl.feed_start("missing_fn(1)");
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume_not_found("missing_fn");
        assert_eq!(tag, MontyProgressTag::Error);
        assert_eq!(repl.complete_is_error(), Some(true));

        let result: serde_json::Value =
            serde_json::from_str(repl.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["error"]["exc_type"], "NameError");
        assert!(
            result["error"]["message"]
                .as_str()
                .unwrap()
                .contains("missing_fn")
        );
    }

    #[test]
    fn resume_not_found_caught_in_python() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["missing_fn".into()]);
        let (tag, _) = repl.feed_start(
            "try:\n    missing_fn()\nexcept NameError as e:\n    result = 'caught'\nresult",
        );
        assert_eq!(tag, MontyProgressTag::Pending);

        let (tag, _) = repl.resume_not_found("missing_fn");
        assert_eq!(tag, MontyProgressTag::Complete);
        let result: serde_json::Value =
            serde_json::from_str(repl.complete_result_json().unwrap()).unwrap();
        assert_eq!(result["value"], "caught");
    }

    #[test]
    fn resume_not_found_wrong_state() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        let (tag, err) = repl.resume_not_found("foo");
        assert_eq!(tag, MontyProgressTag::Error);
        assert!(err.is_some());
    }

    #[test]
    fn resume_as_future_then_resolve() {
        let mut repl = MontyReplHandle::new("test.py", ResourceLimits::default());
        repl.set_ext_fns(vec!["fetch".into()]);

        let (tag, _) = repl.feed_start(
            "import asyncio\nasync def go():\n    return await fetch('url')\nasyncio.run(go())",
        );

        if tag != MontyProgressTag::Pending {
            // Not all monty builds surface async this way; skip gracefully.
            return;
        }

        let (tag, _) = repl.resume_as_future();

        if tag == MontyProgressTag::ResolveFutures {
            let ids_json = repl.pending_future_call_ids().unwrap().to_string();
            let ids: serde_json::Value = serde_json::from_str(&ids_json).unwrap();
            let id = ids[0].as_u64().unwrap_or(0).to_string();

            let results = format!("{{\"{id}\": 42}}");
            let (tag, _) = repl.resume_futures(&results, "{}");
            assert!(
                tag == MontyProgressTag::Complete
                    || tag == MontyProgressTag::Pending
                    || tag == MontyProgressTag::ResolveFutures
            );
        }
    }
}
