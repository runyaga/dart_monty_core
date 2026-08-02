use monty_types::MontyObject;

/// Cap on print output collected into a host-side buffer.
///
/// Upstream #558 added this parameter to `PrintWriter::CollectString` /
/// `CollectStreams` so a sandboxed `while True: print("x")` cannot exhaust the
/// **host** process's memory — print collection previously sat outside all
/// resource accounting.
///
/// Exceeding the cap raises a catchable Python `MemoryError` (via
/// `check_print_collect_limit`); it does **not** truncate, and no output is
/// silently lost. `None` would restore the unbounded 0.18 behaviour and with it
/// the host-OOM exposure.
///
/// Defined here because `convert.rs` is the only module shared by the library
/// and the `oracle` binary, which must agree or fixture conformance diverges.
///
/// Follow-up: expose this as its own knob — deliberately NOT via `MontyLimits`.
/// Upstream documents `CollectString`/`CollectStreams` caps as "Not covered by
/// `ResourceLimits.max_memory`", so folding them into the resource-limits API
/// would conflate two mechanisms upstream keeps separate.
/// The version of the value-encoding wire format.
///
/// Bump this in the SAME commit as any change to what `monty_object_to_json`
/// emits or `json_to_monty_object` accepts. The Dart decoder asserts it at
/// init, so a stale committed asset fails loudly at startup instead of
/// mis-decoding values at some later point.
///
/// This exists because the WASM assets in `lib/assets/` are committed build
/// artefacts and the build is NOT byte-reproducible — an unchanged tree yields
/// different bytes — so `git diff` on the blob cannot tell you whether the
/// asset matches the crate. A version integer can.
///
/// History:
///   1  0.19.0 — `Ellipsis` gained `{"__type":"ellipsis"}`; dict insertion
///                order preserved (core#129).
///   2  0.19.0 — Tier 1: EVERY dict is a tagged envelope
///                (`{"__type":"dict","value":{…}}`, or `"entries"` for
///                non-string keys), and the decoder REJECTS both an untagged
///                object and an unknown `__type` instead of guessing a dict.
///                Closes core#136: a bare object was byte-identical to an
///                envelope, so sandboxed Python could mint any host type.
///   3  0.19.0 — Tier 2: a bare string means `str` and NOTHING else. bigint,
///                non-finite float, exception, type, function, builtin, repr and
///                cycle all gained envelopes, and `abs` stopped arriving as
///                Rust's Debug rendering "Abs". Closes core#134.
///   4  0.19.0 — Tier 3: integral floats, -0.0 and ints past 2^53 travel as
///                tagged TEXT, because a JSON number's text is what the web
///                transport reparses. Closes core#128 on all three backends.
pub const WIRE_FORMAT_VERSION: u32 = 4;

pub const PRINT_COLLECT_LIMIT: Option<usize> = Some(monty_types::DEFAULT_MAX_PRINT_COLLECT_BYTES);

/// Compile options used for every program and REPL session.
///
/// monty v0.0.19 (#556) added pytest-style introspected `assert` messages and
/// turned them **on by default** (`AssertMessageAnnotations::MaxBytes(120)`),
/// deliberately diverging from CPython: `assert 2 == 5` becomes
/// `AssertionError('assert 2 == 5')` where CPython raises `AssertionError()`
/// with an empty message. The change is visible in `str(e)`, `e.args[0]`,
/// tracebacks and host-side error objects.
///
/// We pin it **Off**, which reproduces CPython — and therefore our v0.0.18
/// behaviour — exactly. Two reasons:
///
///  1. Scope: the 0.19 upgrade is port-to-green. Introspected assert messages
///     are a new *capability*, and adopting a new default silently is not a
///     port. It gets surfaced deliberately, as an opt-in, or not at all.
///  2. Blast radius: it rewrites the `AssertionError` text of every failing
///     assert, which is the single largest source of expected-output churn in
///     the 482-fixture conformance corpus.
///
/// Follow-up: expose this through the Dart API so consumers can opt in.
#[must_use]
pub fn compile_options() -> monty_types::CompileOptions {
    monty_types::CompileOptions {
        assert_message_annotations: monty_types::AssertMessageAnnotations::Off,
    }
}

use num_bigint::BigInt;
use num_traits::ToPrimitive;
use serde_json::{Number, Value, json};

