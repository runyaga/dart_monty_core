// Adapted from tool/consumers/drive.mjs: same bounded CDP transport,
// request tracking, MIME handling and fresh-profile cleanup. Host-only smoke.
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
    else if (['--headers', '--compiler', '--root', '--layout', '--page', '--expect', '--timeout'].includes(k)) a[k.slice(2)] = argv[++i];
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
    ...(a.headers === 'off' ? {} : {'cross-origin-opener-policy': 'same-origin', 'cross-origin-embedder-policy': 'require-corp'}),
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


  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true});
    if (!result || result.exceptionDetails) throw Error(JSON.stringify(result?.exceptionDetails ?? 'CDP disconnected'));
    return result.result?.value;
  };
  const waitFor = async (expression, timeout = a.timeout) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (await evaluate(expression)) return;
      await new Promise(r => setTimeout(r, 100));
    }
    throw Error(`Timed out: ${expression}; output: ${await evaluate("document.querySelector('#output')?.textContent")}`);
  };
  const run = async source => {
    await evaluate(`document.querySelector('#output').textContent = ''; document.querySelector('#editor').value = ${JSON.stringify(source)}; document.querySelector('#run').click()`);
    await waitFor("document.querySelector('#run')?.disabled === false");
    return evaluate("document.querySelector('#output').textContent");
  };
  const requireText = (output, expected) => {
    if (!output.includes(expected)) failures.push(`Expected ${JSON.stringify(expected)} in ${JSON.stringify(output)}`);
  };
  const page = async (path, body) => {
    const before = failures.length;
    const requestStart = requests.length;
    const errorStart = consoleErrors.length;
    try {
      await send('Page.navigate', {url: `${origin}/${path}`});
      await body();
    } catch (error) {
      failures.push(`${path}: ${error.message}`);
    }
    const permitted404 = new Set(['/favicon.ico', `/repl/${BASES[a.layout === 'flutter' ? 'package' : 'flutter']}/${WORKER}.js`]);
    for (const r of requests.slice(requestStart)) {
      if (r.status >= 400 && !permitted404.has(r.path)) failures.push(`${path}: request failed: ${r.status} ${r.path}`);
    }
    for (const e of consoleErrors.slice(errorStart)) {
      if (e.kind === 'log' && e.source === 'network' && /^Failed to load resource/.test(e.message)
          && [...permitted404].some(p => e.url === `${origin}${p}`)) continue;
      failures.push(`${path}: ${e.text.slice(0, 400)}`);
    }
    console.log('PAGE_RESULT:' + JSON.stringify({page: path, headers: a.headers, ok: failures.length === before, failures: failures.slice(before)}));
  };
  await page(a.page, async () => {
    await waitFor("document.querySelector('#run')?.disabled === false");
    text = await run("print('smoke print')\nsmoke_state = 40\nsmoke_state + 2");
    requireText(text, 'smoke print'); requireText(text, '=> 42');
    requireText(await run('smoke_state + 3'), '=> 43');
    requireText(await run('if :'), 'syntax:');
    requireText(await run('1 / 0'), 'runtime:');
    requireText(await run('6 * 7'), '=> 42');
    requireText(await run("import csv\nwith open('output.csv', mode='w', newline='', encoding='utf-8') as f:\n    csv.writer(f).writerows([[\"Name\",\"Age\"],[\"Alice\",30]])"), '=> None');
    requireText(await run("print(open('output.csv').read())"), 'Name,Age\nAlice,30\n');
    await evaluate("document.querySelector('#reset').click()");
    await waitFor("document.querySelector('#run')?.disabled === false");
    requireText(await run('smoke_state'), 'runtime:');
    requireText(await run("open('output.csv').read()"), 'runtime:');
    requireText(await run("open('/work/hello.txt').read()"), 'runtime:');
    const examples = JSON.parse(readFileSync(join(root, 'repl/examples.json'), 'utf8'));
    const expectedGroups = ['Basics', 'Host integration', 'Files', 'Standard library 1.2.0', 'Errors'];
    const actualGroups = await evaluate("Array.from(document.querySelectorAll('#examples optgroup'), g => g.label)");
    if (JSON.stringify(actualGroups) !== JSON.stringify(expectedGroups)) failures.push(`Example groups: ${JSON.stringify(actualGroups)}`);
    const assertExampleOutput = (output, expected, label) => {
      if (expected.error) {
        requireText(output, `${expected.error}:`);
      } else {
        const exact = `${expected.print ?? ''}=> ${expected.result}\n`;
        if (output !== exact) failures.push(`${label}: expected ${JSON.stringify(exact)}, got ${JSON.stringify(output)}`);
      }
    };
    for (const example of examples) {
      try {
        await evaluate(`document.querySelector('#examples').value = ${JSON.stringify(example.id)}; document.querySelector('#examples').dispatchEvent(new Event('change'))`);
        await waitFor("document.querySelector('#run')?.disabled === false");
        text = await run(example.source);
        assertExampleOutput(text, example.expected, example.id);
        if (example.expected.nextSource) assertExampleOutput(await run(example.expected.nextSource), {
          result: example.expected.nextResult ?? 'None', print: example.expected.nextPrint,
        }, `${example.id} next feed`);
        if (example.expected.secondResult) assertExampleOutput(await run(example.source), {
          result: example.expected.secondResult, print: example.expected.print,
        }, `${example.id} second feed`);
      } catch (error) {
        failures.push(`example ${example.id}: ${error.message}`);
      }
    }
    if (a.headers === 'off' && !await evaluate('crossOriginIsolated && !!navigator.serviceWorker.controller')) throw Error('Service-worker COI bootstrap failed');
  });
  await page(`repl/matrix_${a.compiler}.html`, async () => {
    await waitFor("document.querySelector('#output')?.getAttribute('data-complete') === 'true'", 900000);
    text = await evaluate("document.querySelector('#output').textContent");
    requireText(text, 'FIXTURE_DONE:'); requireText(text, 'Matrix complete:');
    if (!/FIXTURE_DONE:.*"total":[1-9]/.test(text)) failures.push('No measured corpus execution');
    for (const line of text.split('\n')) if (line.startsWith('FAIL ')) failures.push(line);
    // Corpus outcomes include platform-specific failures; preserve the measured report.
    console.log(text);
  });
  for (const p of a.require) if (!requests.some(r => r.status === 200 && r.path === p)) failures.push(`required request not served 200: ${p}`);
  for (const p of a.forbid) if (requests.some(r => r.status === 200 && r.path === p)) failures.push(`forbidden request was served: ${p}`);

  if (!a.skipAssets) {
    const base = 'repl/' + BASES[a.layout];
    const other = 'repl/' + BASES[a.layout === 'flutter' ? 'package' : 'flutter'];
    for (const ext of ['js', 'wasm']) {
      if (!requests.some(r => r.status === 200 && r.path === `/${base}/${WORKER}.${ext}`)) failures.push(`${WORKER}.${ext} was not served 200 from /${base}/`);
    }
    const probe = `/${other}/${WORKER}.js`;
    for (const r of requests.filter(r => r.path.includes(WORKER))) {
      const ok2xx = r.status >= 200 && r.status < 300;
      if (ok2xx && !r.path.startsWith(`/${base}/`)) failures.push(`worker asset served outside the expected base: ${r.status} ${r.path}`);
      if (!ok2xx && r.path !== probe) failures.push(`worker asset request failed: ${r.status} ${r.path}`);
    }
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
