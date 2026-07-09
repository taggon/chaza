# Chaza

A minimal static-site search engine — Zig + WASM. Finds Korean text even when you type only initial consonants (choseong).

Type `ㄱㄴ` and match 가나, 강남, 경남… All query work runs in a bundled WASM module; JavaScript only passes strings and renders results.

## Features

- **Small index.** Stores binary fuse filters, not document text. ~0.5 MB for a few hundred pages.
- **Korean choseong search.** Match words by their initial consonants (`ㄱㄴ` → 가나, 강남, 경남).
- **All query work in WASM.** Tokenization, hashing, lookup, and ranking happen inside the WASM module.
- **No toolchain for end users.** The runtime WASM is embedded in the CLI binary. Building an index is just byte concatenation — no compiler needed.

## Installation

```bash
npm install chaza
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
  // results: Array<{ title, url, meta, hits }>
</script>
```

Each result is `{ title, url, meta, hits }`, where `meta` is an object keyed by your configured metadata fields and `hits` is the number of query tokens that matched (0~16 — only the first 16 query tokens are considered).

## Input format

The corpus is a JSON array of documents (tinysearch-compatible):

```json
[
  {
    "title": "Post Title",
    "url": "https://example.com/posts/1",
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
    "prefix_fields": ["title"],
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
| `prefix_fields` | `["title"]` | Fields whose words also match by prefix (2–8 chars) while typing. Must be a subset of `indexed_fields`; `[]` disables |
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
```

### Search behavior

- **Multi-token queries are OR with hit-count ranking.** Any document matching at least one token is returned; documents matching more tokens rank higher, so all-token (AND) matches come first. Ties keep document input order. Each result exposes the matched-token count as `hits` (0~16; query tokens beyond the 16th are ignored).
- **The last query token also matches by prefix.** While typing, the last token (2–8 chars) matches words in `prefix_fields` (default: title) that start with it. Other fields still need exact word matches.
- **Choseong tokens work like regular tokens.** `ㅅㅈ` matches any document whose indexed text contains a word starting with those initial consonants.
- **No metadata sorting.** Results are ordered by matched-token count. For other orders (date, etc.), sort the returned array in JavaScript.
- **Stopwords are not searchable.** They are removed at index time and the list is not shipped in the bundle, so a query made up entirely of stopwords returns nothing.

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

## Documentation

- [How it works](https://github.com/taggon/chaza/blob/main/docs/how-it-works.md) — tokenization pipeline, choseong/prefix tokens, binary fuse filters, bundle format, size limits
- [SPEC](https://github.com/taggon/chaza/blob/main/SPEC.md) — full format and behavior specification

## Limitations

- **Input must be UTF-8 + NFC.** NFD (decomposed) Hangul will break choseong extraction.
- **No metadata sorting.** Results are fixed to matched-token-count order; sort the returned array in JavaScript for other orders.
- **Static index.** No incremental updates; rebuild from the corpus to add or remove documents.
- **False positives.** ~0.4% of queries may match a document that doesn't contain the token. There is no brute-force verification step.

## Acknowledgements

Inspired by [tinysearch](https://github.com/tinysearch/tinysearch).

## License

MIT
