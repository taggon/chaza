# How Chaza works

Internals of the index, the filters, and the search runtime. For usage, see the [README](../README.md); for the full format specification, see [SPEC.md](../SPEC.md).

## Architecture

```
build time                              runtime (browser)
──────────                              ─────────────────
corpus.json ─┐                          fetch(chaza.wasm)
chaza.json  ─┤                            │
              ▼                            ▼
          chaza CLI ──► chaza.wasm  ──► chaza.js loader
          (patches          │              ├─ instantiate (streaming-capable)
         runtime.wasm)      │              ├─ read metadata slot via meta_fields()
                            └──────────────┴─ search() (runtime self-initializes)
```

The runtime WASM is compiled **once** and embedded in the CLI binary. Building an index never compiles anything — the CLI tokenizes the corpus, builds filters, and patches the index bytes into the runtime module as a data segment. This is the main difference from tinysearch, which generates and compiles a Rust crate per index.

## Tokenization pipeline

Shared by the indexer (native) and the runtime (wasm) as the same Zig code — bit-level consistency between index-time and query-time tokens is enforced by the compiler, not by a spec document.

1. Lowercase (ASCII A–Z)
2. Segment by script group (Latin, Hangul, Han, Hiragana, Katakana, Number). A run of the same group is one token; a group switch is a token boundary. Combining marks attach to the preceding run.
3. Remove stopwords (`--stopwords` file, if given)
4. Deduplicate per document
5. If `choseong_search`: add choseong prefix tokens (marker `\x01`), length 2–`choseong_max_len` for body words; title words keep length 1–`choseong_max_len`
6. Words in `prefix_fields`: add edge n-gram prefix tokens (marker `\x02`), first 2–8 codepoints (proper prefixes only)
7. Deduplicate again

Input is assumed UTF-8 + NFC. NFD (decomposed) Hangul breaks choseong extraction.

### Stopwords

A built-in default list (English function words + standalone Korean fillers, curated to never contain a plausible standalone search term) is embedded in the CLI and applied automatically. `--stopwords <file>` replaces it; an empty file disables removal.

Stopwords are removed **at index time only**. The list is not shipped in the bundle, so the runtime cannot filter them from queries — a stopword never matches any document. If only some query tokens are stopwords, the remaining tokens still match (OR ranking); if every token is a stopword, the result is empty.

### Choseong tokens (`\x01`)

For each Hangul word, the initial consonants of its first 1–`choseong_max_len` syllables become extra tokens, tagged with a `\x01` marker byte: 안녕하세요 → `\x01ㅇ`, `\x01ㅇㄴ`, `\x01ㅇㄴㅎ`. **Body words skip the single-jamo prefix** (length 1) to avoid over-broad matches — a lone `ㅇ` matches almost every Korean document — so body choseong starts at length 2. Title words keep length 1 so single-consonant queries still find title matches. At query time, a token consisting entirely of choseong jamo gets the same marker, so `ㅇㄴ` matches any document with a word whose initials start ㅇㄴ. No special-casing in the search path — marker tokens are looked up like any other token.

### Prefix tokens (`\x02`)

Words in `prefix_fields` (default: `title`) additionally index their first 2–8 codepoints as `\x02`-tagged tokens: "programming" → `\x02pr` … `\x02programm`. At query time only the **last** token — the word being typed — is probed both exactly and as `\x02`-prefixed; either hit counts as one match. This gives search-as-you-type on titles for a few dozen bytes per document, while body words stay exact-match.

Prefix lookups are impossible at the filter level (see below) — materializing prefixes as tokens at index time is the only route, and it is the same trick choseong uses.

### Title-ranking tokens (`\x03`)

Tokens from the title field (and their choseong tokens) are indexed a second time with a `\x03` marker. At query time every token is also probed as `\x03`-marked; the count (`title_hits`) is a **ranking-only** signal — it never changes `hits` or the JS API. On equal `hits`, documents whose *title* matches outrank body-only matches and false positives (`\x03` tokens live in the 16-bit hi filter, so a fake title signal needs two independent probes to pass: ~0.2% × 0.0015%). This lifted known-item MRR@10 from 0.38 to 0.98+ on a 1,000-document corpus for ~2% extra bundle size.

## Filters: two corpus-global binary fuse filters

