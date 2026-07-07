import { test, describe, before } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { Chaza } from "../dist/chaza.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const bundle = readFileSync(path.join(__dirname, "fixtures", "chaza.bundle"));

let chaza;

before(async () => {
  chaza = await Chaza.load(bundle);
});

describe("e2e: load", () => {
  test("loads 50 documents with path metadata", () => {
    assert.equal(chaza._header_pub.numDocs, 50);
    assert.deepEqual(chaza._metaNames_pub, ["path"]);
  });
});

describe("e2e: single-token search", () => {
  test("대한민국 → 4 hits in document order", () => {
    const results = chaza.search("대한민국");
    assert.equal(results.length, 4);
    assert.deepEqual(
      results.map((r) => r.title),
      [
        "대한민국 민법 제157조",
        "천안백석중학교",
        "NewJeans 라이브 공연 목록",
        "김정주 (기업인)",
      ],
    );
  });

  test("민법 → 1 hit", () => {
    const results = chaza.search("민법");
    assert.equal(results.length, 1);
    assert.equal(results[0].title, "대한민국 민법 제157조");
  });

  test("올림픽 → 4 hits", () => {
    const results = chaza.search("올림픽");
    assert.equal(results.length, 4);
    assert.ok(results.some((r) => r.title.includes("사격")));
  });
});

describe("e2e: multi-token AND", () => {
  test("대한민국 민법 → 1 hit (intersection)", () => {
    const results = chaza.search("대한민국 민법");
    assert.equal(results.length, 1);
    assert.equal(results[0].title, "대한민국 민법 제157조");
  });

  test("올림픽 사격 → 1 hit", () => {
    const results = chaza.search("올림픽 사격");
    assert.equal(results.length, 1);
    assert.ok(results[0].title.includes("올림픽"));
  });
});

describe("e2e: choseong search", () => {
  test("ㄷㅎ → matches docs with ㄷ+ㅎ initial consonants", () => {
    const results = chaza.search("ㄷㅎ");
    assert.ok(results.length >= 5);
    assert.ok(results.some((r) => r.title === "대한민국 민법 제157조"));
  });

  test("ㅊㅅ → matches docs with ㅊ+ㅅ initial consonants", () => {
    const results = chaza.search("ㅊㅅ");
    assert.ok(results.length >= 3);
    assert.ok(results.some((r) => r.title === "청소년"));
  });
});

describe("e2e: empty results", () => {
  test("non-existent token → 0 hits", () => {
    const results = chaza.search("xyzqwert");
    assert.equal(results.length, 0);
  });
});

describe("e2e: sorting", () => {
  test("sort by path ascending", () => {
    const results = chaza.search("대한민국", {
      sortFieldIdx: 0,
      sortDesc: false,
    });
    assert.equal(results.length, 4);
    assert.deepEqual(
      results.map((r) => r.title),
      [
        "김정주 (기업인)",
        "대한민국 민법 제157조",
        "천안백석중학교",
        "NewJeans 라이브 공연 목록",
      ],
    );
  });

  test("sort by path descending", () => {
    const results = chaza.search("대한민국", {
      sortFieldIdx: 0,
      sortDesc: true,
    });
    assert.equal(results.length, 4);
    assert.deepEqual(
      results.map((r) => r.title),
      [
        "NewJeans 라이브 공연 목록",
        "천안백석중학교",
        "대한민국 민법 제157조",
        "김정주 (기업인)",
      ],
    );
  });
});

describe("e2e: maxResults", () => {
  test("maxResults: 2 limits to 2", () => {
    const results = chaza.search("대한민국", { maxResults: 2 });
    assert.equal(results.length, 2);
    assert.deepEqual(
      results.map((r) => r.title),
      ["대한민국 민법 제157조", "천안백석중학교"],
    );
  });

  test("maxResults: 0 → default 20", () => {
    const results = chaza.search("대한민국", { maxResults: 0 });
    assert.equal(results.length, 4);
  });
});

describe("e2e: result structure", () => {
  test("result has title, url, meta", () => {
    const results = chaza.search("민법");
    assert.equal(results.length, 1);
    const r = results[0];
    assert.equal(typeof r.title, "string");
    assert.equal(typeof r.url, "string");
    assert.ok(r.meta);
    assert.equal(typeof r.meta.path, "string");
  });
});
