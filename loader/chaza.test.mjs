/**
 * chaza.js 로더 단위 테스트 (Node.js test runner)
 *
 * 실행: node --test loader/chaza.test.mjs
 *
 * 테스트 전략:
 *   parseTailMeta, readU32LE, getDocEntry, parseMetaNames 등 순수 함수는
 *   핸드코딩 인덱스 바이트로 직접 검증.
 *   Chaza.search end-to-end는 가짜 wasm exports 객체로 stub 검증.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  Chaza,
  parseTailMeta,
  readU32LE,
  getDocEntry,
  readStringAt,
  parseMetaNames,
} from "./chaza.js";

const MAGIC = 0x5a414843;

// ── 바이트 빌드 헬퍼 ──

/** DataView에 u32 LE 쓰기 */
function writeU32LE(dv, offset, val) {
  dv.setUint32(offset, val, true);
}

/**
 * TailMeta 16바이트 생성.
 */
function buildTailMeta(wasmLen, indexLen, opts = {}) {
  const buf = new ArrayBuffer(16);
  const dv = new DataView(buf);
  writeU32LE(dv, 0, opts.magic ?? MAGIC);
  dv.setUint8(4, opts.version ?? 1);
  dv.setUint8(5, 0); // reserved
  dv.setUint8(6, 0);
  dv.setUint8(7, 0);
  writeU32LE(dv, 8, wasmLen);
  writeU32LE(dv, 12, indexLen);
  return new Uint8Array(buf);
}

/**
 * 헤더 32바이트 + 메타이름 + DocEntry 1개 + string_pool + filter로 구성된
 * 최소 인덱스 바이트를 빌드. SPEC v1.1 포맷 준수.
 *
 * layout:
 *   [0..32)    Header
 *   [32..40)   meta_names: "date\0" + 3B 패딩
 *   [40..72)   doc_table: DocEntryPrefix(24) + MetaEntry(8)
 *   [72..88)   string_pool: "Hi"(2)+"/a"(2)+"2026-01-01"(10) = 14 → align4 → 16
 *   [88..96)   filters: 8 bytes
 *
 * @returns {Uint8Array} 96바이트 인덱스
 */
function buildTinyIndex() {
  const total = 96;
  const buf = new ArrayBuffer(total);
  const dv = new DataView(buf);
  const u8 = new Uint8Array(buf);

  const NAMES_OFF = 32;
  const DOC_OFF = 40;
  const POOL_OFF = 72;
  const FILT_OFF = 88;

  // Header
  writeU32LE(dv, 0, MAGIC);
  dv.setUint8(4, 1); // version
  dv.setUint8(5, 0); // filter_kind = bloom
  dv.setUint8(6, 4); // hash_k
  dv.setUint8(7, 0); // tokenizer_kind = default
  writeU32LE(dv, 8, 1); // num_docs
  writeU32LE(dv, 12, 1); // num_meta_fields
  writeU32LE(dv, 16, NAMES_OFF);
  writeU32LE(dv, 20, DOC_OFF);
  writeU32LE(dv, 24, POOL_OFF);
  writeU32LE(dv, 28, FILT_OFF);

  // meta_names: "date\0" + 3B pad
  const nameStr = "date";
  for (let i = 0; i < nameStr.length; i++) u8[NAMES_OFF + i] = nameStr.charCodeAt(i);
  u8[NAMES_OFF + 4] = 0;

  // DocEntryPrefix @ DOC_OFF
  writeU32LE(dv, DOC_OFF + 0, 0); // filter_off
  writeU32LE(dv, DOC_OFF + 4, 8); // filter_len
  writeU32LE(dv, DOC_OFF + 8, 0); // title_off (pool 기준)
  writeU32LE(dv, DOC_OFF + 12, 2); // title_len = "Hi"
  writeU32LE(dv, DOC_OFF + 16, 2); // url_off (pool 기준)
  writeU32LE(dv, DOC_OFF + 20, 2); // url_len = "/a"

  // MetaEntry @ DOC_OFF + 24
  writeU32LE(dv, DOC_OFF + 24, 4); // off (pool 기준) → "2026-01-01"
  writeU32LE(dv, DOC_OFF + 28, 10); // len

  // string_pool @ POOL_OFF: "Hi" + "/a" + "2026-01-01"
  const title = "Hi";
  const url = "/a";
  const meta = "2026-01-01";
  let sp = POOL_OFF;
  for (const c of title) u8[sp++] = c.charCodeAt(0);
  for (const c of url) u8[sp++] = c.charCodeAt(0);
  for (const c of meta) u8[sp++] = c.charCodeAt(0);

  // filters @ FILT_OFF
  const filterBits = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x11, 0x22];
  for (let i = 0; i < filterBits.length; i++) u8[FILT_OFF + i] = filterBits[i];

  return u8;
}

