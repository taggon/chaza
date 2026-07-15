# Benchmark results: chaza vs tinysearch

Snapshot of a full `node bench/run.mjs` run. Reproduce with the steps in [README.md](README.md).

- **Date**: 2026-07-15 (v1.4.1 body single-jamo choseong skipped; lo 9-bit + hi 16-bit)
- **Environment**: Apple M1 Max, macOS, Node v22.18.0 (arm64)
- **Versions**: chaza (this repo, `zig build -Doptimize=ReleaseFast`), tinysearch 0.10.0 (`--release`, warm cargo cache)
- **Corpora**: Wikipedia extracts (Korean + English mixed), 100 / 500 / 1,000 documents, identical input file for both engines
- **Config**: chaza indexes `title` + `body` (`bench/chaza.json`), matching tinysearch's fixed schema. chaza's prefix indexing stays at its default (`title` only) and its built-in default stopword list (154 entries) is active — tinysearch has no stopword removal.

## Speed and size

| corpus | metric | chaza | chaza w/o 초성+prefix¹ | tinysearch |
|---|---|---|---|---|
| 100 docs | index build (median) | **5.8 ms** | — | 4,501 ms |
| | search latency | **6.0 µs/query** | — | 309 µs/query |
| | output raw | 45.2 KB + 11.5 KB loader | 39.1 KB | 131.8 KB + 2.4 KB glue |
| | output gzip | **24.9 KB** + 3.5 KB | 19.5 KB | 60.4 KB + 0.9 KB |
| 500 docs | index build (median) | **44.2 ms** | — | 4,541 ms |
| | search latency | **22.3 µs/query** | — | 459 µs/query |
| | output gzip | 159.1 KB | **120.7 KB** | 147.0 KB |
| 1,000 docs | index build (median) | **91.6 ms** | — | 4,569 ms |
| | search latency | **39.6 µs/query** | — | 663 µs/query |
| | output gzip | 323.6 KB | **242.7 KB** | 255.1 KB |

¹ Feature-parity build (`bench/chaza-plain.json`): choseong and prefix tokens are chaza-only capabilities tinysearch does not have, so this column isolates their cost for an apples-to-apples size comparison.

Notes:

- chaza's build time scales linearly with corpus size; tinysearch's is dominated by the fixed ~4.5 s Rust crate compilation. The first-ever tinysearch build also compiles dependencies (minutes, not shown).
- Search latency: both engines scan per document, so both scale linearly; the gap stays ~20–55×. v1.4's global filter adds a few µs over v1.3's per-document filters (scattered probes into one large array) — irrelevant at this scale.
- **The apparent size crossover is entirely feature cost.** With its full feature set (choseong + title prefix tokens) chaza reaches gzip parity with tinysearch around 500 docs and is ~27% larger at 1,000. At feature parity, chaza is smaller at every scale — 3.1× at 100 docs, 18% at 500, 5% at 1,000. Choseong + prefix cost ~81 KB gzip at 1,000 docs; that is the price of two capabilities tinysearch lacks, and both can be disabled per site. Body single-jamo choseong prefixes (`\x01ㅇ` etc.) are skipped to trim size — title tokens keep them so choseong retrieval is unaffected.
- v1.4's corpus-global filters are ~87% dense, so gzip barely compresses them — unlike v1.3's per-document filters, whose segment-rounding zero padding gzip absorbed. Raw size dropped 17% versus v1.3 (515 → 427 KB at 1,000 docs) while gzip stayed level (328 → 331 KB) — the structural saving was reinvested into wider fingerprints (see accuracy).

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
| | precision | **88.0%** | 77.4% |
| | false positives | **0.19%/doc** | 0.27%/doc |
| | known-item MRR@10 | **0.990** | 0.980 |
| | choseong retrieval | **100.0%** | — |
| 500 docs | recall@20 | **98.4%** | 88.4% |
| | precision | **66.0%** | 43.2% |
| | false positives | **0.19%/doc** | 0.31%/doc |
| | known-item MRR@10 | **0.993** | 0.976 |
| | choseong retrieval | **99.6%** | — |
| 1,000 docs | recall@20 | **99.8%** | 92.1% |
| | precision | **46.8%** | 32.3% |
| | false positives | **0.19%/doc** | 0.31%/doc |
| | known-item MRR@10 | **0.989** | 0.968 |
| | choseong retrieval | **97.3%** | — |

### Reading the numbers

- **Recall**: chaza ~97–100% — its script-aware tokenizer segments punctuation- and script-boundary-attached words that tinysearch's whitespace split misses (88–92%). chaza's few misses are its own stopwords: the positive-query sample includes words like *the*/*of*, which chaza deliberately does not index (searching them is meaningless, but the neutral truth counts them).
- **False positives: halved by v1.4.** chaza's measured 0.19%/doc matches the theoretical 2⁻⁹ ≈ 0.195% of the 9-bit fingerprints in its global lo filter (v1.3's 8-bit per-document filters measured 0.35–0.39%). Merging the per-document filters into one corpus-global filter recovered the space wasted by per-document sizing (~29% of the filter section) and reinvested it into the extra fingerprint bit — same gzip transfer size, half the false positives. chaza is now below tinysearch (0.27–0.31%) at every scale.
- **Precision more than doubled** (21.9% → 46.8% at 1,000 docs) for two reasons: fewer filter false positives padding common-token result pages, and `\x02` prefix / `\x03` title-ranking tokens now living in a separate 16-bit "hi" filter (FP ≈ 0.0015%) — search-as-you-type matches are now essentially exact. The remaining gap to 100% is mostly chaza's last-token prefix matching being counted against the strict exact-token truth.
- **Known-item MRR: held by title-ranking tokens.** Title tokens are duplicated with a `\x03` marker and probed at query time as a secondary sort key; since v1.4 these probes hit the 16-bit hi filter, so a false title signal must pass two independent probes (~0.2% × 0.0015%). MRR@10 stays 0.99 at every scale, ahead of tinysearch's ~0.96–0.97, and choseong retrieval holds at 97–100%.

## Overall

At blog scale (≤ a few hundred documents) chaza wins build time (~750×), search latency (~50×), and transfer size (~2.4×) while beating tinysearch on recall, precision, false-positive rate, and known-item ranking, with choseong search as a capability tinysearch does not have. At feature parity chaza's output is smaller at every measured scale; with the Korean feature set enabled, gzip size reaches parity with tinysearch around 500 documents. v1.4's two-tier global filters halved the false-positive rate at the same transfer size — chaza's headline weakness versus tinysearch (filter noise) is gone.
