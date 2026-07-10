/**
 * chaza — ESM loader for the browser.
 *
 * Distributed as a static file. Shared by all sites.
 *
 * The bundle file (chaza.bundle) is not a pure WASM module — it is a
 * [wasm][index][tail-meta 16 B] container. This loader reads the tail meta,
 * slices the WASM and index sections, instantiates the WASM, and injects
 * the index.
 *
 * Memory management:
 *   alloc(n) may grow wasm.memory.buffer, invalidating previous TypedArray views.
 *   Pattern: alloc -> copy index -> set_index. After set_index no grow occurs.
 *   Each search() call creates fresh DataView/Uint8Array views for reading results.
 */

// --- Constants ---

/** Magic number. LE-serialized bytes spell 'C','H','A','Z'. */
const MAGIC = 0x5a414843;
/** Bundle format version. */
const VERSION = 2;
/** Tail meta section size in bytes. */
const TAIL_META_SIZE = 16;
/** DocEntryPrefix: filter_off(4) + filter_len(4) + title_off(4) + title_len(4) + url_off(4) + url_len(4). */
const DOC_ENTRY_PREFIX_SIZE = 24;
/** MetaEntry: off(4) + len(4). */
const META_ENTRY_SIZE = 8;

const _decoder = new TextDecoder("utf-8");
const _encoder = new TextEncoder();

// --- Types ---

/** Parsed tail meta (last 16 bytes of the bundle). */
export interface TailMeta {
  magic: number;
  version: number;
  wasmLen: number;
  indexLen: number;
}

/** Parsed index header (first 32 bytes of the index section). */
export interface IndexHeader {
  magic: number;
  version: number;
  filterKind: number;
  hashK: number;
  tokenizerKind: number;
  numDocs: number;
  numMetaFields: number;
  metaNamesOff: number;
  docTableOff: number;
  stringPoolOff: number;
  filtersOff: number;
}

/** Raw document entry data read from the index. */
interface DocEntryData {
  title: string;
  url: string;
  metaValues: string[];
}

/** Options for search(). */
export interface SearchOptions {
  /** Max results to return. 0 = default (20). */
  maxResults?: number;
}

/** A single search result. */
export interface SearchResult {
  title: string;
  url: string;
  meta: Record<string, string>;
  /**
   * Number of query tokens that matched this document (ranking key).
   * Range 0~16: at most 16 query tokens are considered per search;
   * tokens beyond that are ignored.
   */
  hits: number;
}

/** WASM export signatures. */
interface WasmExports {
  alloc(n: number): number;
  set_index(ptr: number, len: number): void;
  search(
    queryPtr: number,
    queryLen: number,
    maxResults: number,
  ): number;
  memory: WebAssembly.Memory;
}

/** Type guard for WASM exports. */
function asWasmExports(
  exports: WebAssembly.Exports,
): WasmExports {
  const e = exports as Record<string, unknown>;
  if (typeof e.alloc !== "function") {
    throw new Error("chaza: wasm export 'alloc' not found");
  }
  if (typeof e.set_index !== "function") {
    throw new Error("chaza: wasm export 'set_index' not found");
  }
  if (typeof e.search !== "function") {
    throw new Error("chaza: wasm export 'search' not found");
  }
  if (!(e.memory instanceof WebAssembly.Memory)) {
    throw new Error("chaza: wasm export 'memory' not found");
  }
  return e as unknown as WasmExports;
}

// --- Internal helpers ---

/**
 * Read a little-endian u32 from bytes at the given offset.
 */
export function readU32LE(
  bytes: Uint8Array | ArrayBuffer,
  offset: number,
): number {
  const dv =
    bytes instanceof DataView
      ? bytes
      : bytes instanceof ArrayBuffer
        ? new DataView(bytes)
        : new DataView(
          (bytes as Uint8Array).buffer,
          (bytes as Uint8Array).byteOffset,
          (bytes as Uint8Array).byteLength,
        );
  return dv.getUint32(offset, true);
}

/**
 * Parse the tail meta from the last 16 bytes of the bundle.
 * @throws if magic, version, or length validation fails.
 */
export function parseTailMeta(bundleBytes: Uint8Array): TailMeta {
  if (bundleBytes.length < TAIL_META_SIZE) {
    throw new Error(
      `chaza: bundle too short (${bundleBytes.length} < ${TAIL_META_SIZE})`,
    );
  }
  const tailStart = bundleBytes.length - TAIL_META_SIZE;
  const dv = new DataView(
    bundleBytes.buffer,
    bundleBytes.byteOffset + tailStart,
    TAIL_META_SIZE,
  );

  const magic = dv.getUint32(0, true);
  if (magic !== MAGIC) {
    throw new Error(
      `chaza: invalid tail magic 0x${magic.toString(16)} (expected 0x${MAGIC.toString(16)})`,
    );
  }

  const version = dv.getUint8(4);
  if (version !== VERSION) {
    throw new Error(
      `chaza: unsupported tail version ${version} (expected ${VERSION})`,
    );
  }

  const wasmLen = dv.getUint32(8, true);
  const indexLen = dv.getUint32(12, true);

  // Verify wasm + index length matches bundle body (allow up to 3 bytes padding
  // for 4-byte alignment added by the Zig assembler).
  const expectedBody = bundleBytes.length - TAIL_META_SIZE;
  const dataEnd = wasmLen + indexLen;
  if (dataEnd > expectedBody || expectedBody - dataEnd > 3) {
    throw new Error(
      `chaza: tail meta length mismatch (wasm=${wasmLen} + index=${indexLen} = ${dataEnd}, but body is ${expectedBody})`,
    );
  }

  return { magic, version, wasmLen, indexLen };
}