// ── Tests ──

describe("readU32LE", () => {
  test("올바른 리틀엔디안 u32 읽기", () => {
    const buf = new ArrayBuffer(8);
    const dv = new DataView(buf);
    dv.setUint32(0, 0x01020304, true); // LE → 04 03 02 01
    dv.setUint32(4, 0x5a414843, true); // CHAZ magic
    const u8 = new Uint8Array(buf);

    assert.equal(readU32LE(u8, 0), 0x01020304);
    assert.equal(readU32LE(u8, 4), 0x5a414843);
  });

  test("0 값 읽기", () => {
    const u8 = new Uint8Array(4);
    assert.equal(readU32LE(u8, 0), 0);
  });

  test("최대값 읽기 (0xFFFFFFFF)", () => {
    const buf = new ArrayBuffer(4);
    new DataView(buf).setUint32(0, 0xffffffff, true);
    assert.equal(readU32LE(new Uint8Array(buf), 0), 0xffffffff);
  });
});

describe("parseTailMeta", () => {
  test("정상 TailMeta 파싱", () => {
    // 가짜 wasm(3B) + 가짜 index(5B) + tailMeta(16B)
    const wasm = [0x00, 0x61, 0x73]; // '\0as'
    const index = [0x01, 0x02, 0x03, 0x04, 0x05];
    const tail = buildTailMeta(wasm.length, index.length);
    const bundle = new Uint8Array([...wasm, ...index, ...tail]);

    const meta = parseTailMeta(bundle);
    assert.equal(meta.magic, MAGIC);
    assert.equal(meta.version, 1);
    assert.equal(meta.wasmLen, 3);
    assert.equal(meta.indexLen, 5);
  });

  test("잘못된 magic → throw", () => {
    const tail = buildTailMeta(0, 0, { magic: 0xdeadbeef });
    const bundle = new Uint8Array(24); // dummy body + tail
    bundle.set(tail, 8);
    assert.throws(() => parseTailMeta(bundle), /invalid tail magic/i);
  });

  test("지원하지 않는 버전 → throw", () => {
    const tail = buildTailMeta(0, 0, { version: 99 });
    const bundle = new Uint8Array(24);
    bundle.set(tail, 8);
    assert.throws(() => parseTailMeta(bundle), /unsupported tail version/i);
  });

  test("너무 짧은 번들 → throw", () => {
    const short = new Uint8Array(8); // < 16
    assert.throws(() => parseTailMeta(short), /bundle too short/i);
  });

  test("wasm_len + index_len이 본체와 불일치 → throw", () => {
    // body 10바이트지만 tail은 wasm=3, index=3 → 합 6 ≠ 10
    const tail = buildTailMeta(3, 3);
    const bundle = new Uint8Array(26); // 10 body + 16 tail
    bundle.set(tail, 10);
    assert.throws(() => parseTailMeta(bundle), /length mismatch/i);
  });
});

describe("parseMetaNames", () => {
  test("단일 메타 이름 파싱", () => {
    const idx = buildTinyIndex();
    const header = {
      numMetaFields: 1,
      metaNamesOff: 32,
      docTableOff: 40,
    };
    const names = parseMetaNames(idx, header);
    assert.deepEqual(names, ["date"]);
  });

  test("다중 메타 이름 파싱", () => {
    // "author\0date\0" → align 12바이트, metaNamesOff=32, docTableOff=44
    const buf = new ArrayBuffer(48);
    const u8 = new Uint8Array(buf);
    const str = "author\0date\0";
    for (let i = 0; i < str.length; i++) u8[32 + i] = str.charCodeAt(i);

    const header = {
      numMetaFields: 2,
      metaNamesOff: 32,
      docTableOff: 44,
    };
    const names = parseMetaNames(u8, header);
    assert.deepEqual(names, ["author", "date"]);
  });

  test("메타 0개 → 빈 배열", () => {
    const idx = buildTinyIndex();
    const header = {
      numMetaFields: 0,
      metaNamesOff: 32,
      docTableOff: 40,
    };
    const names = parseMetaNames(idx, header);
    assert.deepEqual(names, []);
  });
});

