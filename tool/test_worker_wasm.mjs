#!/usr/bin/env node
// Drives the worker's wasm32-wasip1 module through its dmw_* exports, as a Web
// Worker host will: Configure with a bounded max_memory, then consecutive
// Feeds whose replies are each a large share of that budget.
//
// The allocator charges every live allocation to the session's memory budget,
// so a reply buffer still allocated during the NEXT turn eats into it. Each
// turn must see the budget whole: turn N's reply is the host's to copy before
// turn N+1, and is released when turn N+1 starts.
//
// Usage: node tool/test_worker_wasm.mjs <dart_monty_worker.wasm>
// Build: cd native/worker && cargo build --locked --profile mixd --lib --target wasm32-wasip1
import { readFileSync } from 'node:fs';
import { WASI } from 'node:wasi';

const MAX_MEMORY = 1_000_000;
// Over half the budget: two of these live at once cannot fit.
const REPLY_CHARS = 600_000;
const TURNS = 3;

// --- minimal protobuf -------------------------------------------------------
const varint = (n) => {
  const out = [];
  let v = BigInt(n);
  do {
    let b = Number(v & 0x7fn);
    v >>= 7n;
    if (v) b |= 0x80;
    out.push(b);
  } while (v);
  return out;
};
const field = (no, wire) => varint((no << 3) | wire);
const vint = (no, n) => [...field(no, 0), ...varint(n)];
const bytes = (no, b) => [...field(no, 2), ...varint(b.length), ...b];
const str = (no, s) => bytes(no, [...new TextEncoder().encode(s)]);

/** Top-level fields of one message: [{no, wire, value}], value a Uint8Array for wire 2. */
function decode(buf) {
  const fields = [];
  let o = 0;
  const u = () => {
    let r = 0n, s = 0n, b;
    do { b = buf[o++]; r |= BigInt(b & 0x7f) << s; s += 7n; } while (b & 0x80);
    return r;
  };
  while (o < buf.length) {
    const key = Number(u());
    const no = key >> 3, wire = key & 7;
    if (wire === 0) fields.push({ no, wire, value: u() });
    else if (wire === 2) {
      const len = Number(u());
      fields.push({ no, wire, value: buf.subarray(o, o + len) });
      o += len;
    } else if (wire === 1) { o += 8; }
    else if (wire === 5) { o += 4; }
    else throw new Error(`unsupported wire type ${wire}`);
  }
  return fields;
}
const text = (b) => new TextDecoder().decode(b);

// ChildEvent oneof `kind` (monty.proto).
const KIND = { 1: 'Print', 2: 'FunctionCall', 3: 'OsCall', 4: 'NameLookup', 5: 'ResolveFutures',
  6: 'Complete', 7: 'Error', 8: 'TypingError', 9: 'DumpResult', 10: 'Ok', 11: 'FatalError', 12: 'Shutdown' };

/** Splits a reply into ChildEvents and names each: [{kind, detail}]. */
function events(reply) {
  const out = [];
  const view = new DataView(reply.buffer, reply.byteOffset, reply.byteLength);
  for (let o = 0; o < reply.length;) {
    const len = view.getUint32(o, true);
    const ev = decode(reply.subarray(o + 4, o + 4 + len));
    o += 4 + len;
    const k = ev.find((f) => KIND[f.no]);
    if (!k) throw new Error('ChildEvent carried no kind');
    let detail = '';
    if (k.no === 7) {
      // Error { RaisedException exception = 1 { exc_type = 1; message = 2 } }
      const exc = decode(decode(k.value).find((f) => f.no === 1).value);
      detail = exc.filter((f) => f.no <= 2).map((f) => text(f.value)).join(': ');
    } else if (k.no === 11) {
      detail = text(decode(k.value).find((f) => f.no === 1)?.value ?? new Uint8Array());
    }
    out.push({ kind: KIND[k.no], detail });
  }
  return out;
}

// --- the module -------------------------------------------------------------
const path = process.argv[2];
if (!path) {
  console.error('usage: node tool/test_worker_wasm.mjs <dart_monty_worker.wasm>');
  process.exit(2);
}
const wasi = new WASI({ version: 'preview1', args: [], env: {}, returnOnExit: true });
const { instance } = await WebAssembly.instantiate(readFileSync(path), wasi.getImportObject());
wasi.initialize(instance);
const x = instance.exports;

function turn(request) {
  const frame = new Uint8Array(4 + request.length);
  new DataView(frame.buffer).setUint32(0, request.length, true);
  frame.set(request, 4);
  const ptr = x.dmw_alloc(frame.length);
  new Uint8Array(x.memory.buffer, ptr, frame.length).set(frame);
  const out = x.dmw_dispatch(ptr, frame.length);
  x.dmw_free(ptr, frame.length);
  // Copied out at once: the reply is valid only until the next call.
  const reply = new Uint8Array(x.memory.buffer, out, x.dmw_out_len()).slice();
  return { outcome: x.dmw_last_outcome(), events: events(reply), bytes: reply.length };
}

let failed = 0;
const check = (ok, what) => {
  console.log(`${ok ? 'OK  ' : 'FAIL'}  ${what}`);
  if (!ok) failed++;
};
const ends = (r) => r.events.at(-1) ?? { kind: 'none', detail: '' };

// ParentRequest { configure = 1 { script_name = 1, limits = 2 { max_memory_bytes = 2 }, protocol_version = 9 } }
const configure = bytes(1, [...str(1, 'main.py'), ...bytes(2, vint(2, MAX_MEMORY)),
  ...vint(9, x.dmw_protocol_version())]);
const c = turn(configure);
check(c.outcome === 0 && ends(c).kind === 'Ok', `Configure max_memory=${MAX_MEMORY}: ${ends(c).kind}`);

// ParentRequest { feed = 3 { code = 1, cwd = 5 } }
const feed = bytes(3, [...str(1, `'a' * ${REPLY_CHARS}`), ...str(5, '/')]);
for (let i = 1; i <= TURNS; i++) {
  let r;
  try {
    r = turn(feed);
  } catch (e) {
    // A breached hard limit ends the instance (trap or proc_exit).
    check(false, `Feed ${i}: instance died: ${e}`);
    break;
  }
  const e = ends(r);
  check(r.outcome === 0 && e.kind === 'Complete' && r.bytes > REPLY_CHARS,
    `Feed ${i}: ${e.kind}${e.detail ? ` (${e.detail})` : ''}, reply ${r.bytes} bytes`);
}

console.log(failed ? `\n${failed} check(s) failed` : '\nworker wasm: PASS');
process.exit(failed ? 1 : 0);
