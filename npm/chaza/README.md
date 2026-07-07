# chaza

A minimal static-site search engine — Zig + WASM. Finds Korean text even when you type only initial consonants (choseong).

Type `ㄱㄴ` and match 가나, 강남, 경남… All query work runs in a bundled WASM module; JavaScript only passes strings and renders results.

## Features

- **Small index.** Stores binary fuse filters, not document text. ~0.5 MB for a few hundred pages.
- **Korean choseong search.** Match words by their initial consonants (`ㄱㄴ` → 가나, 강남, 경남).
- **All query work in WASM.** Tokenization, hashing, lookup, and sorting happen inside the WASM module.
- **No toolchain for end users.** The runtime WASM is embedded in the CLI binary. Building an index is just byte concatenation — no compiler needed.

## Installation

```bash
npm install chaza
```

Or install the standalone binary via shell:

```bash
curl -fsSL https://raw.githubusercontent.com/taggon/chaza/main/scripts/install.sh | sh
```

Platform binaries are auto-selected for macOS and Linux (x64, arm64).

## Quick start

### 1. Build an index

```bash
npx chaza build corpus.json -o chaza.bundle --config chaza.json
```

This produces two files:

| File | Description |
|------|-------------|
| `chaza.bundle` | Bundle: `[runtime.wasm][index][tail-meta 16 B]`. **Not a pure WASM module** — load via the loader. |
| `chaza.js` | ESM loader shared by all sites. |

Pass `--no-js` to skip writing the loader.

### 2. Search from your page

```html
<script type="module">
  import { Chaza } from "chaza";

  const chaza = await Chaza.load("./chaza.bundle");
  const results = chaza.search("ㄱㄴ");
  // results: Array<{ title, url, meta }>
</script>
```

Each result is `{ title, url, meta }`, where `meta` is an object keyed by your configured metadata fields.

## Input format

The corpus is a JSON array of documents (tinysearch-compatible):

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

| Field | Role |
|-------|------|
| `title` | Indexed **and** stored (shown in results) |
| `url` | Stored only (shown in results, not searched) |
| `body` | Indexed only (searched, never stored in the output) |
| others | Any field listed in `metadata_fields` is stored as a string |

Numbers are stringified automatically.

## Configuration (`chaza.json`)

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

## API

```js
import { Chaza } from "chaza";

const chaza = await Chaza.load("./chaza.bundle");

// Basic search (defaults to 20 results)
chaza.search("hello");

// Limit results (pass 0 for the default of 20)
chaza.search("hello", { maxResults: 10 });

// Sort by a metadata field (index into metadata_fields), descending
chaza.search("hello", { sortFieldIdx: 0, sortDesc: true });
```

### Search behavior

- **Multi-token queries are AND.** All tokens must match.
- **No ranking.** Results are returned in document order unless you sort by a metadata field.
- **Choseong tokens work like regular tokens.** `ㅅㅈ` matches any document whose indexed text contains a word starting with those initial consonants.
- **Sorting is string lexicographic only** (ascending or descending). Documents missing the field go last. For date/number sorting, use ISO 8601 dates or zero-padded numbers in the input data.

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

## How it works

### Tokenization pipeline

The indexer and runtime share the same Zig tokenization code, so bit-level consistency is guaranteed:

1. Lowercase (ASCII A–Z)
2. Segment by script group (Latin, Hangul, Han, Hiragana, Katakana, Number)
3. Remove stopwords (`--stopwords` file)
4. Deduplicate per document
5. If `choseong_search`: add choseong prefix tokens (marker `\x01`), length 1–`choseong_max_len`
6. Deduplicate again

### Filter: Binary Fuse (BinaryFuse8)

Each document gets its own [binary fuse filter](https://arxiv.org/abs/2201.01174) — a static, probabilistic set with a ~0.4% false-positive rate (8-bit fingerprints, 3 fixed probes per lookup). Roughly **9 bits per token**.

```
Token → xxhash64 → 64-bit key → binary fuse hash → 3 positions + fingerprint XOR
```

The filter is the only representation stored. No original text or tokens are kept.

### Bundle format

```
[runtime.wasm][index bytes][tail-meta 16 B]
```

The tail meta stores `wasm_len` and `index_len` (little-endian). The loader reads the last 16 bytes, slices the WASM and index sections, instantiates the WASM, and injects the index.

`chaza.bundle` is **not a valid WASM module** — it must be loaded through `chaza.js`.

## Limitations

- **Input must be UTF-8 + NFC.** NFD (decomposed) Hangul will break choseong extraction.
- **String sort only.** No numeric or date-aware sorting — use ISO 8601 / zero-padding in the source data.
- **Static index.** No incremental updates; rebuild from the corpus to add or remove documents.
- **False positives.** ~0.4% of queries may match a document that doesn't contain the token. There is no brute-force verification step.

## Acknowledgements

Inspired by [tinysearch](https://github.com/tinysearch/tinysearch).

## License

MIT
