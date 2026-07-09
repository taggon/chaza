#!/usr/bin/env node
// chaza vs tinysearch benchmark.
//
// Prerequisites:
//   - chaza:      zig build -Doptimize=ReleaseFast   (→ ../zig-out/bin/chaza)
//   - tinysearch: cargo install tinysearch           (global `tinysearch` on PATH)
//
// Usage: node run.mjs
// Override binaries: CHAZA_BIN=/path/to/chaza TINYSEARCH_BIN=tinysearch node run.mjs

import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, statSync } from "node:fs";
import { gzipSync } from "node:zlib";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(here, "out");
const CORPUS = path.join(here, "corpus.json");
const CHAZA = process.env.CHAZA_BIN ?? path.join(here, "..", "zig-out", "bin", "chaza");
const TINYSEARCH = process.env.TINYSEARCH_BIN ?? "tinysearch";

mkdirSync(OUT, { recursive: true });

const ms = (t0) => Number(process.hrtime.bigint() - t0) / 1e6;
const median = (xs) => xs.slice().sort((a, b) => a - b)[xs.length >> 1];
const kb = (n) => `${(n / 1024).toFixed(1)} KB`;
const gzSize = (p) => gzipSync(readFileSync(p), { level: 9 }).length;

function timeRuns(label, n, fn) {
  fn(); // warmup
  const times = [];
  for (let i = 0; i < n; i++) {
    const t0 = process.hrtime.bigint();
    fn();
    times.push(ms(t0));
  }
  const med = median(times);
  console.log(`${label}: median ${med.toFixed(1)} ms over ${n} runs (min ${Math.min(...times).toFixed(1)}, max ${Math.max(...times).toFixed(1)})`);
  return med;
}

// ── 1. Index build time ──
console.log(`corpus: ${CORPUS} (${JSON.parse(readFileSync(CORPUS, "utf8")).length} docs)\n`);

const chazaBundle = path.join(OUT, "chaza.bundle");
const chazaBuild = timeRuns("chaza build      ", 20, () =>
  execFileSync(CHAZA, ["build", CORPUS, "-o", chazaBundle, "-q"], { cwd: OUT }),
);

// --release: wasm only; plain: wasm + JS glue (needed for the search bench)
const tsOut = path.join(OUT, "tinysearch");
const tsBuild = timeRuns("tinysearch build ", 3, () =>
  execFileSync(TINYSEARCH, ["-m", "wasm", "--release", "-p", tsOut, CORPUS], { stdio: "ignore" }),
);
execFileSync(TINYSEARCH, ["-m", "wasm", "-p", tsOut, CORPUS], { stdio: "ignore" });

// ── 2. Output sizes ──
const chazaLoader = path.join(OUT, "chaza.js");
const tsWasm = path.join(tsOut, "tinysearch_engine.wasm");
const tsGlue = path.join(tsOut, "tinysearch_engine.js");

console.log("\nsizes:");
console.log(`  chaza.bundle          ${kb(statSync(chazaBundle).size)} (gzip ${kb(gzSize(chazaBundle))})`);
console.log(`  chaza.js loader       ${kb(statSync(chazaLoader).size)} (gzip ${kb(gzSize(chazaLoader))})`);
console.log(`  tinysearch wasm       ${kb(statSync(tsWasm).size)} (gzip ${kb(gzSize(tsWasm))})`);
console.log(`  tinysearch glue       ${kb(statSync(tsGlue).size)} (gzip ${kb(gzSize(tsGlue))})`);

// ── 3. Search latency ──
// chaza build wrote its embedded ESM loader (chaza.js) next to the bundle — use that.
const { Chaza } = await import(chazaLoader);
const { TinySearch } = await import(tsGlue);

const queries = [
  "대한민국", "민법", "올림픽", "이석구", "학교", "대한민국 민법", "서울 역사",
  "wikipedia", "history school", "music", "science", "york", "language", "war",
];
const N = 2000;

function benchSearch(label, fn) {
  for (let i = 0; i < 200; i++) fn(queries[i % queries.length]);
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < N; i++) fn(queries[i % queries.length]);
  const total = ms(t0);
  console.log(`  ${label} ${(total / N * 1000).toFixed(1)} µs/query (${total.toFixed(1)} ms / ${N} queries)`);
}

console.log("\nsearch latency:");
const chaza = await Chaza.load(readFileSync(chazaBundle));
benchSearch("chaza      ", (q) => chaza.search(q));

const tsMod = await WebAssembly.instantiate(readFileSync(tsWasm));
const ts = new TinySearch(tsMod.instance);
benchSearch("tinysearch ", (q) => ts.search(q, 20));

// sanity: same corpus, both engines find the same doc
console.log("\nsanity ('민법'):");
console.log("  chaza      →", chaza.search("민법").map((r) => r.title));
console.log("  tinysearch →", ts.search("민법", 5).map((r) => r.title));

console.log(`\nsummary: build ${chazaBuild.toFixed(1)} ms vs ${(tsBuild / 1000).toFixed(1)} s · env: node ${process.version}, ${process.arch}`);
