// dart_monty_core_worker.js: the Web Worker behind WorkerChannel
// (lib/src/worker/worker_channel.dart). Hand-written, not bundled: it is the
// source, edited in place. It runs dart_monty_core_worker.wasm, which the
// page compiles ONCE and posts to every Worker.
//
// Messages, page -> Worker -> page:
//   {module: WebAssembly.Module, noJspi: bool}
//       -> {ready: true, jspi: bool, protocol: number} | {ready: false, error}
//   Uint8Array (one length-prefixed ParentRequest frame)
//       -> {print: Uint8Array}* then {events, outcome} | {trap, stderr}
//   {ack: number} acknowledges settled print bytes.
//
// Prints leave at each flush; events holds only the turn-ending frame.
// A trap poisons the instance; the page terminates it.
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
const PRINT_WINDOW = 4 * 1024 * 1024;
let unacknowledged = 0;
let resume;

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
  if (typeof WebAssembly.promising !== 'function' || typeof WebAssembly.Suspending !== 'function') return false;
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
    const host = {
      emit(ptr, len) {
        const print = bytes().slice(ptr, ptr + len);
        unacknowledged += len;
        self.postMessage({ print }, [print.buffer]);
        return Math.min(unacknowledged, 0xffffffff);
      },
      wait: typeof WebAssembly.Suspending === 'function'
        ? new WebAssembly.Suspending(() => unacknowledged < PRINT_WINDOW
            ? Promise.resolve() : new Promise(resolve => { resume = resolve; }))
        : () => { throw new Error('wait without JSPI'); },
    };
    const instance = await WebAssembly.instantiate(module, {
      wasi_snapshot_preview1: wasi, dmw_host: host,
    });
    exports = instance.exports;
    dispatch = exports.dmw_dispatch;
    const jspi = noJspi ? false : await probeJspi();
    if (jspi) exports.dmw_set_backpressure(1);
    self.postMessage({ ready: true, jspi, protocol: exports.dmw_protocol_version() });
  } catch (err) {
    self.postMessage({ ready: false, error: String(err) });
  }
}

async function turn(request) {
  try {
    const ptr = exports.dmw_alloc(request.length);
    try {
      bytes().set(request, ptr);
    } catch (err) {
      exports.dmw_free(ptr, request.length);
      throw err;
    }
    // dispatch owns the buffer, including when execution traps.
    const out = await dispatch(ptr, request.length);
    const events = bytes().slice(out, out + exports.dmw_out_len());
    self.postMessage({ events, outcome: exports.dmw_last_outcome() }, [events.buffer]);
  } catch (err) {
    self.postMessage({ trap: String(err), stderr });
  }
}

self.onmessage = (e) => {
  const data = e.data;
  if (data && Number.isSafeInteger(data.ack) && data.ack >= 0) {
    unacknowledged = Math.max(0, unacknowledged - data.ack);
    if (resume && unacknowledged < PRINT_WINDOW) {
      const resolve = resume;
      resume = undefined;
      resolve();
    }
  } else if (data instanceof Uint8Array) {
    turn(data);
  } else if (data && data.module instanceof WebAssembly.Module) {
    start(data);
  }
};
