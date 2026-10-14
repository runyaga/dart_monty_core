// The consumer-startup driver: loads one built consumer app in headless Chrome
// from a static server and passes only if the page writes the expected result
// into #result AND the worker assets were served from the expected base.
//
// Usage:
//   node tool/consumers/drive.mjs --root <build dir> --layout flutter|package
//        [--page index.html] [--expect 2] [--timeout 60000] [--skip-assets]
//        [--require <path>]... [--forbid <path>]...
//
// Exit 0 = pass, 1 = fail (the reason is printed), 2 = usage/environment error.
//
// What it checks, beyond "the DOM reads 2":
//   - no uncaught exception and no console error (Chrome's own
//     "Failed to load resource" line for the one allowed 404 below excepted);
//   - dart_monty_core_worker.js and .wasm were each served 200 from the
//     layout's base (--layout), so a page that found its worker somewhere else
//     fails;
//   - the only non-2xx request for a worker asset is the other layout's
//     script probe (the factory tries the Flutter base first, then the
//     package base), and nothing outside the layout's base served a worker
//     asset.
// --require/--forbid name a request path (e.g. /main.dart.wasm) that must / must
// not have been served 200: they pin WHICH compiler's output ran, because a
// Flutter --wasm build silently falls back to its JavaScript build when the
// browser lacks a capability, and `2` alone would pass on either.
// --skip-assets drops the two asset checks, for the driver's own self-test pages.
// The page is served cross-origin isolated (COOP/COEP), as a wasm-threaded
// Flutter build needs.
//
// The server is ours so that it records what was actually requested; Chrome's
// own logs do not report every failed subresource fetch (tool/check_pages.sh
// measured this). Node 22+ for the global WebSocket.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { extname, join, normalize, resolve, sep } from 'node:path';

const BASES = {
  flutter: 'assets/packages/dart_monty_core/lib/assets',
  package: 'packages/dart_monty_core/assets',
};
const WORKER = 'dart_monty_core_worker';
const MIME = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.wasm': 'application/wasm', '.json': 'application/json', '.map': 'application/json',
  '.css': 'text/css', '.png': 'image/png', '.ico': 'image/x-icon', '.txt': 'text/plain',
};

function args() {
  const a = { page: 'index.html', expect: '2', timeout: 60000, skipAssets: false, require: [], forbid: [] };
  const argv = process.argv.slice(2);
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--skip-assets') a.skipAssets = true;
    else if (k === '--require' || k === '--forbid') a[k.slice(2)].push(argv[++i]);
    else if (['--root', '--layout', '--page', '--expect', '--timeout'].includes(k)) a[k.slice(2)] = argv[++i];
    else { console.error(`unknown argument ${k}`); process.exit(2); }
  }
  a.timeout = Number(a.timeout);
  if (!a.root || !existsSync(a.root)) { console.error('--root must name an existing directory'); process.exit(2); }
  if (!a.skipAssets && !BASES[a.layout]) { console.error('--layout must be flutter or package'); process.exit(2); }
  if (typeof WebSocket === 'undefined') { console.error(`needs a global WebSocket (Node >= 22); running ${process.version}`); process.exit(2); }
  return a;
}

function findChrome() {
  const candidates = [process.env.CHROME, 'google-chrome-stable', 'google-chrome', 'chromium', 'chromium-browser',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'].filter(Boolean);
  for (const c of candidates) {
    if (c.includes('/') ? existsSync(c) : (process.env.PATH ?? '').split(':').some(d => existsSync(join(d, c)))) return c;
  }
  console.error('Chrome not found (set CHROME): this gate cannot run, and is not skipped silently');
  process.exit(2);
}

const a = args();
const root = resolve(a.root);
const requests = []; // {status, path}
const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  const file = normalize(join(root, path === '/' ? '/index.html' : path));
  let status = 200;
  let body = null;
  if (!file.startsWith(root + sep) || !existsSync(file) || !statSync(file).isFile()) status = 404;
  else body = readFileSync(file);
  requests.push({ status, path });
  res.writeHead(status, {
    'content-type': status === 200 ? (MIME[extname(file)] ?? 'application/octet-stream') : 'text/plain',
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-embedder-policy': 'require-corp',
  });
  res.end(status === 200 ? body : 'not found');
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;

const profile = mkdtempSync(join(tmpdir(), 'consumer-drive-'));
const chrome = spawn(findChrome(), ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage',
  // Software WebGL: Flutter's skwasm renderer needs WebGL, and without it the
  // --wasm build quietly loads its JavaScript fallback instead.
  '--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader',
  `--user-data-dir=${profile}`, '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const cleanup = async () => {
  const exited = new Promise(r => (chrome.exitCode !== null ? r() : chrome.once('exit', r)));
  try { chrome.kill('SIGKILL'); } catch {}
  await Promise.race([exited, new Promise(r => setTimeout(r, 5000))]);
  server.close();
  try { rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); } catch {}
};

// Killing the driver must not leave Chrome or its profile behind.
for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143]]) {
  process.on(sig, async () => { await cleanup(); process.exit(code); });
}
process.on('exit', () => { try { chrome.kill('SIGKILL'); } catch {} });

