# chaza

A minimal static-site search engine — Zig + WASM. Finds Korean text even when you type only initial consonants (choseong).

## Why?

- **Small.** The index stores binary fuse filters, not document text. ~0.5 MB for a few hundred pages.
- **Korean choseong search.** Type ㄱㄴ and match 가나, 강남, 경남…
- **All query work in WASM.** Tokenization, hashing, lookup, sorting — all in the bundled WASM module. JavaScript only passes strings and renders results.
- **No toolchain for end users.** The runtime WASM is embedded in the CLI binary. Building an index is just byte concatenation — no compiler needed.

## Install

**npm:**

```bash
npm install chaza
```

**Shell (standalone binary):**

```bash
curl -fsSL https://raw.githubusercontent.com/taggon/chaza/main/scripts/install.sh | sh
```

Platform binaries are auto-selected for macOS and Linux (x64, arm64).

## Quick start

```bash
# Build a search index from a JSON corpus
npx chaza build corpus.json -o chaza.bundle --config chaza.json
```

This produces two files:

| File | Description |
|------|-------------|
| `chaza.bundle` | Bundle: `[runtime.wasm][index][tail-meta 16 B]`. **Not a pure WASM module** — load via the loader. |
| `chaza.js` | ESM loader shared by all sites. |

Add `--no-js` to skip writing the loader.

### In your page

```html
<script type="module">
  import { Chaza } from "chaza";
  const chaza = await Chaza.load("./chaza.bundle");
  const results = chaza.search("ㄱㄴ");
</script>
```

Each result contains `{ title, url, meta }`.

## CLI

```bash
chaza build <corpus.json> [options]

Options:
  -o, --output <path>      Output bundle path (default: chaza.bundle)
  --config <path>          Path to chaza.json config file
  --stopwords <path>       Stopwords file (line-separated)
  --no-choseong            Disable choseong search
  --no-js                  Skip writing chaza.js loader
  -q, --quiet              Suppress progress output
  -h, --help               Show this help
```

## Input format (tinysearch-compatible)

```json
[
  {
    "title": "Post Title",
    "url": "https://example.com/post",
    "body": "Full text to index (not stored in the output)",
    "path": "/posts/1",
    "date": "2026-01-01"
  }
]
```

- **title** — indexed + stored (shown in results)
- **url** — stored only (shown in results, not searched)
- **body** — indexed only (searched but never stored in the output)
- Any other fields listed in `metadata_fields` — stored only, as strings

Numbers are stringified automatically.

## Config file (`chaza.json`)

```json
{
  "schema": {
    "indexed_fields": ["title", "body"],
    "metadata_fields": ["path", "date"],
    "url_field": "url"
  },
  "korean": {
    "choseong_search": true,
    "choseong_max_len": 3
  }
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `indexed_fields` | `["title"]` | Fields to tokenize and index |
| `metadata_fields` | `[]` | Fields to store for display (not indexed) |
| `url_field` | `"url"` | Which field holds the URL |
| `choseong_search` | `true` | Enable choseong prefix tokens |
| `choseong_max_len` | `3` | Max choseong prefix length (1–3) |

## Search behavior

- **Multi-token queries are AND** — all tokens must match.
- **No ranking.** Results are returned in document order (or sorted by a metadata field).
- **Choseong tokens work like regular tokens.** A query `ㅅㅈ` matches any document whose indexed text contains a word starting with those initial consonants.
- **`max_results`** defaults to 20; pass 0 for the default.

```js
chaza.search("hello", { maxResults: 10 });
chaza.search("hello", { sortFieldIdx: 0, sortDesc: true });
```

### Sorting

Metadata field sorting is **string lexicographic only** (ascending or descending). Documents missing the field go last. For date/number sorting, use ISO 8601 dates or zero-padded numbers in the input data.

## How it works

### Tokenization pipeline (shared by indexer and runtime)

1. Lowercase (ASCII A–Z)
2. Segment by script group (Latin, Hangul, Han, Hiragana, Katakana, Number)
3. Remove stopwords (`--stopwords` file)
4. Deduplicate per document
5. If `choseong_search`: add choseong prefix tokens (marker `\x01`), length 1–`choseong_max_len`
6. Deduplicate again

The indexer and runtime share the same Zig tokenization code — bit-level consistency is guaranteed.

### Filter: Binary Fuse (BinaryFuse8)

Each document gets its own [binary fuse filter](https://arxiv.org/abs/2201.01174) — a static, probabilistic set with ~0.4% false-positive rate (8-bit fingerprints, 3 fixed probes per lookup). Roughly **9 bits per token**.

Token → xxhash64 → 64-bit key → binary fuse internal hash → 3 positions + fingerprint XOR.

The filter is the only representation stored. No original text or tokens are kept.

### Bundle format

```
[runtime.wasm][index bytes][tail-meta 16 B]
```

The tail meta stores `wasm_len` and `index_len` (little-endian). The loader reads the last 16 bytes, slices the WASM and index sections, instantiates the WASM, and injects the index.

`chaza.bundle` is **not a valid WASM module** — it must be loaded through `chaza.js`.

## Limitations

- **Input must be UTF-8 + NFC.** NFD (decomposed) Hangul will break choseong extraction.
- **String sort only.** No numeric or date-aware sorting. Use ISO 8601 / zero-padding in the source data.
- **Static index.** No incremental updates. Rebuild from the corpus to add/remove documents.
- **False positives.** ~0.4% of queries may match a document that doesn't actually contain the token. There is no brute-force verification step.

## Acknowledgements

Inspired by [tinysearch](https://github.com/tinysearch/tinysearch).

## License

MIT
