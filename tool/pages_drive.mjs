// Drives the deployed REPL demo over the Chrome DevTools Protocol and proves it
// EXECUTES PYTHON — not merely that the page loads.
//
// Called by tool/check_pages.sh. Node 26 exposes a global WebSocket, so this has
// no dependencies (no puppeteer, no ws module).
//
// Why CDP rather than chrome-devtools-mcp: the MCP holds a single shared browser
// profile and refuses to attach when an instance is already running, which makes
// it unusable as an unattended gate. CDP against our own throwaway profile always
// works.
//
// Why this matters: the REPL initialises its WASM engine on button click, so a
// passive page load never touches the engine at all. Without typing input and
// clicking Run, a completely broken engine would still look "fine".
//
// Usage: node tool/pages_drive.mjs <cdp-port> <url>
// Prints GATE_RESULT:{...}; exits 0 only if Python actually evaluated.
const PORT = process.argv[2], URL_ = process.argv[3];
const sleep = ms => new Promise(r => setTimeout(r, ms));
const t = (await (await fetch(`http://127.0.0.1:${PORT}/json`)).json()).find(x => x.type === 'page');
const ws = new WebSocket(t.webSocketDebuggerUrl);
let id = 0; const p = new Map(); const logs = [];
const send = (m, params = {}) => new Promise(r => { const i = ++id; p.set(i, r); ws.send(JSON.stringify({ id: i, method: m, params })); });
ws.onmessage = e => { const m = JSON.parse(e.data);
  if (m.method === 'Runtime.exceptionThrown') logs.push('EXC: ' + (m.params.exceptionDetails?.text || ''));
  if (m.id && p.has(m.id)) { p.get(m.id)(m.result); p.delete(m.id); } };
await new Promise(r => ws.onopen = r);
await send('Runtime.enable'); await send('Page.enable');
await send('Page.navigate', { url: URL_ }); await sleep(8000);
const ev = async e => (await send('Runtime.evaluate', { expression: e, awaitPromise: true, returnByValue: true }))?.result?.value;

const tag = await ev(`document.querySelector('#input-a')?.tagName`);
// Set the source the way a user would, then fire the events the app listens for.
await ev(`(() => { const el = document.querySelector('#input-a');
  if ('value' in el) { el.value = '2 + 2'; } else { el.textContent = '2 + 2'; }
  el.dispatchEvent(new Event('input', {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true})); return true; })()`);
const readBack = await ev(`(() => { const el=document.querySelector('#input-a'); return ('value' in el ? el.value : el.textContent) || ''; })()`);
const before = await ev(`document.querySelector('#output-a')?.innerText || ''`);
await ev(`document.querySelector('#run-a').click(); true`);

let after = before;
for (let i = 0; i < 45; i++) { await sleep(1000);
  after = await ev(`document.querySelector('#output-a')?.innerText || ''`);
  if (after !== before && /\b4\b/.test(after)) break; }
const grew = after.length > before.length || after !== before;
const hasFour = /\b4\b/.test(after.replace(before, ''));
const ok = grew && hasFour && logs.length === 0;
console.log('INPUT_TAG    :', tag, '| readBack:', JSON.stringify(readBack));
console.log('NEW_OUTPUT   :', JSON.stringify(after.replace(before, '').trim().slice(0, 200)));
if (logs.length) console.log('EXCEPTIONS   :', JSON.stringify(logs.slice(0, 3)));
console.log('GATE_RESULT:' + JSON.stringify({ ok, executedPython: hasFour, outputChanged: grew, exceptions: logs.length }));
ws.close(); process.exit(ok ? 0 : 1);
