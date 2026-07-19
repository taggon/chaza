/**
 * chaza — ESM loader for the browser.
 *
 * Distributed as a static file. Shared by all sites.
 *
 * The chaza output (chaza.wasm) is a self-contained WASM module: the search
 * index is embedded as data segments, and the runtime self-initializes from
 * a metadata slot. This loader instantiates the module, reads the meta field
 * schema once, and delegates all search/index work to the wasm side.
 *
 * Result format (NUL-separated, wasm materializes all strings):
 *   [u32 count]
 *   per result:
 *     [u32 hits]
 *     title\0 url\0 meta_value_1\0 ... meta_value_N\0
 */

const _decoder = new TextDecoder("utf-8");
const _encoder = new TextEncoder();

// --- Types ---

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
  prepare_query(len: number): number;
  meta_fields(): number;
  search(queryLen: number, maxResults: number): number;
  memory: WebAssembly.Memory;
}

const REQUIRED_FUNCS = ["prepare_query", "meta_fields", "search"] as const;

/** Type guard for WASM exports. */
function asWasmExports(
  exports: WebAssembly.Exports,
): WasmExports {
  const e = exports as Record<string, unknown>;
  for (const name of REQUIRED_FUNCS) {
    if (typeof e[name] !== "function") {
      throw new Error(`chaza: wasm export '${name}' not found`);
    }
  }
  if (!(e.memory instanceof WebAssembly.Memory)) {
    throw new Error("chaza: wasm export 'memory' not found");
  }
  return e as unknown as WasmExports;
}

function eatString(dv: DataView, offset: number): { str: string; next: number } {
  let pos = offset;
  while (dv.getUint8(pos) !== 0) pos++;
  const str = _decoder.decode(new Uint8Array(dv.buffer, offset, pos - offset));
  return { str, next: pos + 1 };
}

// --- Chaza class ---

/**
 * chaza search engine instance.
 * Load a bundle with {@link Chaza.load}, then call {@link Chaza.search}.
 */
export class Chaza {
  private _exports!: WasmExports;
  private _metaNames!: string[];

  /** Number of documents in the loaded index. */
  get documentCount(): number {
    return this._documentCount;
  }
  private _documentCount = 0;

  /** Metadata field names declared in the index schema. */
  get metadataFields(): readonly string[] {
    return this._metaNames;
  }

  /** Underlying wasm memory (exposed for testing/diagnostics). */
  get wasmMemory(): WebAssembly.Memory {
    return this._exports.memory;
  }

  /**
   * Load a chaza .wasm file and return a ready-to-search instance.
   *
   * The index is embedded in the module as data segments, so instantiation
   * alone places it in wasm memory and the runtime self-initializes.
   * URL/Response inputs use WebAssembly.instantiateStreaming when the
   * Content-Type is application/wasm (compile while downloading), falling
   * back to a buffered instantiate otherwise.
   *
   * @param input - .wasm URL (string/URL), Response, ArrayBuffer, or Uint8Array.
   * @returns A Chaza instance.
   */
  static async load(
    input: string | URL | Response | ArrayBuffer | Uint8Array,
  ): Promise<Chaza> {
    let instance: WebAssembly.Instance;

    if (input instanceof Uint8Array || input instanceof ArrayBuffer) {
      const result = (await WebAssembly.instantiate(
        input as BufferSource,
      )) as WebAssembly.WebAssemblyInstantiatedSource;
      instance = result.instance;
    } else {
      // URL string, URL object, or Response — fetch + instantiate
      let resp: Response;
      if (typeof Response !== "undefined" && input instanceof Response) {
        resp = input;
      } else {
        resp = await fetch(input as string | URL);
        if (!resp.ok) {
          throw new Error(
            `chaza: fetch failed (${resp.status} ${resp.statusText})`,
          );
        }
      }

      const contentType = resp.headers.get("content-type")?.split(";")[0].trim();

      if (
        typeof WebAssembly.instantiateStreaming === "function" &&
        contentType === "application/wasm"
      ) {
        const result = await WebAssembly.instantiateStreaming(resp);
        instance = result.instance;
      } else {
        const bytes = await resp.arrayBuffer();
        const result = await WebAssembly.instantiate(bytes);
        instance = result.instance;
      }
    }

    const exports = asWasmExports(instance.exports);

    // Read index info once: [u32 num_docs][u32 num_meta][name1\0 name2\0 ...]
    const mem = exports.memory;
    const infoPtr = exports.meta_fields();
    const infoDv = new DataView(mem.buffer);
    const numDocs = infoDv.getUint32(infoPtr, true);
    const numMeta = infoDv.getUint32(infoPtr + 4, true);
    const metaNames: string[] = [];
    let off = infoPtr + 8;
    for (let i = 0; i < numMeta; i++) {
      const eaten = eatString(infoDv, off);
      metaNames.push(eaten.str);
      off = eaten.next;
    }

    const chaza = new Chaza();
    chaza._exports = exports;
    chaza._metaNames = metaNames;
    chaza._documentCount = numDocs;
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

    // Encode query into the runtime-owned query buffer
    const queryBytes = _encoder.encode(query);
    const qPtr = exports.prepare_query(queryBytes.length);
    const qView = new Uint8Array(
      exports.memory.buffer,
      qPtr,
      queryBytes.length,
    );
    qView.set(queryBytes);

    // Call search — wasm materializes all strings into the result buffer
    const resultPtr = exports.search(queryBytes.length, maxResults);

    // Parse result buffer: [u32 count][per result: u32 hits, title\0, url\0, meta\0 × N]
    const mem = exports.memory;
    const dv = new DataView(mem.buffer);
    const count = dv.getUint32(resultPtr, true);

    let off = resultPtr + 4;
    const results: SearchResult[] = [];
    for (let i = 0; i < count; i++) {
      const hits = dv.getUint32(off, true);
      off += 4;

      // Read NUL-terminated strings: title, url, meta values.
      const title = eatString(dv, off);
      off = title.next;
      const url = eatString(dv, off);
      off = url.next;

      const meta: Record<string, string> = {};
      for (const metaName of this._metaNames) {
        const v = eatString(dv, off);
        meta[metaName] = v.str;
        off = v.next;
      }

      results.push({ title: title.str, url: url.str, meta, hits });
    }

    return results;
  }
}