describe("readStringAt", () => {
  test("UTF-8 문자열 추출", () => {
    const pool = new Uint8Array(Array.from("Hello").map(c => c.charCodeAt(0)));
    assert.equal(readStringAt(pool, 0, 5), "Hello");
  });

  test("부분 슬라이스 추출", () => {
    const pool = new Uint8Array(Array.from("Hello World").map(c => c.charCodeAt(0)));
    assert.equal(readStringAt(pool, 6, 5), "World");
  });

  test("한글 UTF-8 추출", () => {
    const encoder = new TextEncoder();
    const pool = encoder.encode("한글");
    assert.equal(readStringAt(pool, 0, pool.length), "한글");
  });

  test("빈 문자열", () => {
    const pool = new Uint8Array(4);
    assert.equal(readStringAt(pool, 0, 0), "");
  });
});

describe("getDocEntry", () => {
  test("단일 문서 DocEntry에서 title/url/meta 추출", () => {
    const idx = buildTinyIndex();
    const dv = new DataView(idx.buffer);
    const header = {
      numDocs: 1,
      numMetaFields: 1,
      docTableOff: 40,
      stringPoolOff: 72,
    };
    const stringPoolBase = 72;

    const entry = getDocEntry(dv, idx, header, stringPoolBase, 0);
    assert.equal(entry.title, "Hi");
    assert.equal(entry.url, "/a");
    assert.deepEqual(entry.metaValues, ["2026-01-01"]);
  });

  test("범위 초과 doc_id → null", () => {
    const idx = buildTinyIndex();
    const dv = new DataView(idx.buffer);
    const header = {
      numDocs: 1,
      numMetaFields: 1,
      docTableOff: 40,
      stringPoolOff: 72,
    };
    assert.equal(getDocEntry(dv, idx, header, 72, 1), null);
    assert.equal(getDocEntry(dv, idx, header, 72, 999), null);
  });

  test("메타 0개인 문서", () => {
    // num_meta_fields=0인 인덱스 빌드
    // const total = 72; // header(32) + names(8 padded "x\0") + docEntryPrefix(24) + pool(8 padded)
    // 실제로는: header32 + names_align4 + docPrefix24 + pool_align4 + filter8
    // 간단히: header(32) + "x\0"→align4(4) + docPrefix(24) + "T"→1+url"u"→1 = 2→align4(4) + filter(4)
    // = 32+4+24+4+4 = 68
    const buf = new ArrayBuffer(68);
    const dv = new DataView(buf);
    const u8 = new Uint8Array(buf);

    const NAMES_OFF = 32;
    const DOC_OFF = 36;
    const POOL_OFF = 60;
    const FILT_OFF = 64;

    writeU32LE(dv, 0, MAGIC);
    dv.setUint8(4, 1); // version
    writeU32LE(dv, 8, 1); // num_docs
    writeU32LE(dv, 12, 0); // num_meta_fields = 0
    writeU32LE(dv, 16, NAMES_OFF);
    writeU32LE(dv, 20, DOC_OFF);
    writeU32LE(dv, 24, POOL_OFF);
    writeU32LE(dv, 28, FILT_OFF);

    u8[NAMES_OFF] = 0x78; // 'x'
    u8[NAMES_OFF + 1] = 0; // NUL

    // DocEntryPrefix: title_off=0, len=1; url_off=1, len=1
    writeU32LE(dv, DOC_OFF + 8, 0);
    writeU32LE(dv, DOC_OFF + 12, 1);
    writeU32LE(dv, DOC_OFF + 16, 1);
    writeU32LE(dv, DOC_OFF + 20, 1);

    u8[POOL_OFF] = 0x54; // 'T'
    u8[POOL_OFF + 1] = 0x75; // 'u'

    const header = {
      numDocs: 1,
      numMetaFields: 0,
      docTableOff: DOC_OFF,
      stringPoolOff: POOL_OFF,
    };

    const entry = getDocEntry(dv, u8, header, POOL_OFF, 0);
    assert.equal(entry.title, "T");
    assert.equal(entry.url, "u");
    assert.deepEqual(entry.metaValues, []);
  });
});

// ── Chaza.search end-to-end (stub wasm) ──

