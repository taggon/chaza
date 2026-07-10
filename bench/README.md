# Benchmark: chaza vs tinysearch

Reproduces the comparison table in the project README.

## Corpus

`corpus.json` — 100 Wikipedia extracts (50 Korean + 50 English), tinysearch-compatible `[{title, url, body}]`. Both engines index the exact same file.

## Prerequisites

- **chaza** — release build in this repo:
  ```bash
  zig build -Doptimize=ReleaseFast          # → zig-out/bin/chaza
  ```
  The search bench uses the `chaza.js` loader that `chaza build` writes next to the bundle — no npm setup needed.
- **tinysearch** — installed globally (`tinysearch` on PATH):
  ```bash
  cargo install tinysearch
  ```
  Requires a Rust toolchain with the `wasm32-unknown-unknown` target. Run the benchmark once to warm the cargo cache before trusting the build-time numbers — tinysearch compiles a Rust crate on every index build, and the first-ever run also compiles dependencies.

## Run

```bash
node bench/run.mjs
```

Outputs (written to `bench/out/`, git-ignored):
- index build time — median of 20 runs (chaza) / 3 runs (tinysearch)
- output sizes, raw and gzip -9
- search latency — 2,000 mixed Korean/English queries per engine in Node, after 200-query warmup
- a sanity check that both engines return the same document for the same query
- accuracy — recall@20 / precision on 120 sampled real tokens, false-positive rate on 200 letters-only fake tokens, known-item MRR@10 (rarest title token per doc), and chaza-only choseong retrieval; ground truth comes from a neutral reference tokenizer scanning the corpus directly

A snapshot of a full run with analysis lives in [RESULTS.md](RESULTS.md).

Override binaries with `CHAZA_BIN` / `TINYSEARCH_BIN` env vars.

## Fairness notes

- Both engines index title + body: tinysearch's schema is fixed, so chaza is passed `bench/chaza.json` to match (chaza's default would index title only).
- tinysearch is timed with `--release` (its production mode); chaza with `ReleaseFast` (its release mode, same as shipped npm binaries).
- Search latency measures each engine through its own official JS wrapper (`chaza.js` loader / `tinysearch_engine.js` glue), which is what a site would actually run.
- tinysearch has no Korean choseong support and no ranking; result-quality differences are out of scope here — this measures speed and size only.