const failures = [];
let text = '';
try {
  const port = await new Promise((ok, bad) => {
    let buf = '';
    chrome.stderr.on('data', d => { buf += d; const m = /ws:\/\/127\.0\.0\.1:(\d+)\//.exec(buf); if (m) ok(m[1]); });
    chrome.on('exit', c => bad(new Error(`Chrome exited ${c} before it listened`)));
    setTimeout(() => bad(new Error('Chrome did not start in 30s')), 30000);
  });
  const target = (await (await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(15000) })).json()).find(t => t.type === 'page');
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  const consoleErrors = [];
  ws.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.method === 'Runtime.exceptionThrown') consoleErrors.push({ kind: 'exception', text: 'exception: ' + (m.params.exceptionDetails?.exception?.description ?? m.params.exceptionDetails?.text) });
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') consoleErrors.push({ kind: 'console', text: 'console.error: ' + m.params.args.map(x => x.value ?? x.description).join(' ') });
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error') consoleErrors.push({ kind: 'log', text: `log: ${m.params.entry.text} ${m.params.entry.url ?? ''}`, source: m.params.entry.source, message: m.params.entry.text, url: m.params.entry.url ?? '' });
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  };
  await new Promise((ok, bad) => {
    ws.onopen = ok;
    ws.onerror = () => bad(new Error('the DevTools socket failed to open'));
    ws.onclose = () => bad(new Error('the DevTools socket closed before it opened'));
    setTimeout(() => bad(new Error('the DevTools socket did not open in 15s')), 15000);
  });
  // Every CDP command is bounded and fails when the socket closes, so a hung
  // renderer or a dead Chrome reaches cleanup instead of waiting forever.
  const send = (method, params = {}) => new Promise((ok, bad) => {
    const i = ++id;
    const timer = setTimeout(() => { pending.delete(i); bad(new Error(`CDP ${method} timed out`)); }, 20000);
    pending.set(i, r => { clearTimeout(timer); ok(r); });
    ws.send(JSON.stringify({ id: i, method, params }));
  });
  ws.onclose = () => { for (const [i, r] of pending) { pending.delete(i); r(undefined); } };
  await send('Runtime.enable'); await send('Log.enable'); await send('Page.enable');
  await send('Page.navigate', { url: `${origin}/${a.page}` });

  const deadline = Date.now() + a.timeout;
  while (Date.now() < deadline) {
    text = (await send('Runtime.evaluate', { expression: `document.getElementById('result')?.textContent ?? ''`, returnByValue: true }))?.result?.value ?? '';
    if (text.trim() !== '') break;
    await new Promise(r => setTimeout(r, 250));
  }
  if (text.trim() === '') failures.push(`no result written to #result within ${a.timeout} ms`);
  else if (text.trim() !== a.expect) failures.push(`#result is ${JSON.stringify(text.slice(0, 300))}, expected ${JSON.stringify(a.expect)}`);

  for (const p of a.require) if (!requests.some(r => r.status === 200 && r.path === p)) failures.push(`required request not served 200: ${p}`);
  for (const p of a.forbid) if (requests.some(r => r.status === 200 && r.path === p)) failures.push(`forbidden request was served: ${p}`);

  const allowed404 = new Set(['/favicon.ico']);
  if (!a.skipAssets) {
    const base = BASES[a.layout];
    const other = BASES[a.layout === 'flutter' ? 'package' : 'flutter'];
    for (const ext of ['js', 'wasm']) {
      if (!requests.some(r => r.status === 200 && r.path === `/${base}/${WORKER}.${ext}`)) failures.push(`${WORKER}.${ext} was not served 200 from /${base}/`);
    }
    const probe = `/${other}/${WORKER}.js`;
    allowed404.add(probe);
    for (const r of requests.filter(r => r.path.includes(WORKER))) {
      const ok2xx = r.status >= 200 && r.status < 300;
      if (ok2xx && !r.path.startsWith(`/${base}/`)) failures.push(`worker asset served outside the expected base: ${r.status} ${r.path}`);
      if (!ok2xx && r.path !== probe) failures.push(`worker asset request failed: ${r.status} ${r.path}`);
    }
  }
  for (const r of requests) if (r.status >= 400 && !allowed404.has(r.path) && !r.path.includes(WORKER)) failures.push(`request failed: ${r.status} ${r.path}`);
  for (const e of consoleErrors) {
    // Only Chrome's own network-error entry for a permitted 404 is exempt; an
    // application's console.error or an exception never is.
    if (e.kind === 'log' && e.source === 'network' && /^Failed to load resource/.test(e.message)
        && [...allowed404].some(p => e.url === `${origin}${p}`)) continue;
    failures.push(e.text.slice(0, 400));
  }
  ws.close();
} catch (e) {
  failures.push(`driver error: ${e.message}`);
} finally {
  await cleanup();
}

const ok = failures.length === 0;
console.log(`requests: ${requests.map(r => `${r.status} ${r.path}`).join(' | ')}`);
for (const f of failures) console.log(`FAIL: ${f}`);
console.log('DRIVE_RESULT:' + JSON.stringify({ ok, result: text.trim().slice(0, 100), failures: failures.length }));
process.exit(ok ? 0 : 1);
