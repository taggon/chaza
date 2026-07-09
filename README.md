# Chaza

A minimal static-site search engine — Zig + WASM. Finds Korean text even when you type only initial consonants (choseong).

- **Small.** The index stores binary fuse filters, not document text. ~0.5 MB for a few hundred pages.
- **Korean choseong search.** Type ㄱㄴ and match 가나, 강남, 경남…
- **All query work in WASM.** JavaScript only passes strings and renders results.
- **No toolchain for end users.** The runtime WASM is embedded in the CLI binary. Building an index is just byte concatenation — no compiler needed.

## vs tinysearch

Chaza is inspired by [tinysearch](https://github.com/tinysearch/tinysearch) and reads the same corpus format. Same 100-document Wikipedia corpus (50 Korean + 50 English), Apple M1 Max, Node v22 — reproduce with [`bench/`](bench/):

| | chaza | tinysearch 0.10 | |
|---|---|---|---|
| Index build time | **4.7 ms** | 4.6 s¹ | ~1,000× faster |
| Search latency (Node, 2,000 queries) | **4.6 µs/query** | 316 µs/query | ~70× faster |
| Output size (raw) | 38 KB bundle + 12 KB loader | 142 KB wasm + 2 KB glue | ~3× smaller |
| Output size (gzip) | **14 KB** + 4 KB loader | 68 KB + 1 KB glue | ~4× smaller |
| Korean choseong search | ✅ | ❌ | |
| Single binary, no toolchain | ✅ | ❌ needs Rust + wasm toolchain² | |

¹ With a warm cargo cache — tinysearch generates and compiles a Rust crate on every index build. The first-ever build also compiles dependencies (minutes).
² `rustc`, `wasm32-unknown-unknown` target, and `binaryen` at index-build time. Chaza ships the pre-built runtime inside the CLI binary.

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

Each result contains `{ title, url, meta, hits }` — `hits` is the number of query tokens that matched (0~16).

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
    "url": "https://example.com/posts/1",
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

## Search behavior

- **Multi-token queries are OR with hit-count ranking** — documents matching more tokens come first; each result carries the count as `hits`.
- **The last query token also matches by prefix** (2–8 chars) against `prefix_fields` words — `progr` finds a title containing "Programming".
- **Choseong queries** like `ㅅㅈ` match documents with a word starting with those initial consonants.
- **`max_results`** defaults to 20: `chaza.search("hello", { maxResults: 10 })`. Results are ordered by `hits`; for other orders (date, etc.), sort the returned array in JavaScript.

## Limitations

- **Input must be UTF-8 + NFC.** NFD (decomposed) Hangul breaks choseong extraction.
- **False positives.** ~0.4% of lookups may match a document that doesn't contain the token — inherent to the filter. Practical corpus ceiling is a few thousand documents.
- **Static index.** No incremental updates; rebuild to add or remove documents.
- **Stopwords are not searchable.** A query made up entirely of stopwords returns nothing.

## Documentation

- [How it works](docs/how-it-works.md) — tokenization pipeline, choseong/prefix tokens, binary fuse filters, bundle format, size limits
- [SPEC.md](SPEC.md) — full format and behavior specification

## Acknowledgements

Inspired by [tinysearch](https://github.com/tinysearch/tinysearch).

## License

MIT
