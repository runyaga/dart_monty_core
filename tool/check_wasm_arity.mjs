#!/usr/bin/env node
// Cross-check every wasm.<fn>(...) call in the Worker against the arity the
// shipped .wasm actually exports.
//
// Why this exists: JS does NOT throw when a WebAssembly export is called with
// the wrong number of arguments. Missing arguments are filled with 0 and extra
// ones are dropped. So a Rust signature change is a SILENT miscompile on the
// web backend -- there is no compiler, linter, type-checker or existing gate
// on this path. `dart analyze` covers the FFI half of the ABI and nothing at
// all covers the JS half.
//
// Measured 2026-09-14: monty_repl_restore grew from 3 parameters to 5 (limits
// and ext fns were being dropped on the floor), the Worker kept calling it with
// 3, and `outError.ptr` silently bound to the `limits_json` slot -- an
// out-pointer parsed as a C string. Rust then read the zeroed out-slot as "",
// failed to parse it as limits JSON, and wrote the real reason to an out_error
// that was now NULL. Every WASM restore failed with "monty_repl_restore
// failed" and no cause. The full FFI suite stayed green throughout.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const WASM = join(ROOT, 'lib', 'assets', 'dart_monty_core_native.wasm');
const SRC = join(ROOT, 'js', 'src', 'worker_src.js');

/** Parse the wasm type/import/function/export sections -> {name: paramCount}. */
function exportArities(buf) {
  let o = 8;
  const types = [], funcs = [], exports = new Map();
  const u32 = () => {
    let r = 0, s = 0, b;
    do { b = buf[o++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80);
    return r >>> 0;
  };
  while (o < buf.length) {
    const id = buf[o++];
    // Read the size BEFORE computing the end: u32() advances `o`, and
    // `o + u32()` would capture the pre-advance `o`, landing short by the
    // length of the LEB128 size field itself.
    const size = u32();
    const sectionEnd = o + size;
    if (id === 1) {
      const n = u32();
      for (let i = 0; i < n; i++) {
        o++;                       // 0x60 func form
        const np = u32(); o += np; // param types
        const nr = u32(); o += nr; // result types
        types.push(np);
      }
    } else if (id === 2) {
      const n = u32();
      for (let i = 0; i < n; i++) {
        // Same trap as the section size: u32() advances `o`, so the length
        // must be captured first and added afterwards.
        const modLen = u32(); o += modLen;
        const fieldLen = u32(); o += fieldLen;
        const k = buf[o++];
        if (k === 0) funcs.push(u32());
        else if (k === 1) { o++; const f = buf[o++]; u32(); if (f) u32(); }
        else if (k === 2) { const f = buf[o++]; u32(); if (f) u32(); }
        else if (k === 3) { o += 2; }
      }
    } else if (id === 3) {
      const n = u32();
      for (let i = 0; i < n; i++) funcs.push(u32());
    } else if (id === 7) {
      const n = u32();
      for (let i = 0; i < n; i++) {
        const len = u32();
        const name = buf.slice(o, o + len).toString(); o += len;
        const kind = buf[o++], idx = u32();
        if (kind === 0) exports.set(name, types[funcs[idx]]);
      }
    }
    o = sectionEnd;
  }
  return exports;
}

/**
 * Count top-level arguments of the call whose '(' is at `open`.
 *
 * Handles the three things that make a naive comma count wrong on this file:
 * trailing commas (`foo(a, b,)` is 2 arguments, not 3), commas inside string
 * literals (`extFns.join(',')`), and parentheses inside strings or comments,
 * which would otherwise corrupt the depth counter.
 */
function countArgs(src, open) {
  let depth = 0, commas = 0, segHasContent = false, anyContent = false;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    // Skip string literals wholesale -- their contents are not syntax.
    if (c === '"' || c === "'" || c === '`') {
      const quote = c;
      i++;
      while (i < src.length && src[i] !== quote) {
        if (src[i] === '\\') i++;
        i++;
      }
      anyContent = true;
      if (depth >= 1) segHasContent = true;
      continue;
    }
    if (c === '/' && src[i + 1] === '/') {
      i = src.indexOf('\n', i);
      if (i === -1) break;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      i = src.indexOf('*/', i + 2) + 1;
      if (i === 0) break;
      continue;
    }
    if (c === '(' || c === '[' || c === '{') {
      depth++;
      if (depth === 1) continue;
    } else if (c === ')' || c === ']' || c === '}') {
      depth--;
      if (depth === 0) return anyContent ? commas + (segHasContent ? 1 : 0) : 0;
      continue;
    }
    if (depth === 1 && c === ',') {
      commas++;
      segHasContent = false;
      continue;
    }
    if (!/\s/.test(c)) {
      anyContent = true;
      if (depth >= 1) segHasContent = true;
    }
  }
  throw new Error(`unbalanced call starting at offset ${open}`);
}

const arities = exportArities(readFileSync(WASM));
const src = readFileSync(SRC, 'utf8');
const problems = [];
// `wasm.` is the Worker's handle on the instantiated exports object.
for (const m of src.matchAll(/\bwasm\.([A-Za-z_$][\w$]*)\s*\(/g)) {
  const name = m[1];
  const open = m.index + m[0].length - 1;
  const line = src.slice(0, m.index).split('\n').length;
  if (!arities.has(name)) {
    problems.push(`${SRC}:${line}: calls wasm.${name}(), which the shipped wasm does not export`);
    continue;
  }
  const want = arities.get(name), got = countArgs(src, open);
  if (want !== got) {
    problems.push(`${SRC}:${line}: wasm.${name}() called with ${got} argument(s), but the wasm export takes ${want}`);
  }
}

if (problems.length > 0) {
  console.error('=== FAILED: Worker/wasm arity mismatch ===');
  for (const p of problems) console.error(`  ${p}`);
  console.error('\nJS pads missing wasm arguments with 0 and drops extra ones, so this');
  console.error('does not throw at runtime -- it silently binds the wrong values to the');
  console.error('wrong parameters. Fix the call site, or rebuild the wasm.');
  process.exit(1);
}
const n = [...src.matchAll(/\bwasm\.([A-Za-z_$][\w$]*)\s*\(/g)].length;
console.log(`OK: ${n} wasm call sites in worker_src.js match the shipped export arities`);