/**
 * Parse the index header (32 bytes at the start of the index section).
 */
function parseHeader(dv: DataView): IndexHeader {
  const magic = dv.getUint32(0, true);
  if (magic !== MAGIC) {
    throw new Error(
      `chaza: invalid index magic 0x${magic.toString(16)} (expected 0x${MAGIC.toString(16)})`,
    );
  }
  const version = dv.getUint8(4);
  if (version !== VERSION) {
    throw new Error(
      `chaza: unsupported index version ${version} (expected ${VERSION})`,
    );
  }
  return {
    magic,
    version,
    filterKind: dv.getUint8(5),
    hashK: dv.getUint8(6),
    tokenizerKind: dv.getUint8(7),
    numDocs: dv.getUint32(8, true),
    numMetaFields: dv.getUint32(12, true),
    metaNamesOff: dv.getUint32(16, true),
    docTableOff: dv.getUint32(20, true),
    stringPoolOff: dv.getUint32(24, true),
    filtersOff: dv.getUint32(28, true),
  };
}

/**
 * Parse NUL-terminated metadata field names from the meta-names region.
 */
export function parseMetaNames(
  indexBytes: Uint8Array,
  header: IndexHeader,
): string[] {
  const names: string[] = [];
  const { metaNamesOff: regionStart, docTableOff: regionEnd, numMetaFields: numMeta } = header;
  for (let i = regionStart, count = 0; i < regionEnd && count < numMeta; i++, count++) {
    const start = i;
    while (i < regionEnd && indexBytes[i] !== 0) i++;
    names.push(_decoder.decode(indexBytes.subarray(start, i)));
  }
  return names;
}

/**
 * Read a document entry (title, url, meta values) by doc_id from the index.
 * Returns null if doc_id is out of range.
 */
export function getDocEntry(
  dv: DataView,
  memBytes: Uint8Array,
  header: IndexHeader,
  stringPoolBase: number,
  docId: number,
): DocEntryData | null {
  if (docId >= header.numDocs) return null;

  const stride = DOC_ENTRY_PREFIX_SIZE + META_ENTRY_SIZE * header.numMetaFields;
  const docOff = header.docTableOff + docId * stride;

  // DocEntryPrefix
  const titleOff = dv.getUint32(docOff + 8, true);
  const titleLen = dv.getUint32(docOff + 12, true);
  const urlOff = dv.getUint32(docOff + 16, true);
  const urlLen = dv.getUint32(docOff + 20, true);

  // MetaEntry[num_meta_fields]
  const metaValues: string[] = [];
  const metaStart = docOff + DOC_ENTRY_PREFIX_SIZE;
  for (let j = 0; j < header.numMetaFields; j++) {
    const mOff = dv.getUint32(metaStart + j * META_ENTRY_SIZE, true);
    const mLen = dv.getUint32(metaStart + j * META_ENTRY_SIZE + 4, true);
    const absOff = stringPoolBase + mOff;
    metaValues.push(
      _decoder.decode(memBytes.subarray(absOff, absOff + mLen)),
    );
  }

  const titleAbs = stringPoolBase + titleOff;
  const urlAbs = stringPoolBase + urlOff;

  return {
    title: _decoder.decode(memBytes.subarray(titleAbs, titleAbs + titleLen)),
    url: _decoder.decode(memBytes.subarray(urlAbs, urlAbs + urlLen)),
    metaValues,
  };
}

/**
 * Extract a UTF-8 string from a string pool slice.
 */
export function readStringAt(
  stringPool: Uint8Array,
  off: number,
  len: number,
): string {
  return _decoder.decode(stringPool.subarray(off, off + len));
}

// --- Chaza class ---

/**
 * chaza search engine instance.
 * Load a bundle with {@link Chaza.load}, then call {@link Chaza.search}.
 */
export class Chaza {
  private _exports!: WasmExports;
  private _memory!: WebAssembly.Memory;
  private _indexPtr!: number;
  private _header!: IndexHeader;
  private _metaNames!: string[];
  private _stringPoolBase!: number;

  /** Exposed for testing. */
  get _header_pub(): IndexHeader {
    return this._header;
  }
  get _metaNames_pub(): string[] {
    return this._metaNames;
  }

