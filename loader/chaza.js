/**
 * chaza — ESM JS loader (SPEC v1.1)
 *
 * 사이트에 배포되는 정적 파일. 모든 사이트 공통.
 *
 * 번들 파일 chaza.wasm은 순수 wasm이 아닌 [wasm][index][tail-meta 16B] 컨테이너.
 * 이 로더가 tail-meta로 앞부분을 잘라 wasm instantiate + 인덱스 주입.
 *
 * 메모리 관리 (SPEC 245행):
 *   alloc(n) 호출 후 wasm.memory.buffer가 grow될 수 있음. grow 후 이전 TypedArray 뷰가 무효화됨.
 *   패턴: alloc → 인덱스 복사 → set_index. set_index 이후엔 grow 없음.
 *   매 search 호출 시점에 fresh DataView/Uint8Array를 생성하여 결과를 읽음.
 */

const MAGIC = 0x5a414843; // LE 직렬화 시 파일 바이트 'C','H','A','Z'
const VERSION = 2;
const TAIL_META_SIZE = 16;
// const HEADER_SIZE = 32;
const DOC_ENTRY_PREFIX_SIZE = 24; // filter_off(4) + filter_len(4) + title_off(4) + title_len(4) + url_off(4) + url_len(4)
const META_ENTRY_SIZE = 8; // off(4) + len(4)

const _decoder = new TextDecoder("utf-8");
const _encoder = new TextEncoder();

// ── 내부 헬퍼 ──

/**
 * 리틀엔디안 u32 읽기.
 * @param {Uint8Array|ArrayBuffer} bytes
 * @param {number} offset
 * @returns {number}
 */
export function readU32LE(bytes, offset) {
  const dv =
    bytes instanceof DataView
      ? bytes
      : bytes instanceof ArrayBuffer
        ? new DataView(bytes)
        : new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return dv.getUint32(offset, true);
}

/**
 * 마지막 16바이트에서 TailMeta 파싱.
 * @param {Uint8Array} bundleBytes - 전체 번들 바이트
 * @returns {{magic:number, version:number, wasmLen:number, indexLen:number}}
 * @throws {Error} magic 불일치, 버전 미지원, 길이 부족.
 */
