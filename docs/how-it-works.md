# How Chaza works

Internals of the index, the filters, and the search runtime. For usage, see the [README](../README.md); for the full format specification, see [SPEC.md](../SPEC.md).

## Architecture

```
build time                              runtime (browser)
──────────                              ─────────────────
corpus.json ─┐                          fetch(chaza.bundle)
chaza.json  ─┤                            │
             ▼                            ▼
        chaza CLI ──► chaza.bundle ──► chaza.js loader
        (embeds           │              ├─ slice wasm / index via tail-meta
       runtime.wasm)      │              ├─ instantiate wasm
                          └──────────────┴─ set_index() → search()
```

The runtime WASM is compiled **once** and embedded in the CLI binary. Building an index never compiles anything — the CLI tokenizes the corpus, builds filters, and concatenates bytes. This is the main difference from tinysearch, which generates and compiles a Rust crate per index.

## Tokenization pipeline

Shared by the indexer (native) and the runtime (wasm) as the same Zig code — bit-level consistency between index-time and query-time tokens is enforced by the compiler, not by a spec document.

1. Lowercase (ASCII A–Z)
2. Segment by script group (Latin, Hangul, Han, Hiragana, Katakana, Number). A run of the same group is one token; a group switch is a token boundary. Combining marks attach to the preceding run.
3. Remove stopwords (`--stopwords` file, if given)
4. Deduplicate per document
5. If `choseong_search`: add choseong prefix tokens (marker `\x01`), length 1–`choseong_max_len`
6. Words in `prefix_fields`: add edge n-gram prefix tokens (marker `\x02`), first 2–8 codepoints (proper prefixes only)
7. Deduplicate again

Input is assumed UTF-8 + NFC. NFD (decomposed) Hangul breaks choseong extraction.

### Stopwords

A built-in default list (English function words + standalone Korean fillers, curated to never contain a plausible standalone search term) is embedded in the CLI and applied automatically. `--stopwords <file>` replaces it; an empty file disables removal.

Stopwords are removed **at index time only**. The list is not shipped in the bundle, so the runtime cannot filter them from queries — a stopword never matches any document. If only some query tokens are stopwords, the remaining tokens still match (OR ranking); if every token is a stopword, the result is empty.

### Choseong tokens (`\x01`)

For each Hangul word, the initial consonants of its first 1–`choseong_max_len` syllables become extra tokens, tagged with a `\x01` marker byte: 안녕하세요 → `\x01ㅇ`, `\x01ㅇㄴ`, `\x01ㅇㄴㅎ`. At query time, a token consisting entirely of choseong jamo gets the same marker, so `ㅇㄴ` matches any document with a word whose initials start ㅇㄴ. No special-casing in the search path — marker tokens are looked up like any other token.

### Prefix tokens (`\x02`)

Words in `prefix_fields` (default: `title`) additionally index their first 2–8 codepoints as `\x02`-tagged tokens: "programming" → `\x02pr` … `\x02programm`. At query time only the **last** token — the word being typed — is probed both exactly and as `\x02`-prefixed; either hit counts as one match. This gives search-as-you-type on titles for a few dozen bytes per document, while body words stay exact-match.

Prefix lookups are impossible at the filter level (see below) — materializing prefixes as tokens at index time is the only route, and it is the same trick choseong uses.

### Title-ranking tokens (`\x03`)

Tokens from the title field (and their choseong tokens) are indexed a second time with a `\x03` marker. At query time every token is also probed as `\x03`-marked; the count (`title_hits`) is a **ranking-only** signal — it never changes `hits` or the JS API. On equal `hits`, documents whose *title* matches outrank body-only matches and false positives (a false positive would have to pass two independent probes, ~0.4%² ≈ 0.002%). This lifted known-item MRR@10 from 0.38 to 0.98 on a 1,000-document corpus for ~2% extra bundle size.

## Filter: BinaryFuse8

Each document gets its own [binary fuse filter](https://arxiv.org/abs/2201.01174) — a static probabilistic set:

- ~9 bits per token (≈13% overhead over the theoretical minimum)
- Exactly 3 memory probes per lookup
- ~0.4% false positives (8-bit fingerprints, 1/256)
- Exact membership only: no enumeration, no deletion, no prefix queries

Two independent hash layers:

```
token ─ xxhash64 ─► u64 key ─ murmur64(key + seed) ─► 3 positions + 8-bit fingerprint
        (chaza level)          (filter internal)
```

Construction and lookup are both pure Zig (ported from the C `fastfilter` reference). Because the generator and runtime share the same code, hash mismatch between build and query time is structurally impossible.

The filter is the only representation stored — no original text or token list survives into the bundle.

## Search execution

`search(query_ptr, query_len, max_results)` runs entirely inside the WASM module:

1. Tokenize the query with the same pipeline as indexing
2. Mark choseong-only tokens with `\x01`; build the `\x02` prefix probe for the last token
3. Cap at 16 query tokens (see below)
4. For every document, count how many query tokens hit its filter (`hits`) and how many hit as `\x03` title probes (`title_hits`)
5. Keep documents with `hits ≥ 1`, sort by `hits` desc, then `title_hits` desc, then document input order
6. Truncate to `max_results` (0 → 20)
7. Return a buffer: `[u32 count][(u32 doc_id, u32 hits) × count]`, little-endian

The loader reads doc ids, then resolves title / url / metadata from the string pool and exposes `hits` on each result.

### Why cap at 16 tokens?

OR semantics means every token gives every document an independent ~0.4% false-positive chance. Expected fake hits per token ≈ N/256 documents. Without a cap, a 255-token query would falsely match ~64% of all documents. 16 tokens keeps the noise floor at ~6% of documents in the worst case while never truncating a realistic query.

## Bundle format

```
[runtime.wasm][index bytes][tail-meta 16 B]
```

Tail meta (little-endian): magic, version, `wasm_len`, `index_len`. The loader reads the final 16 bytes, slices the two sections, instantiates the WASM, copies the index in, and calls `set_index`.

Bytes are **appended**, not spliced into the WASM data section, because WASM sections carry LEB128 length headers that would need recomputing for every index size. Consequence: `chaza.bundle` is not a valid WASM module and `WebAssembly.instantiateStreaming` on it fails — always go through `chaza.js`.

The index itself is a flat, 4-byte-aligned, little-endian layout (`[header][meta-names][doc-table][string-pool][filter-data]`) that the runtime reads zero-parse via pointer casts. See [SPEC.md](../SPEC.md) for field-level detail.

## Practical size limits

Three ceilings, in the order they are hit:

1. **False-positive noise.** Fake results per query token ≈ N/256. At ~5,000 documents a single-token query can fill the default 20-result page with statistical noise. This is the real ceiling: **a few thousand documents**.
2. **Bundle size.** Filters are ~1.1 KB/doc of high-entropy bytes — gzip barely helps. 5,000 docs ≈ 5.5 MB+ download.
3. **CPU.** Search is a linear scan: docs × tokens × 3 probes. Only matters past ~100k documents, long after 1 and 2.