  /**
   * Load a chaza bundle and return a ready-to-search instance.
   *
   * @param input - Bundle URL (string/URL), Response, ArrayBuffer, or Uint8Array.
   * @returns A Chaza instance.
   */
  static async load(
    input: string | URL | Response | ArrayBuffer | Uint8Array,
  ): Promise<Chaza> {
    let bundleBytes: Uint8Array;

    if (input instanceof Uint8Array) {
      bundleBytes = input;
    } else if (input instanceof ArrayBuffer) {
      bundleBytes = new Uint8Array(input);
    } else if (
      typeof Response !== "undefined" &&
      input instanceof Response
    ) {
      const ab = await input.arrayBuffer();
      bundleBytes = new Uint8Array(ab);
    } else {
      // URL string or URL object — fetch
      const resp = await fetch(input as string | URL);
      if (!resp.ok) {
        throw new Error(
          `chaza: fetch failed (${resp.status} ${resp.statusText})`,
        );
      }
      const ab = await resp.arrayBuffer();
      bundleBytes = new Uint8Array(ab);
    }

    // Parse tail meta
    const { wasmLen, indexLen } = parseTailMeta(bundleBytes);

    // Split wasm / index
    const wasmBytes = bundleBytes.subarray(0, wasmLen);
    const indexBytes = bundleBytes.subarray(wasmLen, wasmLen + indexLen);

    // Instantiate wasm
    const result = (await WebAssembly.instantiate(wasmBytes)) as unknown as
      { module: WebAssembly.Module; instance: WebAssembly.Instance };
    const exports = asWasmExports(result.instance.exports);

    // Inject index into wasm memory
    // alloc may grow memory — create a fresh view afterwards
    const indexPtr = exports.alloc(indexLen);

    const indexView = new Uint8Array(
      exports.memory.buffer,
      indexPtr,
      indexLen,
    );
    indexView.set(indexBytes);

    // set_index — no further grows after this point
    exports.set_index(indexPtr, indexLen);

    // Cache header and meta names from the stable memory
    const mem = exports.memory;
    const dv = new DataView(mem.buffer, indexPtr);
    const indexRelBytes = new Uint8Array(mem.buffer, indexPtr);
    const header = parseHeader(dv);
    const metaNames = parseMetaNames(indexRelBytes, header);

    const chaza = new Chaza();
    chaza._exports = exports;
    chaza._memory = mem;
    chaza._indexPtr = indexPtr;
    chaza._header = header;
    chaza._metaNames = metaNames;
    chaza._stringPoolBase = indexPtr + header.stringPoolOff;
    return chaza;
  }

  /**
   * Execute a search query.
   *
   * Multi-token queries use OR semantics with hit-count ranking:
   * documents matching more tokens rank higher (all-token matches first),
   * ties keep document input order. Each result carries `hits`, the number
   * of matched tokens (0~16 — only the first 16 query tokens are considered).
   *
   * The last query token (the word being typed) also matches as a word
   * prefix (2~8 chars) against fields indexed with prefix support
   * (prefix_fields, default: title).
   *
   * @param query - Search query string (UTF-8).
   * @param opts - Search options.
   * @returns Array of matching results, best matches first.
   */
  search(query: string, opts: SearchOptions = {}): SearchResult[] {
    const maxResults = opts.maxResults ?? 0;

    const exports = this._exports;

    // Write query UTF-8 bytes into wasm memory
    const queryBytes = _encoder.encode(query);
    const qPtr = exports.alloc(queryBytes.length);

    // alloc may have grown memory — fresh view
    const qView = new Uint8Array(
      this._memory.buffer,
      qPtr,
      queryBytes.length,
    );
    qView.set(queryBytes);

    // Call search
    const resultPtr = exports.search(qPtr, queryBytes.length, maxResults);

    // Read results — fresh views (alloc may have grown memory)
    const indexDv = new DataView(this._memory.buffer, this._indexPtr);
    const memBytes = new Uint8Array(this._memory.buffer);
    const resultDv = new DataView(this._memory.buffer);

    // Result buffer: [u32 count][(u32 doc_id, u32 hits) × count], little-endian
    const count = resultDv.getUint32(resultPtr, true);
    const results: SearchResult[] = [];
    for (let i = 0; i < count; i++) {
      const docId = resultDv.getUint32(resultPtr + 4 + i * 8, true);
      const hits = resultDv.getUint32(resultPtr + 8 + i * 8, true);
      const entry = getDocEntry(
        indexDv,
        memBytes,
        this._header,
        this._stringPoolBase,
        docId,
      );
      if (entry === null) continue;

      // Build meta object: { field_name: value }
      const meta: Record<string, string> = {};
      for (let j = 0; j < this._metaNames.length; j++) {
        meta[this._metaNames[j]] = entry.metaValues[j] ?? "";
      }

      results.push({
        title: entry.title,
        url: entry.url,
        meta,
        hits,
      });
    }

    return results;
  }
}