describe("Chaza.search (stub wasm)", () => {
  /**
   * 가짜 wasm instance를 만들어 Chaza.load 로직을 우회하고
   * search 메서드의 결과 객체 조립을 검증.
   *
   * memory buffer에 핸드코딩 인덱스를 직접 배치.
   */
  function buildChazaWithStubIndex() {
    const idx = buildTinyIndex();
    // wasm memory는 최소 1 page(64KB) — 인덱스 96B를 0번지에 배치
    const memory = new WebAssembly.Memory({ initial: 1 });
    const memView = new Uint8Array(memory.buffer);
    memView.set(idx, 0);

    const dv = new DataView(memory.buffer);
    const header = {
      magic: MAGIC,
      version: 1,
      filterKind: 0,
      hashK: 4,
      tokenizerKind: 0,
      numDocs: 1,
      numMetaFields: 1,
      metaNamesOff: 32,
      docTableOff: 40,
      stringPoolOff: 72,
      filtersOff: 88,
    };
    const metaNames = ["date"];

    // search가 doc_id 0을 반환하도록 결과 버퍼를 memory 끝에 배치
    const resultPtr = 60000;
    dv.setUint32(resultPtr, 1, true); // count = 1
    dv.setUint32(resultPtr + 4, 0, true); // doc_id = 0

    const exports = {
      memory,
      alloc: (_n) => 50000, // dummy ptr
      set_index: (_ptr, _len) => { },
      search: (_qp, _ql, _max, _sort, _desc) => resultPtr,
    };

    const chaza = new Chaza();
    chaza._exports = exports;
    chaza._memory = memory;
    chaza._indexPtr = 0; // 인덱스가 0번지에 배치됨
    chaza._header = header;
    chaza._metaNames = metaNames;
    chaza._stringPoolBase = 0 + header.stringPoolOff;
    return chaza;
  }

  test("search → title/url/meta 객체 반환", () => {
    const chaza = buildChazaWithStubIndex();
    const results = chaza.search("dummy", {
      maxResults: 0,
      sortFieldIdx: -1,
      sortDesc: false,
    });

    assert.equal(results.length, 1);
    assert.equal(results[0].title, "Hi");
    assert.equal(results[0].url, "/a");
    assert.deepEqual(results[0].meta, { date: "2026-01-01" });
  });

  test("search 빈 결과 (count=0)", () => {
    const idx = buildTinyIndex();
    const memory = new WebAssembly.Memory({ initial: 1 });
    const memView = new Uint8Array(memory.buffer);
    memView.set(idx, 0);

    const dv = new DataView(memory.buffer);
    const header = {
      numDocs: 1,
      numMetaFields: 1,
      metaNamesOff: 32,
      docTableOff: 40,
      stringPoolOff: 72,
      filtersOff: 88,
    };

    const resultPtr = 60000;
    dv.setUint32(resultPtr, 0, true); // count = 0

    const exports = {
      memory,
      alloc: (_n) => 50000,
      set_index: () => { },
      search: () => resultPtr,
    };

    const chaza = new Chaza();
    chaza._exports = exports;
    chaza._memory = memory;
    chaza._indexPtr = 0;
    chaza._header = header;
    chaza._metaNames = ["date"];
    chaza._stringPoolBase = 0 + header.stringPoolOff;

    const results = chaza.search("nonexistent");
    assert.equal(results.length, 0);
  });

  test("search 기본 옵션 (opts 생략)", () => {
    const chaza = buildChazaWithStubIndex();
    const results = chaza.search("test");
    assert.equal(results.length, 1);
    assert.equal(results[0].title, "Hi");
  });
});

// ── Chaza.load 통합 (실제 wasm module 사용) ──

describe("Chaza.load 통합", () => {
  test("실제 wasm 모듈로 로드 + search end-to-end", async () => {
    // 최소 wasm 모듈: memory + alloc/set_index/search exports
    // search는 항상 count=0 결과 반환
    const wasmBytes = buildMinimalWasm();

    // 가짜 인덱스 (buildTinyIndex 96B)
    const indexBytes = buildTinyIndex();
    // tail meta
    const tail = buildTailMeta(wasmBytes.length, indexBytes.length);

    const bundle = new Uint8Array([...wasmBytes, ...indexBytes, ...tail]);

    const chaza = await Chaza.load(bundle);
    // search 실행 — stub wasm은 실제 검색을 안 하므로 에러 없이 동작하는지만 확인
    const results = chaza.search("hello");
    assert.ok(Array.isArray(results));
  });

  test("잘못된 magic 번들 → throw", async () => {
    const bad = new Uint8Array(32);
    assert.rejects(() => Chaza.load(bad), /invalid tail magic|bundle too short/i);
  });
});