export function parseTailMeta(bundleBytes) {
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

  // wasm + index가 번들 본체와 일치하는지 검증 (최대 3바이트 패딩 허용 —
  // Zig bundle.assemble가 TailMeta 4바이트 정렬을 위해 index 뒤에 패딩 추가).
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
 * 인덱스 헤더(32B) 파싱.
 * @param {DataView} dv - 인덱스 시작점 기준 DataView
 * @typedef {ReturnType<typeof parseHeader>} Header
 */
function parseHeader(dv) {
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
 * Meta_names 구역에서 NUL 종료 문자열 배열 파싱.
 * @param {Uint8Array} indexBytes - 인덱스 전체 바이트 (wasm 메모리 내)
 * @param {Header} header - parseHeader 결과
 * @returns {string[]} 메타 필드 이름 배열
 */
export function parseMetaNames(indexBytes, header) {
  const names = [];
  const { metaNamesOff: regionStart, docTableOff: regionEnd, numMetaFields: numMeta } = header;
  for (let i = regionStart, count = 0; (i < regionEnd && count < numMeta); i++, count++) {
    const start = i;
    while (i < regionEnd && indexBytes[i] !== 0) i++;
    names.push(_decoder.decode(indexBytes.subarray(start, i)));
  }
  return names;
}

/**
 * 인덱스 헤더와 DataView로부터 doc_id의 DocEntry 읽기.
 *
 * DocEntryPrefix(24B) 뒤에 MetaEntry[num_meta_fields]가 옴.
 * 모든 off/len은 string_pool 기준.
 *
 * @param {DataView} dv - wasm memory 전체 DataView
 * @param {Uint8Array} memBytes - wasm memory 전체 Uint8Array (문자열 추출용)
 * @param {Header} header - parseHeader 결과
 * @param {number} stringPoolBase - string_pool의 wasm memory 내 절대 오프셋
 * @param {number} docId
 * @returns {{title:string, url:string, metaValues:string[]}|null}
 */
export function getDocEntry(dv, memBytes, header, stringPoolBase, docId) {
  if (docId >= header.numDocs) return null;

  const stride = DOC_ENTRY_PREFIX_SIZE + META_ENTRY_SIZE * header.numMetaFields;
  const docOff = header.docTableOff + docId * stride;

  // DocEntryPrefix
  const titleOff = dv.getUint32(docOff + 8, true);
  const titleLen = dv.getUint32(docOff + 12, true);
  const urlOff = dv.getUint32(docOff + 16, true);
  const urlLen = dv.getUint32(docOff + 20, true);

  // MetaEntry[num_meta_fields]
  const metaValues = [];
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
 * string_pool에서 UTF-8 문자열 추출.
 *
 * @param {Uint8Array} stringPool - string_pool 바이트 (독립 슬라이스)
 * @param {number} off - string_pool 기준 오프셋
 * @param {number} len - 바이트 길이
 * @returns {string}
 */
export function readStringAt(stringPool, off, len) {
  return _decoder.decode(stringPool.subarray(off, off + len));
}

// ── Chaza 클래스 ──

export class Chaza {
  /**
   * chaza.wasm 번들을 로드하여 Chaza 인스턴스 반환.
   *
   * @param {string|URL|Response|ArrayBuffer|Uint8Array} url - 번들 URL 또는 직접 바이트/Response
   * @returns {Promise<Chaza>}
   */
  static async load(url) {
    let bundleBytes;

    if (url instanceof Uint8Array) {
      bundleBytes = url;
    } else if (url instanceof ArrayBuffer) {
      bundleBytes = new Uint8Array(url);
    } else if (
      typeof Response !== "undefined" &&
      url instanceof Response
    ) {
      const ab = await url.arrayBuffer();
      bundleBytes = new Uint8Array(ab);
    } else {
      // URL string or URL object — fetch
      const resp = await fetch(url);
      if (!resp.ok) {
        throw new Error(`chaza: fetch failed (${resp.status} ${resp.statusText})`);
      }
      const ab = await resp.arrayBuffer();
      bundleBytes = new Uint8Array(ab);
    }

    // tail meta 파싱
    const { wasmLen, indexLen } = parseTailMeta(bundleBytes);

    // wasm / index 분리
    const wasmBytes = bundleBytes.subarray(0, wasmLen);
    const indexBytes = bundleBytes.subarray(wasmLen, wasmLen + indexLen);

    // wasm instantiate
    const { instance } = await WebAssembly.instantiate(wasmBytes);
    const exports = instance.exports;

    // exports 검증
    if (typeof exports.alloc !== "function") {
      throw new Error("chaza: wasm export 'alloc' not found");
    }
    if (typeof exports.set_index !== "function") {
      throw new Error("chaza: wasm export 'set_index' not found");
    }
    if (typeof exports.search !== "function") {
      throw new Error("chaza: wasm export 'search' not found");
    }

    // 인덱스를 wasm 메모리에 주입
    // alloc → grow 가능 → 이 시점에 fresh view 생성
    const indexPtr = exports.alloc(indexLen);
    const memAfterAlloc = instance.exports.memory;

    // alloc 직후의 뷰로 인덱스 복사
    const indexView = new Uint8Array(
      memAfterAlloc.buffer,
      indexPtr,
      indexLen,
    );
    indexView.set(indexBytes);

    // set_index 호출 — 이후 메모리 안정화 (grow 없음)
    exports.set_index(indexPtr, indexLen);

    // set_index 이후 메모리 안정화 상태에서 헤더/메타이름 캐싱
    // 인덱스 오프셋은 indexPtr 기준이므로 DataView를 indexPtr에서 시작
    const mem = instance.exports.memory;
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
    // string_pool 절대 오프셋 (wasm memory 내) — TextDecoder용
    chaza._stringPoolBase = indexPtr + header.stringPoolOff;
    return chaza;
  }

  /**
   * 검색 실행.
   *
   * @param {string} query - 검색어 (UTF-8)
   * @param {{maxResults?:number, sortFieldIdx?:number, sortDesc?:boolean}} [opts]
   *   - maxResults: 0 = 기본 20
   *   - sortFieldIdx: -1 = 정렬 안 함(입력 순), 그 외는 meta-names 인덱스
   *   - sortDesc: false = asc
   * @returns {{title:string, url:string, meta:{[name:string]:string}}[]}
   */
  search(query, opts = {}) {
    const maxResults = opts.maxResults ?? 0;
    const sortFieldIdx = opts.sortFieldIdx ?? -1;
    const sortDesc = opts.sortDesc ?? false;

    const exports = this._exports;

    // 쿼리 UTF-8 바이트를 wasm 메모리에 쓰기
    const queryBytes = _encoder.encode(query);
    const qPtr = exports.alloc(queryBytes.length);

    // alloc 후 메모리가 grow했을 수 있으므로 fresh view
    const qView = new Uint8Array(
      this._memory.buffer,
      qPtr,
      queryBytes.length,
    );
    qView.set(queryBytes);

    // search 호출
    const resultPtr = exports.search(
      qPtr,
      queryBytes.length,
      maxResults,
      sortFieldIdx,
      sortDesc,
    );

    // 결과 읽기 — fresh view (alloc 내부 grow 가능성 대응)
    // indexDv: indexPtr 기준 (DocEntry 오프셋용), memBytes: 전체 메모리 (문자열 디코딩용)
    const indexDv = new DataView(this._memory.buffer, this._indexPtr);
    const memBytes = new Uint8Array(this._memory.buffer);
    const resultDv = new DataView(this._memory.buffer);

    const count = resultDv.getUint32(resultPtr, true);
    const results = [];
    for (let i = 0; i < count; i++) {
      const docId = resultDv.getUint32(resultPtr + 4 + i * 4, true);
      const entry = getDocEntry(
        indexDv,
        memBytes,
        this._header,
        this._stringPoolBase,
        docId,
      );
      if (entry === null) continue;

      // meta 객체: { field_name: value }
      const meta = {};
      for (let j = 0; j < this._metaNames.length; j++) {
        meta[this._metaNames[j]] = entry.metaValues[j] ?? "";
      }

      results.push({
        title: entry.title,
        url: entry.url,
        meta,
      });
    }

    return results;
  }
}