/// Convert a `MontyObject` to a JSON `Value`.
///
/// Key mappings:
/// - `None` → `null`
/// - `Bool` → `true`/`false`
/// - `Int` → number
/// - `BigInt` → number if fits i64, else string
/// - `Float` → number
/// - `String` → string
/// - `List` → array
/// - `Dict` → `{"__type": "dict", "value": {…}}` (string keys), or
///   `{"__type": "dict", "entries": [[k, v], …]}` for any other key type
/// - `Ellipsis` → `{"__type": "ellipsis"}`
///
/// Types with no native JSON counterpart use a tagged envelope,
/// `{"__type": <tag>, ...}`, which `json_to_monty_object` reads back so the
/// value round-trips. A bare array would lose the distinction between `list`,
/// `tuple`, `set` and `frozenset`:
/// - `Tuple` → `{"__type": "tuple", "value": [...]}`
/// - `Bytes` → `{"__type": "bytes", "value": [<u8>, ...]}`
/// - `Set` → `{"__type": "set", "value": [...]}`
/// - `FrozenSet` → `{"__type": "frozenset", "value": [...]}`
/// - `Path` → `{"__type": "path", "value": <str>}`
/// - `Date`/`DateTime`/`TimeDelta`/`TimeZone` → `{"__type": ..., <fields>}`
///
/// This list previously claimed `Tuple`, `Bytes`, `Set` and `FrozenSet`
/// serialized as bare arrays. They never have; the tagged form is required for
/// round-tripping. Found by control (d) during the monty 0.19 upgrade.
pub fn monty_object_to_json(obj: &MontyObject) -> Value {
    match obj {
        MontyObject::None => Value::Null,
        MontyObject::Bool(b) => Value::Bool(*b),
        MontyObject::Int(n) => int_to_json(*n),
        MontyObject::BigInt(n) => bigint_to_json(n),
        MontyObject::Float(f) => float_to_json(*f),
        MontyObject::String(s) => Value::String(s.clone()),
        MontyObject::List(items) => Value::Array(items.iter().map(monty_object_to_json).collect()),
        MontyObject::Tuple(items) => json!({
            "__type": "tuple",
            "value": items.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::Dict(pairs) => dict_to_json(pairs),
        MontyObject::Set(items) => json!({
            "__type": "set",
            "value": items.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::FrozenSet(items) => json!({
            "__type": "frozenset",
            "value": items.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        // `...` gets a tagged envelope like every other non-JSON-native value.
        // It used to serialize as the bare string "...", which is
        // indistinguishable from the actual string "..." (core#129).
        MontyObject::Ellipsis => json!({ "__type": "ellipsis" }),
        MontyObject::Bytes(bytes) => json!({
            "__type": "bytes",
            "value": bytes,
        }),
        MontyObject::NamedTuple {
            type_name,
            field_names,
            values,
        } => json!({
            "__type": "namedtuple",
            "type_name": type_name,
            "field_names": field_names,
            "values": values.iter().map(monty_object_to_json).collect::<Vec<_>>(),
        }),
        MontyObject::Path(p) => json!({
            "__type": "path",
            "value": p,
        }),
        MontyObject::Dataclass {
            name,
            type_id,
            field_names,
            attrs,
            frozen,
        } => {
            let attrs_json = dict_to_json(attrs);
            json!({
                "__type": "dataclass",
                "name": name,
                "type_id": type_id,
                "field_names": field_names,
                "attrs": attrs_json,
                "frozen": frozen,
            })
        }
        // Tier 2, rule R2: a bare JSON string means Python `str` and nothing
        // else. These seven variants all used to collapse onto one, so a value's
        // type depended on whether some OTHER variant happened to produce the
        // same characters. The clearest case: `ValueError("boom")` and the
        // string `"ValueError: boom"` were byte-identical on the wire.
        MontyObject::Type(t) => json!({ "__type": "type", "text": t.to_string() }),
        // `{f}` not `{f:?}`. Debug printed Rust's variant name — `abs` arrived as
        // "Abs" — so the wire carried a Rust identifier where a reader expects
        // the Python name. Display is strum's `serialize_all = "lowercase"`, and
        // `EnumString` parses it back, so this round-trips exactly.
        MontyObject::BuiltinFunction(f) => json!({
            "__type": "builtin",
            "text": f.to_string(),
        }),
        // exc_type and message travel SEPARATELY. Joining them with ": " was
        // lossy in both directions: unrecoverable if the message contained
        // ": ", and indistinguishable from a string that merely looked like it.
        MontyObject::Exception { exc_type, arg } => json!({
            "__type": "exception",
            "exc_type": exc_type.to_string(),
            "message": arg.as_ref().map(std::string::ToString::to_string),
        }),
        MontyObject::Repr(r) => json!({ "__type": "repr", "text": r }),
        MontyObject::Cycle(_, desc) => json!({ "__type": "cycle", "text": desc }),
        MontyObject::Function { name, .. } => json!({
            "__type": "function",
            "text": format!("<function {name}>"),
        }),
        MontyObject::Date(d) => json!({
            "__type": "date",
            "year": d.year,
            "month": d.month,
            "day": d.day,
        }),
        MontyObject::DateTime(dt) => json!({
            "__type": "datetime",
            "year": dt.year,
            "month": dt.month,
            "day": dt.day,
            "hour": dt.hour,
            "minute": dt.minute,
            "second": dt.second,
            "microsecond": dt.microsecond,
            "offset_seconds": dt.offset_seconds,
            "timezone_name": dt.timezone_name,
        }),
        MontyObject::TimeDelta(td) => json!({
            "__type": "timedelta",
            "days": td.days,
            "seconds": td.seconds,
            "microseconds": td.microseconds,
        }),
        MontyObject::TimeZone(tz) => json!({
            "__type": "timezone",
            "offset_seconds": tz.offset_seconds,
            "name": tz.name,
        }),
        MontyObject::FileHandle(fh) => json!({
            "__type": "filehandle",
            "path": fh.path,
            "mode": fh.mode.as_str(),
            "position": fh.position,
        }),
    }
}

/// Message for an object arriving at a value position with no `__type`.
///
/// Kept as a constant because both this and the Dart decoder are asserted
/// against it: after Tier 1 an untagged object is a protocol violation, not a
/// dict, and a test that greps for the word "dict" in a passing decode would
/// otherwise not notice the rule being quietly restored.
const UNTAGGED_OBJECT_ERR: &str = "untagged JSON object at a value position: after wire format v2 every object \
     carries a __type, and a dict is {\"__type\":\"dict\",\"value\":{...}}";

/// Read `field` as a JSON array of values, defaulting to empty when absent.
///
/// Extracted because four arms (`tuple`, `set`, `frozenset`, `namedtuple`) had
/// the identical `.as_array().map(...).unwrap_or_default()` block, and each now
/// needs to propagate a decode failure rather than swallow it.
fn json_array_to_objects(field: Option<&Value>) -> Result<Vec<MontyObject>, String> {
    match field.and_then(|v| v.as_array()) {
        Some(arr) => arr.iter().map(json_to_monty_object).collect(),
        None => Ok(Vec::new()),
    }
}

/// Decode the `dict` envelope's payload into pairs.
///
/// The whole of the core#136 fix lives in the two loops below: keys come from
/// the payload's own key positions and values recurse, but the payload object is
/// NEVER handed back to the `__type` dispatch. So a user dict containing the key
/// `"__type"` is just a dict with an odd key, which is what Python said it was.
fn dict_payload_to_pairs(map: &serde_json::Map<String, Value>) -> Result<MontyObject, String> {
    if let Some(obj) = map.get("value").and_then(|v| v.as_object()) {
        let pairs = obj
            .iter()
            .map(|(k, v)| Ok((MontyObject::String(k.clone()), json_to_monty_object(v)?)))
            .collect::<Result<Vec<_>, String>>()?;
        return Ok(MontyObject::dict(pairs));
    }

    if let Some(arr) = map.get("entries").and_then(|v| v.as_array()) {
        let mut pairs = Vec::with_capacity(arr.len());
        for entry in arr {
            match entry.as_array().map(std::vec::Vec::as_slice) {
                Some([k, v]) => pairs.push((json_to_monty_object(k)?, json_to_monty_object(v)?)),
                _ => {
                    return Err(format!(
                        "dict entries must each be a [key, value] pair, got {entry}"
                    ));
                }
            }
        }
        return Ok(MontyObject::dict(pairs));
    }

    Err("dict envelope needs either \"value\" (string keys) or \"entries\" (any keys)".to_string())
}

/// Convert a JSON `Value` back to a `MontyObject` (for resume values).
///
/// Fallible since wire format v2. It previously decoded an untagged object AND an
/// unknown `__type` as a dict, which are the same forgery-shaped hole core#136
/// describes, pointing the other way: anything the decoder does not recognise
/// became a plausible value instead of a rejection. Rule R4 — the decoder rejects
/// Reads a REQUIRED integer field out of a typed envelope.
///
/// Replaces `map["key"].as_i64().unwrap_or(0).try_into().unwrap_or(0)`, which
/// carried two defects on one line:
///
/// - `map["key"]` is the panicking `Index` impl. A missing key aborted the
///   process. Measured in Chrome against the shipped wasm: a `{"__type":
///   "date", "year": 2020}` envelope with no `month`/`day` returned
///   `error: "unreachable"` — the wasm trap — and left the REPL session
///   permanently in `handle not in Idle or Complete state`, so every later feed
///   on that session failed with an error naming neither a panic nor a cause.
///   A fresh session still worked, so this destroys a session, not the module.
/// - `.unwrap_or(0)` silently substituted zero for a field of the wrong type.
///   Measured: `{"__type": "datetime", …, "hour": "XX", …}` decoded happily to
///   `datetime.datetime(2020, 1, 1, 0, 0)` — `ok: true`, hour silently 0. That
///   is a G2 violation ("never fail silently") sitting inside a decoder.
///
/// Both are now decode errors naming the tag, the field and what was wrong.
fn envelope_int<T>(map: &serde_json::Map<String, Value>, tag: &str, key: &str) -> Result<T, String>
where
    T: TryFrom<i64>,
{
    let Some(raw) = map.get(key) else {
        return Err(format!(
            "{tag} envelope is missing required field \"{key}\""
        ));
    };
    let Some(n) = raw.as_i64() else {
        return Err(format!(
            "{tag} envelope field \"{key}\" must be an integer, got {raw}"
        ));
    };
    T::try_from(n).map_err(|_| format!("{tag} envelope field \"{key}\" is out of range: {n}"))
}

/// Reads an OPTIONAL integer field. Absent is `None`; present-but-wrong is an
/// error, because a caller that supplied the key meant something by it.
fn envelope_opt_int<T>(
    map: &serde_json::Map<String, Value>,
    tag: &str,
    key: &str,
) -> Result<Option<T>, String>
where
    T: TryFrom<i64>,
{
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(_) => envelope_int(map, tag, key).map(Some),
    }
}

/// Reads a REQUIRED string field. Same reasoning as [`envelope_int`]:
/// `map["value"].as_str().unwrap_or("")` turned a malformed envelope into an
/// empty path rather than an error.
fn envelope_str(
    map: &serde_json::Map<String, Value>,
    tag: &str,
    key: &str,
) -> Result<String, String> {
    let Some(raw) = map.get(key) else {
        return Err(format!(
            "{tag} envelope is missing required field \"{key}\""
        ));
    };
    raw.as_str()
        .map(std::string::ToString::to_string)
        .ok_or_else(|| format!("{tag} envelope field \"{key}\" must be a string, got {raw}"))
}

/// Reads a REQUIRED array field. Same reasoning as [`envelope_int`]: the
/// `map["field_names"].as_array().…unwrap_or_default()` shape both panicked on
/// an absent key and turned a wrong-typed one into an empty list.
fn envelope_array<'a>(
    map: &'a serde_json::Map<String, Value>,
    tag: &str,
    key: &str,
) -> Result<&'a Vec<Value>, String> {
    let Some(raw) = map.get(key) else {
        return Err(format!(
            "{tag} envelope is missing required field \"{key}\""
        ));
    };
    raw.as_array()
        .ok_or_else(|| format!("{tag} envelope field \"{key}\" must be an array, got {raw}"))
}

/// Reads an array of strings, rejecting a non-string element rather than
/// substituting `""` for it.
fn envelope_str_array(
    map: &serde_json::Map<String, Value>,
    tag: &str,
    key: &str,
) -> Result<Vec<String>, String> {
    envelope_array(map, tag, key)?
        .iter()
        .map(|v| {
            v.as_str()
                .map(std::string::ToString::to_string)
                .ok_or_else(|| {
                    format!("{tag} envelope field \"{key}\" must contain only strings, got {v}")
                })
        })
        .collect()
}

/// what it does not understand.
pub fn json_to_monty_object(val: &Value) -> Result<MontyObject, String> {
    Ok(match val {
        Value::Null => MontyObject::None,
        Value::Bool(b) => MontyObject::Bool(*b),
        Value::Number(n) => number_to_monty_object(n),
        Value::String(s) => MontyObject::String(s.clone()),
        Value::Array(items) => MontyObject::List(
            items
                .iter()
                .map(json_to_monty_object)
                .collect::<Result<Vec<_>, String>>()?,
        ),
        Value::Object(map) => {
            let Some(type_str) = map.get("__type").and_then(|v| v.as_str()) else {
                return Err(UNTAGGED_OBJECT_ERR.to_string());
            };
            match type_str {
                "dict" => dict_payload_to_pairs(map)?,
                "date" => MontyObject::Date(monty_types::MontyDate {
                    year: envelope_int(map, "date", "year")?,
                    month: envelope_int(map, "date", "month")?,
                    day: envelope_int(map, "date", "day")?,
                }),
                "datetime" => MontyObject::DateTime(monty_types::MontyDateTime {
                    year: envelope_int(map, "datetime", "year")?,
                    month: envelope_int(map, "datetime", "month")?,
                    day: envelope_int(map, "datetime", "day")?,
                    hour: envelope_int(map, "datetime", "hour")?,
                    minute: envelope_int(map, "datetime", "minute")?,
                    second: envelope_int(map, "datetime", "second")?,
                    microsecond: envelope_int(map, "datetime", "microsecond")?,
                    offset_seconds: envelope_opt_int(map, "datetime", "offset_seconds")?,
                    timezone_name: map
                        .get("timezone_name")
                        .and_then(|v| v.as_str())
                        .map(std::string::ToString::to_string),
                }),
                "timedelta" => MontyObject::TimeDelta(monty_types::MontyTimeDelta {
                    days: envelope_int(map, "timedelta", "days")?,
                    seconds: envelope_int(map, "timedelta", "seconds")?,
                    microseconds: envelope_int(map, "timedelta", "microseconds")?,
                }),
                "timezone" => MontyObject::TimeZone(monty_types::MontyTimeZone {
                    offset_seconds: envelope_int(map, "timezone", "offset_seconds")?,
                    name: map
                        .get("name")
                        .and_then(|v| v.as_str())
                        .map(std::string::ToString::to_string),
                }),
                "path" => MontyObject::Path(envelope_str(map, "path", "value")?),
                "bytes" => MontyObject::Bytes(
                    envelope_array(map, "bytes", "value")?
                        .iter()
                        .map(|v| {
                            v.as_u64()
                                .and_then(|n| u8::try_from(n).ok())
                                .ok_or_else(|| {
                                    format!("bytes envelope must contain only 0..=255, got {v}")
                                })
                        })
                        .collect::<Result<Vec<u8>, String>>()?,
                ),
                "tuple" => MontyObject::Tuple(json_array_to_objects(map.get("value"))?),
                "set" => MontyObject::Set(json_array_to_objects(map.get("value"))?),
                "frozenset" => MontyObject::FrozenSet(json_array_to_objects(map.get("value"))?),
                "namedtuple" => MontyObject::NamedTuple {
                    type_name: envelope_str(map, "namedtuple", "type_name")?,
                    field_names: envelope_str_array(map, "namedtuple", "field_names")?,
                    values: json_array_to_objects(map.get("values"))?,
                },
                "dataclass" => MontyObject::Dataclass {
                    name: envelope_str(map, "dataclass", "name")?,
                    type_id: envelope_int::<i64>(map, "dataclass", "type_id")?
                        .try_into()
                        .map_err(|_| {
                            "dataclass envelope field \"type_id\" must not be negative".to_string()
                        })?,
                    field_names: envelope_str_array(map, "dataclass", "field_names")?,
                    // `attrs` is itself a dict envelope, because the encoder
                    // routes it through dict_to_json. That uniformity is the
                    // point: R1 holds with no "except inside dataclass" carve-out.
                    attrs: match map.get("attrs") {
                        Some(a) => match json_to_monty_object(a)? {
                            MontyObject::Dict(pairs) => pairs,
                            other => {
                                return Err(format!(
                                    "dataclass attrs must be a dict envelope, got {other:?}"
                                ));
                            }
                        },
                        None => vec![].into(),
                    },
                    frozen: map
                        .get("frozen")
                        .and_then(serde_json::Value::as_bool)
                        .unwrap_or(false),
                },
                "filehandle" => {
                    // Host (OS handler) returns this for an `Open` call; the
                    // interpreter turns it into the `OpenFile` heap wrapper.
                    // Mode is the canonical open() string (`r`/`rb`/`w`/…);
                    // the engine only ever emits modes that round-trip, so a
                    // parse failure falls back to read-only text.
                    let path = map
                        .get("path")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let position = map
                        .get("position")
                        .and_then(serde_json::Value::as_u64)
                        .unwrap_or(0);
                    let mode = map
                        .get("mode")
                        .and_then(|v| v.as_str())
                        .and_then(|s| s.parse::<monty_types::FileMode>().ok())
                        .unwrap_or(monty_types::FileMode::Read(false));
                    MontyObject::FileHandle(monty_types::MontyFileHandle {
                        path,
                        mode,
                        position,
                    })
                }
                "ellipsis" => MontyObject::Ellipsis,
                "bigint" => {
                    let text = map.get("value").and_then(|v| v.as_str()).unwrap_or("");
                    text.parse::<BigInt>()
                        .map(MontyObject::BigInt)
                        .map_err(|e| format!("bad bigint {text:?}: {e}"))?
                }
                "float" => {
                    // Three groups of floats arrive tagged, and this arm used to
                    // accept only the first:
                    //
                    //   1. non-finite — no JSON number representation at all;
                    //   2. integral (`2.0`) — a JSON number reparses it as `2`;
                    //   3. negative zero — `JSON.stringify(-0)` is `"0"`.
                    //
                    // Groups 2 and 3 are Tier 3 (core#128): the text is the only
                    // place the distinction survives the web transport, so the
                    // Dart encoder sends them tagged (monty_value_scalars.dart).
                    // The encoder moved and this decoder did not, so a host
                    // callback returning a plain `2.0` was rejected outright.
                    //
                    // `f64::from_str` handles all three, including "NaN",
                    // "Infinity" and "-Infinity", and preserves the sign of
                    // "-0.0". Parsing rather than matching is also what keeps
                    // the two directions from drifting again.
                    let text = map.get("value").and_then(|v| v.as_str()).unwrap_or("");
                    match text.parse::<f64>() {
                        Ok(value) => MontyObject::Float(value),
                        Err(e) => {
                            return Err(format!("bad float {text:?}: {e}"));
                        }
                    }
                }
                "exception" => {
                    let exc = map.get("exc_type").and_then(|v| v.as_str()).unwrap_or("");
                    let arg = map
                        .get("message")
                        .and_then(|v| v.as_str())
                        .map(std::string::ToString::to_string);
                    MontyObject::Exception {
                        exc_type: exc
                            .parse::<monty_types::ExcType>()
                            .map_err(|_| format!("unknown exception type {exc:?}"))?,
                        arg,
                    }
                }
                "builtin" => {
                    let text = map.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    MontyObject::BuiltinFunction(
                        text.parse::<monty_types::BuiltinsFunctions>()
                            .map_err(|_| format!("unknown builtin {text:?}"))?,
                    )
                }
                // Host-side OBSERVATIONS of interpreter internals, not values the
                // interpreter can be handed back. `type` names a class this side
                // cannot construct; `function` and `repr` carry a rendering, not
                // the callable or the object; `cycle` marks a place in a graph
                // that does not exist over here. Rejected rather than
                // approximated — silently substituting something plausible is
                // the class of bug this whole change removes.
                kind @ ("type" | "function" | "repr" | "cycle") => {
                    return Err(format!(
                        "a {kind} cannot be sent back into the interpreter: it is a \
                         host-side rendering, not a constructible value"
                    ));
                }
                unknown => {
                    return Err(format!(
                        "unknown __type {unknown:?}: the decoder rejects what it does not \
                         understand rather than guessing a dict (rule R4)"
                    ));
                }
            }
        }
    })
}

/// Integers that fit i64 stay JSON numbers; the rest get a tagged envelope.
///
/// They used to become a BARE JSON string, so `2**63` arrived in Dart as a
/// `MontyString` and a value's TYPE depended on its magnitude (core#134). The
/// digits travel as text either way — JSON numbers cannot hold them — but now
/// the envelope says they are an integer.
/// The largest magnitude every backend can hold in a Dart `int`.
///
/// On dart2js `int` IS a double, so 2^53 is the exact-integer ceiling there —
/// `JSON.parse("9007199254740993")` measurably returns `…992`. Beyond this an
/// integer cannot be a `MontyInt` on all three backends, so it becomes a
/// `MontyBigInt` on ALL of them rather than changing type per backend, which
/// would break invariant I1.
const EXACT_INT_LIMIT: i64 = 1 << 53;

/// True when `n` needs the bigint envelope to survive the web transport.
fn needs_bigint_envelope(n: i64) -> bool {
    !(-EXACT_INT_LIMIT..=EXACT_INT_LIMIT).contains(&n)
}

/// Encode an `i64` — as a JSON number when that is lossless everywhere.
fn int_to_json(n: i64) -> Value {
    if needs_bigint_envelope(n) {
        json!({ "__type": "bigint", "value": n.to_string() })
    } else {
        json!(n)
    }
}

fn bigint_to_json(n: &BigInt) -> Value {
    match n.to_i64() {
        Some(i) if !needs_bigint_envelope(i) => json!(i),
        _ => json!({ "__type": "bigint", "value": n.to_string() }),
    }
}

/// Finite floats stay JSON numbers; NaN and the infinities get an envelope.
///
/// They used to be the bare strings "NaN"/"Infinity"/"-Infinity", which the Dart
/// decoder turned back into floats — so the Python STRING `"NaN"` also decoded as
/// `MontyFloat(NaN)`. Two different values, one wire representation.
///
/// Tier 3 will envelope finite floats too, for the int/float and signed-zero
/// distinctions the web transport destroys (core#128). This is only the
/// non-finite half, which is a pure R2 fix and needs no measurement.
fn float_to_json(f: f64) -> Value {
    if !f.is_finite() {
        let text = if f.is_nan() {
            "NaN"
        } else if f.is_sign_positive() {
            "Infinity"
        } else {
            "-Infinity"
        };

        return json!({ "__type": "float", "value": text });
    }

    // Tier 3, and the whole of core#128: the int/float distinction and the sign
    // of zero live ONLY in a JSON number's text, and the web transport reparses
    // that text (`JSON.parse("4.0") === 4`, `JSON.stringify(-0) === "0"`). A
    // value carried as a tagged STRING cannot be damaged by either.
    //
    // Only the two ambiguous shapes are tagged, so ordinary floats stay JSON
    // numbers and the corpus does not grow: measured at 1.00x bytes on integer
    // and realistic-float payloads, where tagging every number cost 6.52x and
    // 17.4x round-trip latency.
    if f.fract() == 0.0 || (f == 0.0 && f.is_sign_negative()) {
        return json!({ "__type": "float", "value": format_exact_float(f) });
    }

    Number::from_f64(f).map_or(Value::Null, Value::Number)
}

/// Render a finite float so Python can read the type back off the text.
///
/// `4.0` must not print as `4`, and `-0.0` must keep its sign — those two facts
/// are the payload. Rust's `{:?}` gives `4.0` and `-0.0`; `{}` gives `4` and
/// `-0`, which is exactly the loss being fixed.
fn format_exact_float(f: f64) -> String {
    format!("{f:?}")
}

fn number_to_monty_object(n: &Number) -> MontyObject {
    if let Some(i) = n.as_i64() {
        MontyObject::Int(i)
    } else if let Some(f) = n.as_f64() {
        MontyObject::Float(f)
    } else {
        // u64 that doesn't fit i64
        MontyObject::BigInt(BigInt::from(n.as_u64().unwrap_or(0)))
    }
}

/// Encode a dict as a TAGGED envelope — never as a bare object or array.
///
/// This is rule R1 of `WIRE-CONTRACT.md`, and it is what closes core#136. A bare
/// object was byte-identical to a tagged envelope, so sandboxed Python returning
/// the plain dict `{"__type": "path", "value": "x"}` arrived in Dart as a genuine
/// `MontyPath` — untrusted code choosing its own host type. Now user keys live
/// inside `value`/`entries`, which the decoder reads as dict CONTENTS and never
/// re-dispatches, so no arrangement of user data can name a type.
///
/// Two payload shapes, because Python dict keys are not restricted to strings:
///
/// - `{"__type": "dict", "value": {k: v}}`   — all keys are `str` (the common case)
/// - `{"__type": "dict", "entries": [[k, v]]}` — any other key type
///
/// The `entries` form preserves key TYPES, which the old bare-array form also did
/// — but that array decoded as a `MontyList`, silently turning a dict into a
/// sequence. It now decodes as `MontyPairsDict`.
fn dict_to_json(pairs: &monty_types::DictPairs) -> Value {
    // Collect pairs via the &DictPairs IntoIterator impl.
    let items: Vec<&(MontyObject, MontyObject)> = pairs.into_iter().collect();
    let all_string_keys = items
        .iter()
        .all(|(k, _)| matches!(k, MontyObject::String(_)));

    if all_string_keys {
        let map: serde_json::Map<String, Value> = items
            .into_iter()
            .map(|(k, v)| {
                let key = match k {
                    MontyObject::String(s) => s.clone(),
                    _ => unreachable!(),
                };
                (key, monty_object_to_json(v))
            })
            .collect();
        json!({ "__type": "dict", "value": Value::Object(map) })
    } else {
        json!({
            "__type": "dict",
            "entries": Value::Array(
                items
                    .into_iter()
                    .map(|(k, v)| json!([monty_object_to_json(k), monty_object_to_json(v)]))
                    .collect(),
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_none() {
        assert_eq!(monty_object_to_json(&MontyObject::None), Value::Null);
    }

    #[test]
    fn test_bool() {
        assert_eq!(monty_object_to_json(&MontyObject::Bool(true)), json!(true));
        assert_eq!(
            monty_object_to_json(&MontyObject::Bool(false)),
            json!(false)
        );
    }

    #[test]
    fn test_int() {
        assert_eq!(monty_object_to_json(&MontyObject::Int(42)), json!(42));
        assert_eq!(monty_object_to_json(&MontyObject::Int(-1)), json!(-1));
        assert_eq!(monty_object_to_json(&MontyObject::Int(0)), json!(0));
    }

    #[test]
    fn test_bigint_fits_i64() {
        let n = BigInt::from(123_456_789i64);
        assert_eq!(
            monty_object_to_json(&MontyObject::BigInt(n)),
            json!(123_456_789)
        );
    }

    #[test]
    fn test_bigint_too_large() {
        let n = BigInt::parse_bytes(b"99999999999999999999999", 10).unwrap();
        let val = monty_object_to_json(&MontyObject::BigInt(n.clone()));
        // Tier 2: was a BARE string, so `2**63` decoded as MontyString and a
        // value's type depended on its magnitude (core#134). The digits still
        // travel as text — JSON numbers cannot hold them — but tagged.
        assert_eq!(val, json!({"__type": "bigint", "value": n.to_string()}));
    }

    #[test]
    fn test_float() {
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(3.125)),
            json!(3.125)
        );
    }

    #[test]
    fn test_float_nan() {
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(f64::NAN)),
            // Was the bare string "NaN", which made the STRING "NaN" decode as
            // a float. Tagged since Tier 2.
            json!({"__type": "float", "value": "NaN"})
        );
    }

    #[test]
    fn test_float_infinity() {
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(f64::INFINITY)),
            json!({"__type": "float", "value": "Infinity"})
        );
        assert_eq!(
            monty_object_to_json(&MontyObject::Float(f64::NEG_INFINITY)),
            json!({"__type": "float", "value": "-Infinity"})
        );
    }

    #[test]
    fn test_string() {
        assert_eq!(
            monty_object_to_json(&MontyObject::String("hello".into())),
            json!("hello")
        );
    }

    #[test]
    fn test_list() {
        let list = MontyObject::List(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        assert_eq!(monty_object_to_json(&list), json!([1, 2]));
    }

    #[test]
    fn test_tuple() {
        let tuple = MontyObject::Tuple(vec![MontyObject::Bool(true), MontyObject::None]);
        assert_eq!(
            monty_object_to_json(&tuple),
            json!({"__type": "tuple", "value": [true, null]})
        );
    }

    #[test]
    fn test_dict_string_keys() {
        let pairs = vec![
            (MontyObject::String("a".into()), MontyObject::Int(1)),
            (MontyObject::String("b".into()), MontyObject::Int(2)),
        ];
        let dict = MontyObject::dict(pairs);
        let val = monty_object_to_json(&dict);
        // Wire v2: the tag belongs to the ENVELOPE and user keys live under
        // `value`. Asserted on the whole object, not field-by-field, so a
        // regression to a bare object cannot pass.
        assert_eq!(val, json!({"__type": "dict", "value": {"a": 1, "b": 2}}));
    }

    #[test]
    fn test_dict_non_string_keys() {
        let pairs = vec![
            (MontyObject::Int(1), MontyObject::String("a".into())),
            (MontyObject::Int(2), MontyObject::String("b".into())),
        ];
        let dict = MontyObject::dict(pairs);
        let val = monty_object_to_json(&dict);
        // Wire v2: was a bare array, which decoded as a MontyList — a dict
        // silently becoming a sequence. Now tagged, and decodes as a dict.
        assert_eq!(
            val,
            json!({"__type": "dict", "entries": [[1, "a"], [2, "b"]]})
        );
    }

    #[test]
    fn test_set() {
        let set = MontyObject::Set(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        assert_eq!(
            monty_object_to_json(&set),
            json!({"__type": "set", "value": [1, 2]})
        );
    }

    #[test]
    fn test_ellipsis() {
        assert_eq!(
            monty_object_to_json(&MontyObject::Ellipsis),
            json!({ "__type": "ellipsis" })
        );
    }

    #[test]
    fn test_bytes() {
        let bytes = MontyObject::Bytes(vec![72, 105]);
        assert_eq!(
            monty_object_to_json(&bytes),
            json!({"__type": "bytes", "value": [72, 105]})
        );
    }

    // Round-trip tests
    #[test]
    fn test_round_trip_null() {
        let original = MontyObject::None;
        let json = monty_object_to_json(&original);
        let back = json_to_monty_object(&json).expect("round-trip decode");
        assert!(matches!(back, MontyObject::None));
    }

    #[test]
    fn test_round_trip_bool() {
        let json = monty_object_to_json(&MontyObject::Bool(true));
        let back = json_to_monty_object(&json).expect("round-trip decode");
        assert!(matches!(back, MontyObject::Bool(true)));
    }

    #[test]
    fn test_round_trip_int() {
        let json = monty_object_to_json(&MontyObject::Int(42));
        let back = json_to_monty_object(&json).expect("round-trip decode");
        assert!(matches!(back, MontyObject::Int(42)));
    }

    #[test]
    fn test_round_trip_string() {
        let json = monty_object_to_json(&MontyObject::String("hello".into()));
        let back = json_to_monty_object(&json).expect("round-trip decode");
        assert!(matches!(back, MontyObject::String(ref s) if s == "hello"));
    }

    #[test]
    fn test_round_trip_list() {
        let list = MontyObject::List(vec![MontyObject::Int(1), MontyObject::None]);
        let json = monty_object_to_json(&list);
        let back = json_to_monty_object(&json).expect("round-trip decode");
        match back {
            MontyObject::List(items) => {
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(items[1], MontyObject::None));
            }
            _ => panic!("expected list"),
        }
    }

    /// An untagged object is REJECTED as of wire format v2.
    ///
    /// This test previously asserted the opposite — that `{"key": "value"}`
    /// decoded to a dict — and that behaviour is exactly core#136 pointed the
    /// other way: anything unrecognised became a plausible value. Inverted
    /// deliberately, not deleted, so the change of contract is visible in the
    /// history of the test that used to pin it.
    #[test]
    fn test_untagged_object_is_rejected() {
        let err = json_to_monty_object(&json!({"key": "value"}))
            .expect_err("an untagged object must not decode");
        assert!(err.contains("untagged"), "unhelpful message: {err}");
    }

    #[test]
    fn test_unknown_type_tag_is_rejected() {
        let err = json_to_monty_object(&json!({"__type": "nope", "value": 1}))
            .expect_err("an unknown __type must not decode");
        assert!(err.contains("unknown __type"), "unhelpful message: {err}");
    }

    #[test]
    fn test_dict_envelope_string_keys() {
        let obj = json_to_monty_object(&json!({"__type": "dict", "value": {"key": "value"}}))
            .expect("decode dict envelope");
        match obj {
            MontyObject::Dict(pairs) => {
                let items: Vec<_> = pairs.into_iter().collect::<Vec<_>>();
                assert_eq!(items.len(), 1);
            }
            other => panic!("expected dict, got {other:?}"),
        }
    }

    #[test]
    fn test_dict_envelope_entries_preserves_key_types() {
        let obj = json_to_monty_object(&json!({
            "__type": "dict",
            "entries": [[1, "a"], [{"__type": "tuple", "value": [1, 2]}, "b"]],
        }))
        .expect("decode entries envelope");
        match obj {
            MontyObject::Dict(pairs) => {
                let items: Vec<_> = pairs.into_iter().collect::<Vec<_>>();
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0].0, MontyObject::Int(1)));
                assert!(matches!(items[1].0, MontyObject::Tuple(_)));
            }
            other => panic!("expected dict, got {other:?}"),
        }
    }

    #[test]
    fn test_malformed_dict_envelope_is_rejected() {
        let err = json_to_monty_object(&json!({"__type": "dict"}))
            .expect_err("a dict envelope with no payload must not decode");
        assert!(
            err.contains("value") && err.contains("entries"),
            "msg: {err}"
        );

        let err = json_to_monty_object(&json!({"__type": "dict", "entries": [[1]]}))
            .expect_err("a 1-element entry is not a [key, value] pair");
        assert!(err.contains("pair"), "unhelpful message: {err}");
    }

    /// core#136, in the encoder's own terms: a Python dict whose KEYS spell a
    /// type envelope must round-trip as a dict.
    ///
    /// Before Tier 1 the encoder emitted this dict as a bare object that was
    /// byte-identical to a real `path` envelope, so the value changed type in
    /// transit. Now the user's keys sit inside the payload, which the decoder
    /// reads as contents and never re-dispatches.
    #[test]
    fn test_forged_type_envelope_stays_a_dict() {
        let forged = MontyObject::dict(vec![
            (
                MontyObject::String("__type".into()),
                MontyObject::String("path".into()),
            ),
            (
                MontyObject::String("value".into()),
                MontyObject::String("/etc/passwd".into()),
            ),
        ]);

        let json = monty_object_to_json(&forged);
        assert_eq!(json["__type"], "dict", "the ENVELOPE must own the tag");
        assert_eq!(json["value"]["__type"], "path", "user keys stay in payload");

        match json_to_monty_object(&json).expect("decode forged dict") {
            MontyObject::Dict(pairs) => {
                let items: Vec<_> = pairs.into_iter().collect::<Vec<_>>();
                assert_eq!(items.len(), 2, "both user keys survive");
            }
            other => panic!("FORGERY: decoded as {other:?} instead of a dict"),
        }
    }

    #[test]
    fn test_named_tuple() {
        let nt = MontyObject::NamedTuple {
            type_name: "Point".into(),
            field_names: vec!["x".into(), "y".into()],
            values: vec![MontyObject::Int(1), MontyObject::Int(2)],
        };
        assert_eq!(
            monty_object_to_json(&nt),
            json!({"__type": "namedtuple", "type_name": "Point", "field_names": ["x", "y"], "values": [1, 2]})
        );
    }

    #[test]
    fn test_path() {
        let p = MontyObject::Path("/tmp/foo".into());
        assert_eq!(
            monty_object_to_json(&p),
            json!({"__type": "path", "value": "/tmp/foo"})
        );
    }

    #[test]
    fn test_dataclass() {
        let dc = MontyObject::Dataclass {
            name: "MyClass".into(),
            type_id: 1,
            field_names: vec!["a".into()],
            attrs: vec![(MontyObject::String("a".into()), MontyObject::Int(42))].into(),
            frozen: false,
        };
        let val = monty_object_to_json(&dc);
        assert_eq!(val["__type"], json!("dataclass"));
        assert_eq!(val["name"], json!("MyClass"));
        // `attrs` is a dict, so it carries the dict envelope like any other —
        // there is no "except inside dataclass" carve-out to remember.
        assert_eq!(val["attrs"], json!({"__type": "dict", "value": {"a": 42}}));
    }

    #[test]
    fn test_exception_with_arg() {
        let exc = MontyObject::Exception {
            exc_type: monty_types::ExcType::ValueError,
            arg: Some("bad value".into()),
        };
        // exc_type and message travel separately now. Joined with ": " they were
        // byte-identical to the STRING "ValueError: bad value", and a message
        // containing ": " could not be recovered.
        assert_eq!(
            monty_object_to_json(&exc),
            json!({
                "__type": "exception",
                "exc_type": "ValueError",
                "message": "bad value",
            })
        );
    }

    #[test]
    fn test_exception_no_arg() {
        let exc = MontyObject::Exception {
            exc_type: monty_types::ExcType::RuntimeError,
            arg: None,
        };
        assert_eq!(
            monty_object_to_json(&exc),
            json!({
                "__type": "exception",
                "exc_type": "RuntimeError",
                "message": null,
            })
        );
    }

    #[test]
    fn test_repr() {
        let r = MontyObject::Repr("<object at 0x123>".into());
        assert_eq!(
            monty_object_to_json(&r),
            json!({"__type": "repr", "text": "<object at 0x123>"})
        );
    }

    #[test]
    fn test_frozen_set() {
        let fs = MontyObject::FrozenSet(vec![MontyObject::Int(3), MontyObject::Int(4)]);
        assert_eq!(
            monty_object_to_json(&fs),
            json!({"__type": "frozenset", "value": [3, 4]})
        );
    }

    #[test]
    fn test_json_to_monty_float() {
        let val = json!(3.125);
        let obj = json_to_monty_object(&val).expect("decode float");
        match obj {
            MontyObject::Float(f) => assert!((f - 3.125).abs() < f64::EPSILON),
            _ => panic!("expected Float"),
        }
    }

    // =========================================================================
    // Round-trip coverage for EVERY MontyObject variant
    //
    // These tests document the current serialization behavior.
    // Variants marked "LOSSY" lose type information during the round-trip
    // (monty → JSON → monty). These need typed JSON wrappers to fix.
    // =========================================================================

    /// Helper: serialize to JSON then deserialize back.
    fn round_trip(obj: &MontyObject) -> MontyObject {
        let json = monty_object_to_json(obj);
        json_to_monty_object(&json).expect("round-trip decode")
    }

    // --- Lossless round-trips (these work correctly) ---

    #[test]
    fn rt_none() {
        assert!(matches!(round_trip(&MontyObject::None), MontyObject::None));
    }

    #[test]
    fn rt_bool_true() {
        assert!(matches!(
            round_trip(&MontyObject::Bool(true)),
            MontyObject::Bool(true)
        ));
    }

    #[test]
    fn rt_bool_false() {
        assert!(matches!(
            round_trip(&MontyObject::Bool(false)),
            MontyObject::Bool(false)
        ));
    }

    #[test]
    fn rt_int() {
        assert!(matches!(
            round_trip(&MontyObject::Int(42)),
            MontyObject::Int(42)
        ));
    }

    #[test]
    fn rt_int_negative() {
        assert!(matches!(
            round_trip(&MontyObject::Int(-99)),
            MontyObject::Int(-99)
        ));
    }

    #[test]
    #[expect(
        clippy::approx_constant,
        reason = "3.14 is the test value, not a PI approximation"
    )]
    fn rt_float() {
        match round_trip(&MontyObject::Float(3.14)) {
            MontyObject::Float(f) => assert!((f - 3.14).abs() < f64::EPSILON),
            other => panic!("expected Float, got {other:?}"),
        }
    }

    #[test]
    fn rt_string() {
        match round_trip(&MontyObject::String("hello".into())) {
            MontyObject::String(s) => assert_eq!(s, "hello"),
            other => panic!("expected String, got {other:?}"),
        }
    }

    #[test]
    fn rt_list() {
        let obj = MontyObject::List(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        match round_trip(&obj) {
            MontyObject::List(items) => {
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(items[1], MontyObject::Int(2)));
            }
            other => panic!("expected List, got {other:?}"),
        }
    }

    /// Helper: a Dict's (key, value) pairs as comparable strings, IN ORDER.
    fn dict_pairs(obj: MontyObject) -> Vec<(String, i64)> {
        match obj {
            MontyObject::Dict(pairs) => pairs
                .into_iter()
                .map(|(k, v)| {
                    let key = match k {
                        MontyObject::String(s) => s,
                        other => panic!("expected String key, got {other:?}"),
                    };
                    let val = match v {
                        MontyObject::Int(i) => i,
                        other => panic!("expected Int value, got {other:?}"),
                    };
                    (key, val)
                })
                .collect(),
            other => panic!("expected Dict, got {other:?}"),
        }
    }

    #[test]
    fn rt_dict_string_keys() {
        let obj = MontyObject::dict(vec![
            (MontyObject::String("a".into()), MontyObject::Int(1)),
            (MontyObject::String("b".into()), MontyObject::Int(2)),
        ]);
        // Assert the actual contents, not just the count: a length-only check
        // passes even if the keys are renamed, reordered, or the values swapped.
        assert_eq!(
            dict_pairs(round_trip(&obj)),
            vec![("a".to_string(), 1), ("b".to_string(), 2)]
        );
    }

    /// Python dicts are insertion-ordered, and that order is observable through
    /// `list(d)`, iteration and `repr(d)`. We lost it: `serde_json` without the
    /// `preserve_order` feature backs `Map` with a sorted `BTreeMap`, so
    /// `{"b":…, "a":…}` came back as `{"a":…, "b":…}` (core#129).
    ///
    /// The keys here are deliberately NOT in sorted order — with a `BTreeMap`
    /// this test fails, which is the whole point. The conformance corpus could
    /// never have caught this: exactly one of its 531 fixtures returns a dict,
    /// and that one's keys are already sorted.
    #[test]
    fn rt_dict_preserves_insertion_order() {
        let obj = MontyObject::dict(vec![
            (MontyObject::String("b".into()), MontyObject::Int(1)),
            (MontyObject::String("a".into()), MontyObject::Int(2)),
            (MontyObject::String("c".into()), MontyObject::Int(3)),
        ]);
        assert_eq!(
            dict_pairs(round_trip(&obj)),
            vec![
                ("b".to_string(), 1),
                ("a".to_string(), 2),
                ("c".to_string(), 3)
            ],
            "dict insertion order must survive the JSON round-trip"
        );
    }

    // =========================================================================
    // LOSSLESS round-trip tests — these define CORRECT behavior.
    //
    // These tests WILL FAIL until convert.rs is updated with __type wrappers.
    // When the refactor is complete, all tests pass.
    // =========================================================================

    // --- Date ---

    #[test]
    fn rt_date() {
        let obj = MontyObject::Date(monty_types::MontyDate {
            year: 2026,
            month: 4,
            day: 9,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 2026);
                assert_eq!(d.month, 4);
                assert_eq!(d.day, 9);
            }
            other => panic!("expected Date, got {other:?}"),
        }
    }

    #[test]
    fn rt_date_min() {
        let obj = MontyObject::Date(monty_types::MontyDate {
            year: 1,
            month: 1,
            day: 1,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 1);
                assert_eq!(d.month, 1);
                assert_eq!(d.day, 1);
            }
            other => panic!("expected Date min, got {other:?}"),
        }
    }

    #[test]
    fn rt_date_max() {
        let obj = MontyObject::Date(monty_types::MontyDate {
            year: 9999,
            month: 12,
            day: 31,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 9999);
                assert_eq!(d.month, 12);
                assert_eq!(d.day, 31);
            }
            other => panic!("expected Date max, got {other:?}"),
        }
    }

    #[test]
    fn rt_date_leap_day() {
        let obj = MontyObject::Date(monty_types::MontyDate {
            year: 2024,
            month: 2,
            day: 29,
        });
        match round_trip(&obj) {
            MontyObject::Date(d) => {
                assert_eq!(d.year, 2024);
                assert_eq!(d.month, 2);
                assert_eq!(d.day, 29);
            }
            other => panic!("expected Date leap day, got {other:?}"),
        }
    }

    // --- DateTime ---

    #[test]
    fn rt_datetime_naive() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 4,
            day: 9,
            hour: 14,
            minute: 30,
            second: 45,
            microsecond: 0,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.year, 2026);
                assert_eq!(dt.month, 4);
                assert_eq!(dt.day, 9);
                assert_eq!(dt.hour, 14);
                assert_eq!(dt.minute, 30);
                assert_eq!(dt.second, 45);
                assert_eq!(dt.microsecond, 0);
                assert_eq!(dt.offset_seconds, None);
                assert_eq!(dt.timezone_name, None);
            }
            other => panic!("expected naive DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_utc() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            microsecond: 0,
            offset_seconds: Some(0),
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.offset_seconds, Some(0));
                assert_eq!(dt.timezone_name, None);
            }
            other => panic!("expected UTC DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_positive_offset() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 6,
            day: 15,
            hour: 10,
            minute: 0,
            second: 0,
            microsecond: 0,
            offset_seconds: Some(19800), // +05:30
            timezone_name: Some("IST".into()),
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.offset_seconds, Some(19800));
                assert_eq!(dt.timezone_name, Some("IST".into()));
            }
            other => panic!("expected +05:30 DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_negative_offset() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 12,
            day: 25,
            hour: 18,
            minute: 30,
            second: 0,
            microsecond: 0,
            offset_seconds: Some(-18000), // -05:00
            timezone_name: Some("EST".into()),
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.offset_seconds, Some(-18000));
                assert_eq!(dt.timezone_name, Some("EST".into()));
            }
            other => panic!("expected -05:00 DateTime, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_microseconds() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 4,
            day: 9,
            hour: 14,
            minute: 30,
            second: 0,
            microsecond: 123_456,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => assert_eq!(dt.microsecond, 123_456),
            other => panic!("expected DateTime with microseconds, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_max_microseconds() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 4,
            day: 9,
            hour: 23,
            minute: 59,
            second: 59,
            microsecond: 999_999,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.hour, 23);
                assert_eq!(dt.minute, 59);
                assert_eq!(dt.second, 59);
                assert_eq!(dt.microsecond, 999_999);
            }
            other => panic!("expected DateTime end-of-day, got {other:?}"),
        }
    }

    #[test]
    fn rt_datetime_midnight() {
        let obj = MontyObject::DateTime(monty_types::MontyDateTime {
            year: 2026,
            month: 1,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0,
            microsecond: 0,
            offset_seconds: None,
            timezone_name: None,
        });
        match round_trip(&obj) {
            MontyObject::DateTime(dt) => {
                assert_eq!(dt.hour, 0);
                assert_eq!(dt.minute, 0);
                assert_eq!(dt.second, 0);
            }
            other => panic!("expected midnight DateTime, got {other:?}"),
        }
    }

    // --- TimeDelta ---

    #[test]
    fn rt_timedelta() {
        let obj = MontyObject::TimeDelta(monty_types::MontyTimeDelta {
            days: 1,
            seconds: 3600,
            microseconds: 500,
        });
        match round_trip(&obj) {
            MontyObject::TimeDelta(td) => {
                assert_eq!(td.days, 1);
                assert_eq!(td.seconds, 3600);
                assert_eq!(td.microseconds, 500);
            }
            other => panic!("expected TimeDelta, got {other:?}"),
        }
    }

    #[test]
    fn rt_timedelta_zero() {
        let obj = MontyObject::TimeDelta(monty_types::MontyTimeDelta {
            days: 0,
            seconds: 0,
            microseconds: 0,
        });
        match round_trip(&obj) {
            MontyObject::TimeDelta(td) => {
                assert_eq!(td.days, 0);
                assert_eq!(td.seconds, 0);
                assert_eq!(td.microseconds, 0);
            }
            other => panic!("expected zero TimeDelta, got {other:?}"),
        }
    }

    #[test]
    fn rt_timedelta_negative() {
        let obj = MontyObject::TimeDelta(monty_types::MontyTimeDelta {
            days: -5,
            seconds: 43200,
            microseconds: 0,
        });
        match round_trip(&obj) {
            MontyObject::TimeDelta(td) => {
                assert_eq!(td.days, -5);
                assert_eq!(td.seconds, 43200);
            }
            other => panic!("expected negative TimeDelta, got {other:?}"),
        }
    }

    // --- TimeZone ---

    #[test]
    fn rt_timezone_utc() {
        let obj = MontyObject::TimeZone(monty_types::MontyTimeZone {
            offset_seconds: 0,
            name: None,
        });
        match round_trip(&obj) {
            MontyObject::TimeZone(tz) => {
                assert_eq!(tz.offset_seconds, 0);
                assert_eq!(tz.name, None);
            }
            other => panic!("expected UTC TimeZone, got {other:?}"),
        }
    }

    #[test]
    fn rt_timezone_named() {
        let obj = MontyObject::TimeZone(monty_types::MontyTimeZone {
            offset_seconds: -18000,
            name: Some("EST".into()),
        });
        match round_trip(&obj) {
            MontyObject::TimeZone(tz) => {
                assert_eq!(tz.offset_seconds, -18000);
                assert_eq!(tz.name, Some("EST".into()));
            }
            other => panic!("expected named TimeZone, got {other:?}"),
        }
    }

    #[test]
    fn rt_timezone_positive() {
        let obj = MontyObject::TimeZone(monty_types::MontyTimeZone {
            offset_seconds: 32400, // +09:00
            name: Some("JST".into()),
        });
        match round_trip(&obj) {
            MontyObject::TimeZone(tz) => {
                assert_eq!(tz.offset_seconds, 32400);
                assert_eq!(tz.name, Some("JST".into()));
            }
            other => panic!("expected +09:00 TimeZone, got {other:?}"),
        }
    }

    // --- Path ---

    #[test]
    fn rt_path() {
        let obj = MontyObject::Path("/tmp/foo".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, "/tmp/foo"),
            other => panic!("expected Path, got {other:?}"),
        }
    }

    #[test]
    fn rt_path_with_spaces() {
        let obj = MontyObject::Path("/my path/has spaces".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, "/my path/has spaces"),
            other => panic!("expected Path with spaces, got {other:?}"),
        }
    }

    #[test]
    fn rt_path_unicode() {
        let obj = MontyObject::Path("/données/café.txt".into());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, "/données/café.txt"),
            other => panic!("expected unicode Path, got {other:?}"),
        }
    }

    #[test]
    fn rt_path_empty() {
        let obj = MontyObject::Path(String::new());
        match round_trip(&obj) {
            MontyObject::Path(p) => assert_eq!(p, ""),
            other => panic!("expected empty Path, got {other:?}"),
        }
    }

    // --- Tuple ---

    #[test]
    fn rt_tuple() {
        let obj = MontyObject::Tuple(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 2);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(items[1], MontyObject::Int(2)));
            }
            other => panic!("expected Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_empty() {
        let obj = MontyObject::Tuple(vec![]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => assert!(items.is_empty()),
            other => panic!("expected empty Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_single() {
        let obj = MontyObject::Tuple(vec![MontyObject::String("solo".into())]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 1);
                assert!(matches!(&items[0], MontyObject::String(s) if s == "solo"));
            }
            other => panic!("expected single-element Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_mixed_types() {
        let obj = MontyObject::Tuple(vec![
            MontyObject::Int(1),
            MontyObject::String("two".into()),
            MontyObject::Bool(true),
            MontyObject::None,
        ]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 4);
                assert!(matches!(items[0], MontyObject::Int(1)));
                assert!(matches!(&items[1], MontyObject::String(s) if s == "two"));
                assert!(matches!(items[2], MontyObject::Bool(true)));
                assert!(matches!(items[3], MontyObject::None));
            }
            other => panic!("expected mixed Tuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_tuple_nested() {
        let inner = MontyObject::Tuple(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        let obj = MontyObject::Tuple(vec![inner, MontyObject::Int(3)]);
        match round_trip(&obj) {
            MontyObject::Tuple(items) => {
                assert_eq!(items.len(), 2);
                match &items[0] {
                    MontyObject::Tuple(inner) => {
                        assert_eq!(inner.len(), 2);
                        assert!(matches!(inner[0], MontyObject::Int(1)));
                    }
                    other => panic!("expected nested Tuple, got {other:?}"),
                }
            }
            other => panic!("expected outer Tuple, got {other:?}"),
        }
    }

    // --- Set ---

    #[test]
    fn rt_set() {
        let obj = MontyObject::Set(vec![MontyObject::Int(1), MontyObject::Int(2)]);
        match round_trip(&obj) {
            MontyObject::Set(items) => {
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected Set, got {other:?}"),
        }
    }

    #[test]
    fn rt_set_empty() {
        let obj = MontyObject::Set(vec![]);
        match round_trip(&obj) {
            MontyObject::Set(items) => assert!(items.is_empty()),
            other => panic!("expected empty Set, got {other:?}"),
        }
    }

    // --- FrozenSet ---

    #[test]
    fn rt_frozenset() {
        let obj = MontyObject::FrozenSet(vec![MontyObject::Int(3), MontyObject::Int(4)]);
        match round_trip(&obj) {
            MontyObject::FrozenSet(items) => {
                assert_eq!(items.len(), 2);
            }
            other => panic!("expected FrozenSet, got {other:?}"),
        }
    }

    #[test]
    fn rt_frozenset_empty() {
        let obj = MontyObject::FrozenSet(vec![]);
        match round_trip(&obj) {
            MontyObject::FrozenSet(items) => assert!(items.is_empty()),
            other => panic!("expected empty FrozenSet, got {other:?}"),
        }
    }

    // --- Bytes ---

    #[test]
    fn rt_bytes() {
        let obj = MontyObject::Bytes(vec![72, 105]);
        match round_trip(&obj) {
            MontyObject::Bytes(b) => assert_eq!(b, vec![72, 105]),
            other => panic!("expected Bytes, got {other:?}"),
        }
    }

    #[test]
    fn rt_bytes_empty() {
        let obj = MontyObject::Bytes(vec![]);
        match round_trip(&obj) {
            MontyObject::Bytes(b) => assert!(b.is_empty()),
            other => panic!("expected empty Bytes, got {other:?}"),
        }
    }

    #[test]
    fn rt_bytes_full_range() {
        let obj = MontyObject::Bytes((0u8..=255).collect());
        match round_trip(&obj) {
            MontyObject::Bytes(b) => {
                assert_eq!(b.len(), 256);
                assert_eq!(b[0], 0);
                assert_eq!(b[255], 255);
            }
            other => panic!("expected full-range Bytes, got {other:?}"),
        }
    }

    // --- NamedTuple ---

    #[test]
    fn rt_named_tuple() {
        let obj = MontyObject::NamedTuple {
            type_name: "Point".into(),
            field_names: vec!["x".into(), "y".into()],
            values: vec![MontyObject::Int(10), MontyObject::Int(20)],
        };
        match round_trip(&obj) {
            MontyObject::NamedTuple {
                type_name,
                field_names,
                values,
            } => {
                assert_eq!(type_name, "Point");
                assert_eq!(field_names, vec!["x", "y"]);
                assert_eq!(values.len(), 2);
                assert!(matches!(values[0], MontyObject::Int(10)));
                assert!(matches!(values[1], MontyObject::Int(20)));
            }
            other => panic!("expected NamedTuple, got {other:?}"),
        }
    }

    #[test]
    fn rt_named_tuple_empty() {
        let obj = MontyObject::NamedTuple {
            type_name: "Empty".into(),
            field_names: vec![],
            values: vec![],
        };
        match round_trip(&obj) {
            MontyObject::NamedTuple {
                type_name,
                field_names,
                values,
            } => {
                assert_eq!(type_name, "Empty");
                assert!(field_names.is_empty());
                assert!(values.is_empty());
            }
            other => panic!("expected empty NamedTuple, got {other:?}"),
        }
    }

    // --- Dataclass ---

    #[test]
    fn rt_dataclass() {
        let obj = MontyObject::Dataclass {
            name: "MyClass".into(),
            type_id: 1,
            field_names: vec!["x".into(), "y".into()],
            attrs: vec![
                (MontyObject::String("x".into()), MontyObject::Int(42)),
                (
                    MontyObject::String("y".into()),
                    MontyObject::String("hello".into()),
                ),
            ]
            .into(),
            frozen: false,
        };
        match round_trip(&obj) {
            MontyObject::Dataclass {
                name,
                type_id,
                field_names,
                frozen,
                ..
            } => {
                assert_eq!(name, "MyClass");
                assert_eq!(type_id, 1);
                assert_eq!(field_names, vec!["x", "y"]);
                assert!(!frozen);
            }
            other => panic!("expected Dataclass, got {other:?}"),
        }
    }

    #[test]
    fn rt_dataclass_frozen() {
        let obj = MontyObject::Dataclass {
            name: "Frozen".into(),
            type_id: 99,
            field_names: vec!["a".into()],
            attrs: vec![(MontyObject::String("a".into()), MontyObject::Bool(true))].into(),
            frozen: true,
        };
        match round_trip(&obj) {
            MontyObject::Dataclass { name, frozen, .. } => {
                assert_eq!(name, "Frozen");
                assert!(frozen);
            }
            other => panic!("expected frozen Dataclass, got {other:?}"),
        }
    }

    // --- BigInt (large values stay lossy — JSON has no big-int type) ---

    #[test]
    fn rt_bigint_large_round_trips_exactly() {
        // Was `rt_bigint_large_stays_lossy`, asserting MontyObject::String "by
        // design — JSON has no native big-integer type". The premise was true and
        // the conclusion was not: JSON has no big-integer type, but the envelope
        // says what the text means, so nothing is lost. core#134.
        let n = BigInt::parse_bytes(b"99999999999999999999999", 10).unwrap();
        let obj = MontyObject::BigInt(n.clone());
        match round_trip(&obj) {
            MontyObject::BigInt(back) => assert_eq!(back, n, "exact digits"),
            other => panic!("expected BigInt, got {other:?}"),
        }
    }

    // --- Representational types (not data, just display) ---

    /// This test used to be `rt_ellipsis_becomes_string`, and it ASSERTED THE
    /// BUG: that `...` round-trips as the string `"..."`. A test that pins
    /// lossy behaviour as correct makes the defect permanent, and this one
    /// did exactly that until core#129.
    #[test]
    fn rt_ellipsis_round_trips_losslessly() {
        assert!(
            matches!(round_trip(&MontyObject::Ellipsis), MontyObject::Ellipsis),
            "Ellipsis must survive the JSON round-trip"
        );
    }

    /// The point of the envelope: `...` and the string `"..."` must not
    /// collapse onto each other.
    #[test]
    fn rt_ellipsis_is_distinguishable_from_the_string() {
        let dots = MontyObject::String("...".into());
        assert_ne!(
            monty_object_to_json(&MontyObject::Ellipsis),
            monty_object_to_json(&dots),
            "Ellipsis and the string \"...\" must serialize differently"
        );
        assert!(
            matches!(round_trip(&dots), MontyObject::String(ref s) if s == "..."),
            "the string \"...\" must still round-trip as a string"
        );
    }

    // ---- Control a' (P2) ------------------------------------------------
    //
    // The 482-fixture oracle suite CANNOT see a bug in this file: oracle.rs
    // includes convert.rs via #[path], so the FFI side and the oracle side share
    // it and agree even when both are wrong. These tests are the independent
    // check — expectations are derived from the monty 0.19 TYPE DEFINITIONS, not
    // from running the interpreter.
    //
    // Diffing MontyObject across v0.0.18 -> v0.0.19 (see
    // artifacts/monty-api-diff-018-019.txt) shows 27 variants on both sides,
    // none added or removed, and exactly three payload changes:
    //
    //   Cycle(HeapId, String)          -> Cycle(usize, String)
    //   Type(monty::types::type::Type) -> Type(monty_types::MontyType)
    //   BuiltinFunction(builtins::..)  -> BuiltinFunction(monty_types::..)
    //
    // Those three are therefore the entire convert.rs risk surface for this
    // upgrade, and each is pinned below.
    //
    // The previous note here said Type and BuiltinFunction "are not tested
    // because the inner types are private to the monty crate". That is obsolete:
    // 0.19 made MontyType and BuiltinsFunctions public in monty-types, so the two
    // variants that were previously untestable now are.

    #[test]
    fn cycle_ignores_its_id_field() {
        // Cycle's first field changed HeapId -> usize in 0.19. We discard it and
        // emit only the description, so the change is inert — pin that, because a
        // future edit that starts emitting the id would silently alter output
        // that no oracle comparison could flag.
        let a = monty_object_to_json(&MontyObject::Cycle(0, "[...]".into()));
        let b = monty_object_to_json(&MontyObject::Cycle(999_999, "[...]".into()));
        assert_eq!(a, json!({"__type": "cycle", "text": "[...]"}));
        assert_eq!(a, b, "the id field must not affect JSON output");
    }

    #[test]
    fn type_serializes_via_display() {
        // The expected string is LITERAL on purpose. Asserting against
        // `MontyType::Bool.to_string()` would recompute exactly what
        // `monty_object_to_json` already does, so an upstream change to that
        // `Display` impl would sail through green while our wire output silently
        // changed — the tautology this control exists to avoid. Verified against
        // the interpreter: `type(True)` marshals to "bool".
        let obj = MontyObject::Type(monty_types::MontyType::Bool);
        assert_eq!(
            monty_object_to_json(&obj),
            json!({"__type": "type", "text": "bool"})
        );
    }

    #[test]
    fn builtin_function_serializes_via_debug() {
        // Literal for the same reason as the Type test above: recomputing the
        // Debug impl under test would make the assertion unfalsifiable.
        let obj = MontyObject::BuiltinFunction(monty_types::BuiltinsFunctions::Abs);
        // "abs", not "Abs". Debug printed Rust's variant name, so the wire
        // carried a Rust identifier where a reader expects the Python name.
        assert_eq!(
            monty_object_to_json(&obj),
            json!({"__type": "builtin", "text": "abs"})
        );
    }

    #[test]
    fn a_function_is_tagged_and_refused_on_the_way_back() {
        // Was `rt_function_becomes_string`. Two changes: the wire says `function`
        // rather than handing over a bare string, and sending one back is now an
        // ERROR instead of silently becoming a str. A rendering of a callable is
        // not a callable, and approximating one is the class of bug Tier 1 and
        // Tier 2 exist to remove.
        let obj = MontyObject::Function {
            name: "my_func".into(),
            docstring: Some("does stuff".into()),
        };
        let json = monty_object_to_json(&obj);
        assert_eq!(
            json,
            json!({"__type": "function", "text": "<function my_func>"})
        );

        let err = json_to_monty_object(&json).expect_err("must not decode");
        assert!(err.contains("cannot be sent back"), "message: {err}");
    }

    #[test]
    fn rt_exception_round_trips_as_an_exception() {
        // Was `rt_exception_becomes_string`, asserting "ValueError: bad" — the
        // exact bytes of the STRING "ValueError: bad". Nothing downstream could
        // tell an exception from prose describing one.
        let obj = MontyObject::Exception {
            exc_type: monty_types::ExcType::ValueError,
            arg: Some("bad".into()),
        };
        match round_trip(&obj) {
            MontyObject::Exception { exc_type, arg } => {
                assert_eq!(exc_type, monty_types::ExcType::ValueError);
                assert_eq!(arg.as_deref(), Some("bad"));
            }
            other => panic!("expected Exception, got {other:?}"),
        }
    }

    /// A message containing ": " survives, which the joined form could not.
    #[test]
    fn rt_exception_message_with_colon_space() {
        let obj = MontyObject::Exception {
            exc_type: monty_types::ExcType::ValueError,
            arg: Some("expected: got 3".into()),
        };
        match round_trip(&obj) {
            MontyObject::Exception { arg, .. } => {
                assert_eq!(arg.as_deref(), Some("expected: got 3"));
            }
            other => panic!("expected Exception, got {other:?}"),
        }
    }

    #[test]
    fn an_exception_and_a_string_that_looks_like_one_differ_on_the_wire() {
        // The clearest single statement of what Tier 2 fixed.
        let exc = monty_object_to_json(&MontyObject::Exception {
            exc_type: monty_types::ExcType::ValueError,
            arg: Some("boom".into()),
        });
        let text = monty_object_to_json(&MontyObject::String("ValueError: boom".into()));
        assert_ne!(exc, text, "these used to be byte-identical");
    }

    #[test]
    fn a_repr_is_tagged_and_refused_on_the_way_back() {
        let obj = MontyObject::Repr("<object>".into());
        let json = monty_object_to_json(&obj);
        assert_eq!(json, json!({"__type": "repr", "text": "<object>"}));
        assert!(
            json_to_monty_object(&json)
                .expect_err("must not decode")
                .contains("cannot be sent back")
        );
    }

    #[test]
    fn a_builtin_round_trips_by_its_python_name() {
        let obj = MontyObject::BuiltinFunction(monty_types::BuiltinsFunctions::Abs);
        match round_trip(&obj) {
            MontyObject::BuiltinFunction(f) => {
                assert_eq!(f, monty_types::BuiltinsFunctions::Abs);
            }
            other => panic!("expected BuiltinFunction, got {other:?}"),
        }
    }

    #[test]
    fn non_finite_floats_round_trip_and_the_string_nan_stays_a_string() {
        for f in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            match round_trip(&MontyObject::Float(f)) {
                MontyObject::Float(back) => {
                    // Compared by PROPERTY, not by `==`: clippy forbids strict
                    // float comparison, and NaN != NaN would make an equality
                    // assertion wrong here anyway.
                    assert_eq!(back.is_nan(), f.is_nan(), "nan-ness of {f}");
                    assert_eq!(back.is_infinite(), f.is_infinite(), "infinity of {f}");
                    assert_eq!(back.is_sign_negative(), f.is_sign_negative(), "sign of {f}");
                }
                other => panic!("expected Float for {f}, got {other:?}"),
            }
        }

        // The other half of the same defect: these are DIFFERENT values and used
        // to share one wire representation.
        match round_trip(&MontyObject::String("NaN".into())) {
            MontyObject::String(s) => assert_eq!(s, "NaN"),
            other => panic!("the string \"NaN\" must stay a string, got {other:?}"),
        }
    }

    // --- Edge case: dict with __type key should NOT be hijacked ---

    #[test]
    fn rt_dict_with_type_key_stays_dict() {
        // A plain Python dict that happens to contain "__type" must NOT be
        // misinterpreted as a typed wrapper. It should round-trip as a dict.
        let obj = MontyObject::dict(vec![
            (
                MontyObject::String("__type".into()),
                MontyObject::String("date".into()),
            ),
            (
                MontyObject::String("value".into()),
                MontyObject::String("not-a-date".into()),
            ),
        ]);
        // After the refactor, json_to_monty_object will see __type:"date" and
        // try to parse it as a MontyDate. This is the correct behavior —
        // if Dart sends {"__type":"date","year":...} it means "this is a date".
        // A plain dict should never have __type unless it's intentionally typed.
        // This test documents that __type IS the discriminator.
        let json = monty_object_to_json(&obj);
        let parsed = json.as_object().unwrap();
        // Dict with string keys serializes as JSON object — no __type wrapper added
        assert!(
            !parsed.contains_key("__type") || parsed.len() > 1,
            "plain dict should not gain extra __type wrapper"
        );
    }

    // -------------------------------------------------------------------
    // A malformed envelope is a DECODE ERROR, never a panic and never a
    // silently-substituted zero (core A2).
    //
    // Both defects lived on one line each: `map["key"]` is the panicking
    // `Index` impl, and `.unwrap_or(0)` swallowed a wrong-typed field.
    //
    // Measured in Chrome against the shipped wasm BEFORE this fix, driving the
    // bridge directly (which is not WireJson-gated):
    //
    //   {"__type":"date","year":2020}                  -> error "unreachable",
    //       and the REPL session was left permanently in
    //       "handle not in Idle or Complete state" — bricked, with an error
    //       naming neither a panic nor a cause. A fresh session still worked,
    //       so this destroys a session rather than the module.
    //   {"__type":"datetime",...,"hour":"XX",...}      -> ok:true,
    //       datetime.datetime(2020, 1, 1, 0, 0). Silently zeroed.
    // -------------------------------------------------------------------

    fn decode_err(json: &str) -> String {
        let v: Value = serde_json::from_str(json).expect("test json parses");
        json_to_monty_object(&v).expect_err("expected a decode error")
    }

    #[test]
    fn missing_envelope_field_is_an_error_not_a_panic() {
        let err = decode_err(r#"{"__type":"date","year":2020}"#);
        assert!(err.contains("date"), "{err}");
        assert!(err.contains("month"), "names the missing field: {err}");
    }

    #[test]
    fn wrong_typed_field_is_an_error_not_a_silent_zero() {
        let err = decode_err(
            r#"{"__type":"datetime","year":2020,"month":1,"day":1,
                "hour":"XX","minute":0,"second":0,"microsecond":0}"#,
        );
        assert!(err.contains("hour"), "names the field: {err}");
        assert!(err.contains("integer"), "says what was expected: {err}");
    }

    #[test]
    fn out_of_range_field_is_an_error() {
        let err = decode_err(r#"{"__type":"date","year":2020,"month":99999999999,"day":1}"#);
        assert!(err.contains("month"), "{err}");
    }

    #[test]
    fn a_present_but_wrong_typed_optional_is_still_an_error() {
        // Absent is fine; present-and-wrong is not. A caller who supplied the
        // key meant something by it.
        let err = decode_err(
            r#"{"__type":"datetime","year":2020,"month":1,"day":1,"hour":0,
                "minute":0,"second":0,"microsecond":0,"offset_seconds":"XX"}"#,
        );
        assert!(err.contains("offset_seconds"), "{err}");
    }

    #[test]
    fn a_well_formed_envelope_still_decodes() {
        let v: Value =
            serde_json::from_str(r#"{"__type":"date","year":2020,"month":1,"day":2}"#).unwrap();
        match json_to_monty_object(&v).expect("well-formed date decodes") {
            MontyObject::Date(d) => {
                assert_eq!((d.year, d.month, d.day), (2020, 1, 2));
            }
            other => panic!("expected a date, got {other:?}"),
        }
    }

    #[test]
    fn malformed_bytes_and_names_are_errors_too() {
        assert!(decode_err(r#"{"__type":"bytes","value":[1,999]}"#).contains("255"));
        assert!(
            decode_err(r#"{"__type":"path"}"#).contains("value"),
            "a path with no value names the field"
        );
        assert!(
            decode_err(r#"{"__type":"namedtuple","type_name":"P","values":[]}"#)
                .contains("field_names")
        );
    }
}