/**
 * 최소 wasm 모듈 빌드 (바이트 어셈블리).
 *
 * exports: memory, alloc(n)→ptr, set_index(ptr,len), search(...)→ptr
 * alloc: 단순히 고정 오프셋(4096) 반환, 메모리는 충분히 큼.
 * set_index: no-op.
 * search: 결과 버퍼(count=0)를 4096에 쓰고 반환.
 *
 * WAT로 작성 후 수동 인코딩은 복잡하므로, Node의 WebAssembly.compile으로
 * 검증 가능한 미리 만들어진 바이트를 사용.
 */
function buildMinimalWasm() {
  // WAT 소스를 wasm 바이트로 컴파일할 수 없으므로,
  // WebAssembly.Module을 수동 어셈블하는 대신 미리 준비된 바이너리 사용.
  //
  // 이 wasm 모듈은:
  //   (module
  //     (memory (export "memory") 1)
  //     (func (export "alloc") (param i32) (result i32)
  //       i32.const 4096)
  //     (func (export "set_index") (param i32 i32))
  //     (func (export "search")
  //       (param i32 i32 i32 i32 i32) (result i32)
  //       ;; 결과 버퍼 4096에 count=0 기록
  //       i32.const 4096
  //       i32.const 0
  //       i32.store
  //       i32.const 4096)
  //   )
  //
  // 수동 wasm 바이트 인코딩:
  const wasm = [
    0x00, 0x61, 0x73, 0x6d, // magic \0asm
    0x01, 0x00, 0x00, 0x00, // version 1

    // Type section (1) — 3 types, content=20 bytes
    0x01, // section id
    0x14, // section size (20)
    0x03, // num types
    // type 0: (i32) -> (i32)  — alloc
    0x60, 0x01, 0x7f, 0x01, 0x7f,
    // type 1: (i32 i32) -> ()  — set_index
    0x60, 0x02, 0x7f, 0x7f, 0x00,
    // type 2: (i32 i32 i32 i32 i32) -> (i32)  — search
    0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x01, 0x7f,

    // Function section (3) — 3 funcs, content=4 bytes
    0x03, // section id
    0x04, // size (4)
    0x03, // num functions
    0x00, // alloc: type 0
    0x01, // set_index: type 1
    0x02, // search: type 2

    // Memory section (5) — 1 memory, content=3 bytes
    0x05, // section id
    0x03, // size (3)
    0x01, // num memories
    0x00, // limits: flags=0 (no max), initial=1
    0x01,

    // Export section (7) — 4 exports, content=39 bytes
    0x07, // section id
    0x27, // size (39)
    0x04, // num exports

    // "memory"
    0x06, 0x6d, 0x65, 0x6d, 0x6f, 0x72, 0x79,
    0x02, // export kind: memory
    0x00, // memory index 0

    // "alloc" (5 chars)
    0x05, 0x61, 0x6c, 0x6c, 0x6f, 0x63,
    0x00, // export kind: func
    0x00, // func index 0

    // "set_index"
    0x09, 0x73, 0x65, 0x74, 0x5f, 0x69, 0x6e, 0x64, 0x65, 0x78,
    0x00, // func
    0x01, // func index 1

    // "search"
    0x06, 0x73, 0x65, 0x61, 0x72, 0x63, 0x68,
    0x00, // func
    0x02, // func index 2

    // Code section (10) — 3 bodies, content=24 bytes
    0x0a, // section id
    0x18, // size (24)
    0x03, // num function bodies

    // alloc: i32.const 4096; end — body=5 bytes
    0x05, // body size (5)
    0x00, // num locals
    0x41, 0x80, 0x20, // i32.const 4096 (LEB128: 0x80 0x20 = 4096)
    0x0b, // end

    // set_index: (no-op, params discarded) — body=2 bytes
    0x02, // body size (2)
    0x00, // num locals
    0x0b, // end

    // search: i32.const 4096; i32.const 0; i32.store; i32.const 4096; end — body=13 bytes
    0x0d, // body size (13)
    0x00, // num locals
    0x41, 0x80, 0x20, // i32.const 4096
    0x41, 0x00,       // i32.const 0
    0x36, 0x02, 0x00, // i32.store align=2 offset=0
    0x41, 0x80, 0x20, // i32.const 4096
    0x0b, // end
  ];

  return new Uint8Array(wasm);
}
