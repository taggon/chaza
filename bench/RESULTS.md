# Benchmark results: chaza vs tinysearch

Snapshot of a full `node bench/run.mjs` run. Reproduce with the steps in [README.md](README.md).

- **Date**: 2026-07-10 (title-ranking tokens included)
- **Environment**: Apple M1 Max, macOS, Node v22.18.0 (arm64)
- **Versions**: chaza (this repo, `zig build -Doptimize=ReleaseFast`), tinysearch 0.10.0 (`--release`, warm cargo cache)
- **Corpora**: Wikipedia extracts (Korean + English mixed), 100 / 500 / 1,000 documents, identical input file for both engines
- **Config**: chaza indexes `title` + `body` (`bench/chaza.json`), matching tinysearch's fixed schema. chaza's prefix indexing stays at its default (`title` only) and its built-in default stopword list (154 entries) is active — tinysearch has no stopword removal.

## Speed and size

| corpus | metric | chaza | chaza w/o 초성+prefix¹ | tinysearch |
|---|---|---|---|---|
| 100 docs | index build (median) | **7.8 ms** | — | 4,568 ms |
| | search latency | **5.2 µs/query** | — | 313 µs/query |
| | output raw | 50.3 KB + 11.5 KB loader | 44.7 KB | 142.8 KB + 2.4 KB glue |
| | output gzip | **24.7 KB** + 3.6 KB | 19.8 KB | 69.4 KB + 0.9 KB |
| 500 docs | index build (median) | **47.1 ms** | — | 4,742 ms |
| | search latency | **17.0 µs/query** | — | 444 µs/query |
| | output gzip | 160.5 KB | **123.2 KB** | 156.2 KB |
| 1,000 docs | index build (median) | **97.1 ms** | — | 4,725 ms |
| | search latency | **29.8 µs/query** | — | 659 µs/query |
| | output gzip | 328.2 KB | **251.2 KB** | 264.3 KB |

¹ Feature-parity build (`bench/chaza-plain.json`): choseong and prefix tokens are chaza-only capabilities tinysearch does not have, so this column isolates their cost for an apples-to-apples size comparison.

Notes:

- chaza's build time scales linearly with corpus size; tinysearch's is dominated by the fixed ~4.6 s Rust crate compilation. The first-ever tinysearch build also compiles dependencies (minutes, not shown).
- Search latency: both engines scan per document, so both scale linearly; the gap stays ~20–60×.
- **The apparent size crossover is entirely feature cost.** With its full feature set (choseong + title prefix tokens) chaza reaches gzip parity with tinysearch around 500 docs and is ~20% larger at 1,000. At feature parity, chaza is smaller at every scale — 3.6× at 100 docs, 22% at 500, 6% at 1,000. Choseong + prefix cost ~74 KB gzip at 1,000 docs; that is the price of two capabilities tinysearch lacks, and both can be disabled per site.
- gzip compresses chaza's binary-fuse fingerprints poorly (high-entropy bytes) while tinysearch's storage compresses well — that is why the raw-size gap (508 vs 447 KB at 1,000 docs) narrows after compression.
- The built-in stopword list trims the filter section ~4% (e.g., 529 → 508 KB raw at 1,000 docs).

## Accuracy

Method (see `benchAccuracy` in `run.mjs`):

- **Ground truth**: a neutral reference tokenizer (lowercase + Unicode word split — neither engine's own) maps each document to its token set. For a query token, the truth set is every document that literally contains it.
- **Positive queries** (120): real tokens sampled deterministically from the corpus vocabulary, stratified 60 Korean / 60 Latin → recall@20 (capped at truth size) and precision.
- **Negative queries** (200): letters-only fake tokens (`zq` + 8 random letters) guaranteed absent from the vocabulary → any returned document is a false positive. Per-doc FP rate = returned docs / (queries × corpus size).
- **Known-item queries** (1 per doc): the rarest token of each document's title → MRR@10 (is the source document ranked first?).
- **Choseong queries** (chaza only): initial consonants (≤3 jamo) of the first Korean word of each Korean title → is the source document in the top 20?

| corpus | metric | chaza | tinysearch |
|---|---|---|---|
| 100 docs | recall@20 | **96.7%** | 87.5% |
| | precision | 68.5% | 77.4% |
| | false positives | 0.39%/doc | 0.27%/doc |
| | known-item MRR@10 | **0.990** | 0.980 |
| | choseong retrieval | **100.0%** | — |
| 500 docs | recall@20 | **97.5%** | 88.4% |
| | precision | 35.1% | 43.2% |
| | false positives | 0.36%/doc | 0.31%/doc |
| | known-item MRR@10 | **0.992** | 0.969 |
| | choseong retrieval | **99.6%** | — |
| 1,000 docs | recall@20 | **99.7%** | 92.0% |
| | precision | 21.9% | 32.2% |
| | false positives | 0.35%/doc | 0.31%/doc |
| | known-item MRR@10 | **0.982** | 0.962 |
| | choseong retrieval | **97.3%** | — |

### Reading the numbers

- **Recall**: chaza ~97–100% — its script-aware tokenizer segments punctuation- and script-boundary-attached words that tinysearch's whitespace split misses (87–92%). chaza's few misses are its own stopwords: the positive-query sample includes words like *the*/*of*, which chaza deliberately does not index (searching them is meaningless, but the neutral truth counts them).
- **False positives**: chaza's measured 0.35–0.39%/doc matches the theoretical 1/256 ≈ 0.4% of its 8-bit binary fuse fingerprints. tinysearch measures slightly lower (0.27–0.31%).
- **Precision** declines for both engines as the corpus grows — common-token queries return the 20-result page, and both engines pad it: chaza with prefix matches (its last-token prefix matching is counted against the strict exact-token truth) plus FP ties, tinysearch with its top-N scoring that always returns *something* even for weak matches.
- **Known-item MRR: fixed by title-ranking tokens.** Ties on `hits` used to fall back to document input order, letting false positives and body-only matches rank above a true title match (MRR degraded to 0.38 at 1,000 docs). Title tokens are now duplicated with a `\x03` marker and probed at query time as a secondary sort key — a false positive would need to pass two independent probes (~0.002%). MRR@10 is now 0.98–0.99 at every scale, ahead of tinysearch's ~0.96–0.98, and choseong retrieval no longer collapses with corpus size (97–100%). Cost: ~2% bundle size.

## Overall

At blog scale (≤ a few hundred documents) chaza wins build time (~650×), search latency (~55×), and transfer size (~3×) while beating tinysearch on recall, with choseong search as a capability tinysearch does not have. At feature parity chaza's output is smaller at every measured scale; with the Korean feature set enabled, gzip size reaches parity with tinysearch around 500 documents. With title-ranking tokens, known-item lookup quality (MRR@10 0.98+) now holds at every measured scale.
