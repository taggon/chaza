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
const CHAZA = process.env.CHAZA_BIN ?? path.join(here, "..", "zig-out", "bin", "chaza");
const TINYSEARCH = process.env.TINYSEARCH_BIN ?? "tinysearch";

const CORPORA = ["corpus.json", "corpus_500.json", "corpus_1000.json"].map((f) => path.join(here, f));

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

const queries = [
  "대한민국", "민법", "올림픽", "이석구", "학교", "대한민국 민법", "서울 역사",
  "wikipedia", "history school", "music", "science", "york", "language", "war",
];
const N = 2000;

// ── Accuracy helpers ──
// Neutral reference tokenizer (neither engine's): lowercase + Unicode word split.
// Ground truth for a token = every document whose title/body contains it.
const neutralTokens = (s) => s.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];

// Deterministic PRNG for negative (fake-token) queries.
function mulberry32(seed) {
  return () => {
    seed |= 0; seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const CHOSEONG_JAMO = [..."ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"];
function choseongOf(word, len) {
  let out = "";
  for (const ch of word) {
    const cp = ch.codePointAt(0);
    if (cp < 0xac00 || cp > 0xd7a3) break;
    out += CHOSEONG_JAMO[Math.floor((cp - 0xac00) / 588)];
    if (out.length >= len) break;
  }
  return out.length >= len ? out : null;
}

function benchAccuracy(docs, engines) {
  // Truth: url → neutral token set; global document frequency per token
  const docTokens = docs.map((d) => new Set(neutralTokens(`${d.title} ${d.body}`)));
  const df = new Map();
  for (const set of docTokens) for (const t of set) df.set(t, (df.get(t) ?? 0) + 1);
  const truthFor = (token) => {
    const urls = new Set();
    docTokens.forEach((set, i) => { if (set.has(token)) urls.add(docs[i].url); });
    return urls;
  };

  // Positive queries: stratified sample of real tokens (Korean + Latin), deterministic
  const isKo = (t) => /\p{Script=Hangul}/u.test(t);
  const vocab = [...df.keys()].filter((t) => t.length >= 2 && t.length <= 12).sort();
  const sampleEvery = (arr, n) => {
    const step = Math.max(1, Math.floor(arr.length / n));
    return arr.filter((_, i) => i % step === 0).slice(0, n);
  };
  const positives = [...sampleEvery(vocab.filter(isKo), 60), ...sampleEvery(vocab.filter((t) => !isKo(t)), 60)];

  // Negative queries: fake tokens guaranteed absent from the vocabulary.
  // Letters only — digits would make chaza's script-boundary tokenizer split
  // "zq3k9d" into [zq, 3, k, 9, d], and single digits are real corpus tokens.
  const rng = mulberry32(42);
  const negatives = [];
  while (negatives.length < 200) {
    let t = "zq";
    for (let i = 0; i < 8; i++) t += String.fromCharCode(97 + Math.floor(rng() * 26));
    if (!df.has(t)) negatives.push(t);
  }

  // Known-item queries: rarest title token per doc → source doc should rank top
  const knownItems = [];
  for (let i = 0; i < docs.length; i++) {
    const cands = [...new Set(neutralTokens(docs[i].title))].filter((t) => t.length >= 2);
    if (cands.length === 0) continue;
    cands.sort((a, b) => (df.get(a) - df.get(b)) || (b.length - a.length) || a.localeCompare(b));
    knownItems.push({ query: cands[0], url: docs[i].url });
  }

  console.log(`\naccuracy (${positives.length} positive · ${negatives.length} negative · ${knownItems.length} known-item queries):`);
  for (const { label, search } of engines) {
    // Positive: recall@20 (capped) and precision vs neutral truth
    let recallSum = 0, recallN = 0, precSum = 0, precN = 0;
    for (const q of positives) {
      const truth = truthFor(q);
      if (truth.size === 0) continue;
      const got = search(q, 20);
      const hit = got.filter((u) => truth.has(u)).length;
      recallSum += hit / Math.min(truth.size, 20); recallN++;
      if (got.length > 0) { precSum += hit / got.length; precN++; }
    }

    // Negative: every returned doc is a false positive
    let fpDocs = 0, fpQueries = 0;
    for (const q of negatives) {
      const got = search(q, 20);
      fpDocs += got.length;
      if (got.length > 0) fpQueries++;
    }
    const fpRate = (fpDocs / (negatives.length * docs.length)) * 100;

    // Known-item: MRR@10
    let mrrSum = 0;
    for (const { query, url } of knownItems) {
      const rank = search(query, 10).indexOf(url);
      if (rank >= 0) mrrSum += 1 / (rank + 1);
    }

    console.log(
      `  ${label} recall@20 ${(recallSum / recallN * 100).toFixed(1)}% · precision ${(precSum / precN * 100).toFixed(1)}% · ` +
      `FP ${fpRate.toFixed(2)}%/doc (${fpQueries}/${negatives.length} queries polluted) · MRR@10 ${(mrrSum / knownItems.length).toFixed(3)}`,
    );
  }
  return { positives, negatives, knownItems };
}

// chaza only: choseong query → source doc retrievable? (no tinysearch equivalent)
function benchChoseong(docs, search) {
  let tried = 0, hits = 0;
  for (const d of docs) {
    const word = neutralTokens(d.title).find((t) => /^\p{Script=Hangul}+$/u.test(t));
    if (!word) continue;
    const cs = choseongOf(word, Math.min(3, [...word].length));
    if (!cs) continue;
    tried++;
    if (search(cs, 20).includes(d.url)) hits++;
  }
  if (tried > 0) {
    console.log(`  chaza choseong: ${hits}/${tried} Korean-title docs retrievable by initial consonants (${(hits / tried * 100).toFixed(1)}%)`);
  }
}

function benchSearch(label, fn) {
  for (let i = 0; i < 200; i++) fn(queries[i % queries.length]);
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < N; i++) fn(queries[i % queries.length]);
  const total = ms(t0);
  console.log(`  ${label} ${(total / N * 1000).toFixed(1)} µs/query (${total.toFixed(1)} ms / ${N} queries)`);
}

for (const CORPUS of CORPORA) {
  const tag = path.basename(CORPUS, ".json").replace(/^corpus_?/, "") || "full";
  const outDir = path.join(OUT, tag === "full" ? "" : tag);
  mkdirSync(outDir, { recursive: true });

  const docCount = JSON.parse(readFileSync(CORPUS, "utf8")).length;
  console.log(`\n${"=".repeat(60)}`);
  console.log(`corpus: ${CORPUS} (${docCount} docs) [${tag}]`);
  console.log(`${"=".repeat(60)}\n`);

  // ── 1. Index build time ──
  // --config indexes title+body, matching tinysearch's fixed schema (fair comparison)
  const chazaBundle = path.join(outDir, "chaza.wasm");
  const chazaConfig = path.join(here, "chaza.json");
  const chazaBuild = timeRuns("chaza build      ", 20, () =>
    execFileSync(CHAZA, ["build", CORPUS, "--config", chazaConfig, "-o", chazaBundle, "-q"], { cwd: outDir }),
  );

  // --release: wasm only; plain: wasm + JS glue (needed for the search bench)
  const tsOut = path.join(outDir, "tinysearch");
  const tsBuild = timeRuns("tinysearch build ", 3, () =>
    execFileSync(TINYSEARCH, ["-m", "wasm", "--release", "-p", tsOut, CORPUS], { stdio: "ignore" }),
  );
  execFileSync(TINYSEARCH, ["-m", "wasm", "-p", tsOut, CORPUS], { stdio: "ignore" });

  // ── 2. Output sizes ──
  const chazaLoader = path.join(outDir, "chaza.js");
  const tsWasm = path.join(tsOut, "tinysearch_engine.wasm");
  const tsGlue = path.join(tsOut, "tinysearch_engine.js");

  // Feature-parity size: choseong + prefix tokens are chaza-only capabilities
  // tinysearch lacks — build once without them to isolate their cost.
  const chazaPlain = path.join(outDir, "chaza-plain.wasm");
  execFileSync(CHAZA, ["build", CORPUS, "--config", path.join(here, "chaza-plain.json"), "-o", chazaPlain, "--no-js", "-q"], { cwd: outDir });

  console.log("\nsizes:");
  console.log(`  chaza.wasm            ${kb(statSync(chazaBundle).size)} (gzip ${kb(gzSize(chazaBundle))})`);
  console.log(`  chaza w/o 초성+prefix ${kb(statSync(chazaPlain).size)} (gzip ${kb(gzSize(chazaPlain))}) — feature-parity vs tinysearch`);
  console.log(`  chaza.js loader       ${kb(statSync(chazaLoader).size)} (gzip ${kb(gzSize(chazaLoader))})`);
  console.log(`  tinysearch wasm       ${kb(statSync(tsWasm).size)} (gzip ${kb(gzSize(tsWasm))})`);
  console.log(`  tinysearch glue       ${kb(statSync(tsGlue).size)} (gzip ${kb(gzSize(tsGlue))})`);

  // ── 3. Search latency ──
  // chaza build wrote its embedded ESM loader (chaza.js) next to the bundle — use that.
  const chazaLoaderUrl = `file://${chazaLoader}?t=${Date.now()}`;
  const tsGlueUrl = `file://${tsGlue}?t=${Date.now()}`;
  const { Chaza } = await import(chazaLoaderUrl);
  const { TinySearch } = await import(tsGlueUrl);

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

  // ── 4. Accuracy ──
  const docs = JSON.parse(readFileSync(CORPUS, "utf8"));
  benchAccuracy(docs, [
    { label: "chaza      ", search: (q, k) => chaza.search(q, { maxResults: k }).map((r) => r.url) },
    { label: "tinysearch ", search: (q, k) => ts.search(q, k).map((r) => r.url) },
  ]);
  benchChoseong(docs, (q, k) => chaza.search(q, { maxResults: k }).map((r) => r.url));

  console.log(`\nsummary [${tag}]: build ${chazaBuild.toFixed(1)} ms vs ${(tsBuild / 1000).toFixed(1)} s · env: node ${process.version}, ${process.arch}`);
}