All (token, document) pairs go into two corpus-wide [binary fuse filters](https://arxiv.org/abs/2201.01174) — static probabilistic sets:

- **lo** — regular + `\x01` choseong tokens, 9-bit fingerprints (~0.2% false positives)
- **hi** — `\x02` prefix + `\x03` title-ranking tokens, 16-bit fingerprints (~0.0015%) — these feed search-as-you-type and ranking, where a false positive is directly user-visible
- Exactly 3 memory probes per lookup; fingerprints are bit-packed (any width 8–16, self-described by the blob header)
- Exact membership only: no enumeration, no deletion, no prefix queries

Until v1.3 every document had its own 8-bit filter. That wastes space at per-document scale: the fuse size factor is ~1.45× at a few hundred keys versus ~1.15× at corpus scale, plus a 28-byte header per document and per-segment rounding. Merging everything into one global filter (keying each entry as `pairKey(doc_id, token_key)` — the doc id mixed through splitmix64, XORed with the token key) cut the filter section by ~29%, and that saving was reinvested into wider fingerprints: same transfer size, half the false positives, and a near-exact hi tier.

Three independent hash layers:

```
token ─ xxhash64 ─► u64 key ─ ⊕ splitmix64(doc_id) ─► pair key ─ murmur64(key + seed) ─► 3 positions + w-bit fingerprint
        (chaza level)           (pair level)                      (filter internal)
```

Construction and lookup are both pure Zig (ported from the C `fastfilter` reference, generalized to packed fingerprint widths). Because the generator and runtime share the same code, hash mismatch between build and query time is structurally impossible.

The filters are the only representation stored — no original text or token list survives into the bundle.

## Search execution

`search(query_len, max_results)` runs entirely inside the WASM module (the query itself was copied into the runtime-owned buffer via `prepare_query`):

1. Tokenize the query with the same pipeline as indexing
2. Mark choseong-only tokens with `\x01`; build the `\x02` prefix probe for the last token
3. Cap at 16 query tokens (see below)
4. For every document, count how many query tokens hit the lo filter under that document's pair key (`hits`) and how many hit as `\x03` title probes in the hi filter (`title_hits`)
5. Keep documents with `hits ≥ 1`, sort by `hits` desc, then `title_hits` desc, then document input order
6. Truncate to `max_results` (0 → 20)
7. Materialize the results into a single buffer: `[u32 count][per result: [u32 hits][title\0][url\0][meta_value\0 × num_meta_fields]]`, little-endian

The loader parses that buffer directly into `{ title, url, meta, hits }` objects — wasm owns all string materialization, so no separate string-pool lookup happens on the JS side.

### Why cap at 16 tokens?

OR semantics means every token gives every document an independent ~0.2% false-positive chance. Expected fake hits per token ≈ N/512 documents. Without a cap, a very long query would falsely match a large fraction of all documents. 16 tokens keeps the noise floor at ~3% of documents in the worst case while never truncating a realistic query.

## Output format

`chaza.wasm` is a plain valid WASM module. The CLI's wasm patcher (`src/wasm_patch.zig`) rewrites the pre-built runtime module section by section, recomputing the LEB128 length headers:

- **memory section**: initial pages extended so the index region fits inside initial memory
- **data section**: one active data segment at the old memory end (page-aligned) carrying the index bytes
- **data section**: two active segments added — a metadata segment (8 bytes: index ptr+len LE) written to the runtime's `g_embedded_index` slot, and an index segment carrying the index bytes at the old memory end

The loader instantiates the module — `WebAssembly.instantiateStreaming` works when the server returns `application/wasm`, so compilation overlaps the download — reads the metadata slot via `meta_fields()`, and calls `search()`. The runtime self-initializes the `IndexView` from the embedded metadata; no `set_index` call or index copy happens at load time. The query buffer is runtime-owned (`prepare_query`), so JS no longer manages allocation policy. Memory growth never moves wasm linear memory, so the index region stays valid.

The index itself is a flat, 4-byte-aligned, little-endian layout (`[header][meta-names][doc-table][string-pool][filter-data]`, with filter-data holding the two global blobs as `[lo_len][hi_len][lo][hi]`) that the runtime reads zero-parse via pointer casts. See [SPEC.md](../SPEC.md) for field-level detail.

## Practical size limits

Three ceilings, in the order they are hit:

1. **False-positive noise.** Fake results per query token ≈ N/512. At ~10,000 documents a single-token query can fill the default 20-result page with statistical noise. This is the real ceiling: **a few thousand documents** (chaza is designed and verified up to 1,000).
2. **Bundle size.** Filters are high-entropy bytes — gzip barely helps. Thousands of documents mean multi-megabyte downloads.
3. **CPU.** Search is a linear scan: docs × tokens × 3 probes. Only matters past ~100k documents, long after 1 and 2.
