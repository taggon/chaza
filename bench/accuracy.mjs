#!/usr/bin/env node
// chaza-only accuracy + size harness for stage-gating filter changes.
//
// Same methodology as run.mjs benchAccuracy (deterministic queries), without
// the tinysearch dependency, plus a filter-section size breakdown read from
// the bundle's index header.
//
// Usage: node accuracy.mjs [--label NAME]
//   CHAZA_BIN=/path/to/chaza node accuracy.mjs

import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, statSync } from "node:fs";
import { gzipSync } from "node:zlib";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(here, "out", "accuracy");
const CHAZA = process.env.CHAZA_BIN ?? path.join(here, "..", "zig-out", "bin", "chaza");
const label = process.argv.includes("--label")
  ? process.argv[process.argv.indexOf("--label") + 1]
  : "current";

const CORPORA = ["corpus.json", "corpus_500.json", "corpus_1000.json"].map((f) => path.join(here, f));

mkdirSync(OUT, { recursive: true });

const kb = (n) => `${(n / 1024).toFixed(1)} KB`;
const gz = (buf) => gzipSync(buf, { level: 9 }).length;

const neutralTokens = (s) => s.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];

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

// Bundle layout: [wasm][index][tail 16B]. Index header offsets give the
// section split; filters section runs to the end of the index.
function sectionSizes(bundleBytes) {
  const dv = new DataView(bundleBytes.buffer, bundleBytes.byteOffset);
  const tailOff = bundleBytes.length - 16;
  const wasmLen = dv.getUint32(tailOff + 8, true);
  const indexLen = dv.getUint32(tailOff + 12, true);
  const h = new DataView(bundleBytes.buffer, bundleBytes.byteOffset + wasmLen, 32);
  const filtersOff = h.getUint32(28, true);
  return { wasmLen, indexLen, filters: indexLen - filtersOff, nonFilter: filtersOff };
}

for (const CORPUS of CORPORA) {
  const docs = JSON.parse(readFileSync(CORPUS, "utf8"));
  const tag = path.basename(CORPUS, ".json").replace(/^corpus_?/, "") || "100";
  console.log(`\n=== ${tag} docs (${docs.length}) [${label}] ===`);

  const bundle = path.join(OUT, `chaza-${tag}.bundle`);
  execFileSync(CHAZA, ["build", CORPUS, "--config", path.join(here, "chaza.json"), "-o", bundle, "-q"], { cwd: OUT });

  const bundleBytes = readFileSync(bundle);
  const sec = sectionSizes(new Uint8Array(bundleBytes));
  console.log(
    `size: bundle ${kb(bundleBytes.length)} (gzip ${kb(gz(bundleBytes))}) · ` +
    `filters ${kb(sec.filters)} · index-nonfilter ${kb(sec.nonFilter)} · wasm ${kb(sec.wasmLen)}`,
  );

  const loaderUrl = `file://${path.join(OUT, "chaza.js")}?t=${Date.now()}`;
  const { Chaza } = await import(loaderUrl);
  const chaza = await Chaza.load(new Uint8Array(bundleBytes));
  const search = (q, k) => chaza.search(q, { maxResults: k }).map((r) => r.url);

  // Ground truth
  const docTokens = docs.map((d) => new Set(neutralTokens(`${d.title} ${d.body}`)));
  const df = new Map();
  for (const set of docTokens) for (const t of set) df.set(t, (df.get(t) ?? 0) + 1);
  const truthFor = (token) => {
    const urls = new Set();
    docTokens.forEach((set, i) => { if (set.has(token)) urls.add(docs[i].url); });
    return urls;
  };

  // Positive queries
  const isKo = (t) => /\p{Script=Hangul}/u.test(t);
  const vocab = [...df.keys()].filter((t) => t.length >= 2 && t.length <= 12).sort();
  const sampleEvery = (arr, n) => {
    const step = Math.max(1, Math.floor(arr.length / n));
    return arr.filter((_, i) => i % step === 0).slice(0, n);
  };
  const positives = [...sampleEvery(vocab.filter(isKo), 60), ...sampleEvery(vocab.filter((t) => !isKo(t)), 60)];

  let recallSum = 0, recallN = 0, precSum = 0, precN = 0;
  for (const q of positives) {
    const truth = truthFor(q);
    if (truth.size === 0) continue;
    const got = search(q, 20);
    const hit = got.filter((u) => truth.has(u)).length;
    recallSum += hit / Math.min(truth.size, 20); recallN++;
    if (got.length > 0) { precSum += hit / got.length; precN++; }
  }

  // Negative queries — 1000 fake tokens for a tighter FP estimate than run.mjs's 200
  const rng = mulberry32(42);
  const negatives = [];
  while (negatives.length < 1000) {
    let t = "zq";
    for (let i = 0; i < 8; i++) t += String.fromCharCode(97 + Math.floor(rng() * 26));
    if (!df.has(t)) negatives.push(t);
  }
  let fpDocs = 0, fpQueries = 0;
  for (const q of negatives) {
    const got = search(q, 1000000);
    fpDocs += got.length;
    if (got.length > 0) fpQueries++;
  }
  const fpRate = (fpDocs / (negatives.length * docs.length)) * 100;

  // Known-item MRR@10
  const knownItems = [];
  for (let i = 0; i < docs.length; i++) {
    const cands = [...new Set(neutralTokens(docs[i].title))].filter((t) => t.length >= 2);
    if (cands.length === 0) continue;
    cands.sort((a, b) => (df.get(a) - df.get(b)) || (b.length - a.length) || a.localeCompare(b));
    knownItems.push({ query: cands[0], url: docs[i].url });
  }
  let mrrSum = 0;
  for (const { query, url } of knownItems) {
    const rank = search(query, 10).indexOf(url);
    if (rank >= 0) mrrSum += 1 / (rank + 1);
  }

  // Choseong retrieval
  let csTried = 0, csHits = 0;
  for (const d of docs) {
    const word = neutralTokens(d.title).find((t) => /^\p{Script=Hangul}+$/u.test(t));
    if (!word) continue;
    const cs = choseongOf(word, Math.min(3, [...word].length));
    if (!cs) continue;
    csTried++;
    if (search(cs, 20).includes(d.url)) csHits++;
  }

  console.log(
    `accuracy: recall@20 ${(recallSum / recallN * 100).toFixed(1)}% · precision ${(precSum / precN * 100).toFixed(1)}% · ` +
    `FP ${fpRate.toFixed(4)}%/doc (${fpQueries}/${negatives.length} neg queries polluted) · ` +
    `MRR@10 ${(mrrSum / knownItems.length).toFixed(3)} · choseong ${csTried ? (csHits / csTried * 100).toFixed(1) : "n/a"}% (${csHits}/${csTried})`,
  );
}
