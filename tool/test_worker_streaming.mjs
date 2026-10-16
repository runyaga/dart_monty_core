// Runs the shipped browser shim in Node worker threads when Chrome is unavailable.
// Expectations come from the R-1 Python binding probes and transport contracts.
// Usage: node tool/test_worker_streaming.mjs [name substring]
// R1_WASM / R1_SHIM optionally select the base artifacts for a red run.
import { Worker } from 'node:worker_threads';
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
const module = await WebAssembly.compile(readFileSync(process.env.R1_WASM ?? 'lib/assets/dart_monty_core_worker.wasm'));
const shim = readFileSync(process.env.R1_SHIM ?? 'lib/assets/dart_monty_core_worker.js', 'utf8');
const vint = (n) => {
  const b = [];
  do {
    b.push((n & 127) | (n > 127 ? 128 : 0));
    n = Math.floor(n / 128);
  } while (n);
  return Buffer.from(b);
};
const field = (n, b) => Buffer.concat([vint(n * 8 + 2), vint(b.length), b]);
const num = (n, x) => Buffer.concat([vint(n * 8), vint(x)]);
const str = (n, x) => field(n, Buffer.from(x));
const frame = (b) => {
  const h = Buffer.alloc(4);
  h.writeUInt32LE(b.length);
  return new Uint8Array(Buffer.concat([h, b]));
};
const feed = (code, size = 0) => field(3, Buffer.concat([
  str(1, code), ...(size ? [field(2, str(1, 'x')), field(3, field(2, field(9, Buffer.alloc(size))))] : []),
]));
function kinds(data) {
  const out = [];
  for (let i = 0; i < data.length;) {
    const len = new DataView(data.buffer, data.byteOffset + i, 4).getUint32(0, true);
    out.push(data[i + 4] >> 3);
    i += len + 4;
  }
  return out;
}
async function open(noJspi, maxMemory) {
  const worker = new Worker(`const {parentPort} = require('node:worker_threads');
    globalThis.self = {postMessage: (m, transfer) => parentPort.postMessage(m, transfer)};
    ${shim}
    parentPort.on('message', data => self.onmessage({data}));`, {eval: true});
  const hello = new Promise((resolve, reject) => { worker.once('message', resolve); worker.once('error', reject); });
  worker.postMessage({module, noJspi});
  const greeting = await hello;
  if (!greeting.ready) {
    await worker.terminate();
    assert.fail(`worker failed to start: ${greeting.error}`);
  }
  let pending;
  const printed = [];
  let unacked = 0;
  let peak = 0;
  let acknowledge = true;
  worker.on('message', m => {
    if (m.print) {
      printed.push(performance.now());
      unacked += m.print.length;
      peak = Math.max(peak, unacked);
      if (acknowledge) {
        worker.postMessage({ack: m.print.length});
        unacked -= m.print.length;
      }
    } else {
      pending?.(m);
      pending = null;
    }
  });
  const turn = request => new Promise(resolve => {
    pending = resolve;
    worker.postMessage(frame(request));
  });
  const config = field(1, Buffer.concat([str(1, 'main.py'), num(9, 5), num(10, 0), ...(maxMemory ? [field(2, num(2, maxMemory))] : [])]));
  assert.deepEqual(kinds((await turn(config)).events), [10]);
  return {
    worker, turn, printed,
    get peak() { return peak; },
    hold() { acknowledge = false; },
    release() {
      acknowledge = true;
      worker.postMessage({ack: unacked});
      unacked = 0;
    },
  };
}
let passed = 0, failed = 0;
async function test(name, run) {
  if (process.argv[2] && !name.includes(process.argv[2])) return;
  const timer = setTimeout(() => { console.error('TIMEOUT', name); process.exit(1); }, 30000);
  try { await run(); console.log('PASS', name); passed++; }
  catch (e) { console.error('FAIL', name, e.message); failed++; }
  finally { clearTimeout(timer); }
}
for (const noJspi of [false, true]) {
  await test(`streaming early print noJspi=${noJspi}`, async () => {
    const c = await open(noJspi);
    try {
      const end = await c.turn(feed("import time\nprint('early')\nt = time.monotonic() + 1.5\nwhile time.monotonic() < t:\n    pass\nprint('late')"));
      assert.ok(!end.trap, `unexpected trap: ${end.trap}`);
      assert.ok(c.printed.length >= 2, 'prints must leave before the reply');
      assert.ok(c.printed.at(-1) - c.printed[0] >= 1000, 'early/late gap >= 1 second');
      assert.deepEqual(kinds(end.events), [6]);
    } finally { await c.worker.terminate(); }
  });
  await test(`print before kill noJspi=${noJspi}`, async () => {
    const c = await open(noJspi);
    try {
      c.turn(feed("print('early')\nwhile True:\n    pass"));
      await new Promise(resolve => setTimeout(resolve, 1500));
      assert.ok(c.printed.length > 0, 'early print delivered before timeout kills worker');
    } finally { await c.worker.terminate(); }
  });
  await test(`volume under limit noJspi=${noJspi}`, async () => {
    const c = await open(noJspi, 2000000);
    try {
      const end = await c.turn(feed("for i in range(20000):\n    print('x' * 200)\n42"));
      assert.ok(!end.trap, `unexpected trap: ${end.trap}`);
      assert.equal(kinds(end.events).at(-1), 6, 'volume must complete under its memory limit');
    } finally { await c.worker.terminate(); }
  });
  for (const size of [700000, 2000000, 10000000]) {
    await test(`memory ${size} noJspi=${noJspi}`, async () => {
      const c = await open(noJspi, 1000000);
      try {
        const end = await c.turn(feed('len(x)', size));
        if (size === 10000000) assert.match(end.stderr ?? '', /^monty worker: allocation of \d+ bytes (exceeds the memory limit|failed)\n?$/);
        else assert.deepEqual(kinds(end.events ?? new Uint8Array()), [size === 700000 ? 6 : 7]);
      } finally { await c.worker.terminate(); }
    });
  }
  await test(`window noJspi=${noJspi}`, async () => {
    const c = await open(noJspi);
    try {
      c.hold();
      const turn = c.turn(feed("for i in range(16384):\n    print('x' * 1023)\n42"));
      await new Promise(resolve => setTimeout(resolve, 1200));
      assert.ok(c.peak > 4 * 1024 * 1024, 'worker crossed the window');
      if (!noJspi) assert.ok(c.peak <= 4 * 1024 * 1024 + 1100, `peak ${c.peak}`);
      else assert.ok(c.peak >= 16 * 1024 * 1024, 'fallback never waits');
      c.release();
      assert.deepEqual(kinds((await turn).events), [6]);
    } finally { await c.worker.terminate(); }
  });
}
console.log(`${passed} passed; ${failed} failed`);
const expected = process.argv[2] ? passed + failed > 0 : passed + failed === 14;
if (!expected) console.error('FAIL test-count floor');
process.exitCode = failed || !expected ? 1 : 0;
