// dart_monty_core_proto_worker.js: the Web Worker behind WorkerChannel
// (lib/src/worker/worker_channel.dart). Hand-written, not bundled: it is the
// source, edited in place. It runs dart_monty_core_proto_worker.wasm, which the
// page compiles ONCE and posts to every Worker.
//
// Messages, page -> Worker -> page:
//   {module: WebAssembly.Module, noJspi: bool}
//       -> {ready: true, jspi: bool, protocol: number} | {ready: false, error}
//   Uint8Array (one length-prefixed ParentRequest frame)
//       -> {events: Uint8Array, outcome: 0 | 1 | 2} | {trap: string}
//
// `events` holds every frame of the turn (Prints, then the turn-ending event),
// buffered by monty-proto's dispatch_frame. `outcome` is dmw_last_outcome():
// 0 Continue, 1 Shutdown, 2 Fatal. A trap poisons the instance; the page
// terminates this Worker and never sends it another request.
//
// JSPI: when the probe passes, dmw_dispatch runs under WebAssembly.promising,
// on its own larger stack. The probe is feature detection AND one real
// dispatch of an empty request through the wrapper, which must come back as a
// Continue with no events. Any failure falls back to a direct call.
'use strict';

let exports;
let dispatch;
const STDERR_TAIL = 4096;
let stderr = '';

const view = () => new DataView(exports.memory.buffer);
const bytes = () => new Uint8Array(exports.memory.buffer);
const decoder = new TextDecoder();

// The seven WASI imports the module needs, nothing more.
const wasi = {
  random_get(buf, len) {
    for (let i = 0; i < len; i += 65536) {
      crypto.getRandomValues(bytes().subarray(buf + i, buf + Math.min(len, i + 65536)));
    }
    return 0;
  },
  clock_time_get(id, _precision, out) {
    const ns = id === 0
      ? BigInt(Date.now()) * 1000000n
      : BigInt(Math.round(performance.now() * 1e6));
    view().setBigUint64(out, ns, true);
    return 0;
  },
  fd_write(_fd, iovs, count, written) {
    let total = 0;
    for (let i = 0; i < count; i++) {
      const ptr = view().getUint32(iovs + i * 8, true);
      const len = view().getUint32(iovs + i * 8 + 4, true);
      stderr = (stderr + decoder.decode(bytes().slice(ptr, ptr + len))).slice(-STDERR_TAIL);
      total += len;
    }
    view().setUint32(written, total, true);
    return 0;
  },
  environ_get() { return 0; },
  environ_sizes_get(count, size) {
    view().setUint32(count, 0, true);
    view().setUint32(size, 0, true);
    return 0;
  },
  proc_exit(code) { throw new Error(`proc_exit(${code})`); },
  sched_yield() { return 0; },
};

async function probeJspi() {
  if (typeof WebAssembly.promising !== 'function') return false;
  try {
    const promising = WebAssembly.promising(exports.dmw_dispatch);
    await promising(0, 0);
    if (exports.dmw_out_len() !== 0 || exports.dmw_last_outcome() !== 0) return false;
    dispatch = promising;
    return true;
  } catch (_) {
    return false;
  }
}

async function start({ module, noJspi }) {
  try {
    const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi });
    exports = instance.exports;
    dispatch = exports.dmw_dispatch;
    const jspi = noJspi ? false : await probeJspi();
    self.postMessage({ ready: true, jspi, protocol: exports.dmw_protocol_version() });
  } catch (err) {
    self.postMessage({ ready: false, error: String(err) });
  }
}

async function turn(request) {
  try {
    const ptr = exports.dmw_alloc(request.length);
    bytes().set(request, ptr);
    let events;
    try {
      const out = await dispatch(ptr, request.length);
      events = bytes().slice(out, out + exports.dmw_out_len());
    } finally {
      exports.dmw_free(ptr, request.length);
    }
    self.postMessage({ events, outcome: exports.dmw_last_outcome() }, [events.buffer]);
  } catch (err) {
    self.postMessage({ trap: String(err) + (stderr ? `; stderr: ${stderr}` : '') });
  }
}

self.onmessage = (e) => {
  const data = e.data;
  if (data instanceof Uint8Array) {
    turn(data);
  } else if (data && data.module instanceof WebAssembly.Module) {
    start(data);
  }
};
