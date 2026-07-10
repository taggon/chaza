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

  test("올림픽 → multiple hits including 사격 doc", () => {
    // >= 3, not an exact count: the exact tail can shift by one ~0.4%/doc
    // false positive whenever filter bytes change.
    const results = chaza.search("올림픽");
    assert.ok(results.length >= 3);
    assert.ok(results.some((r) => r.title.includes("사격")));
  });
});

describe("e2e: multi-token OR ranking", () => {
  test("대한민국 민법 → all-token match ranks first, partial matches follow", () => {
    const results = chaza.search("대한민국 민법");
    // Union of 대한민국 docs (4) and 민법 docs; both-token doc first.
    assert.ok(results.length >= 4);
    assert.equal(results[0].title, "대한민국 민법 제157조");
    assert.equal(results[0].hits, 2);
    assert.equal(results[1].hits, 1);
  });

  test("올림픽 사격 → both-token doc first", () => {
    const results = chaza.search("올림픽 사격");
    assert.ok(results.length >= 3);
    assert.ok(results[0].title.includes("올림픽"));
    assert.ok(results[0].title.includes("사격"));
    assert.equal(results[0].hits, 2);
  });

  test("unknown token doesn't kill partial matches", () => {
    // some() not exact count: a false positive on the fake token may add a doc
    const results = chaza.search("민법 xyzqwert");
    assert.ok(results.some((r) => r.title === "대한민국 민법 제157조"));
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

describe("e2e: prefix search (title words)", () => {
  test("newj → NewJeans title via prefix token", () => {
    // some() not exact count: with 50 docs a ~0.4%/doc false positive
    // occasionally adds an extra hit (inherent to the filter).
    const results = chaza.search("newj");
    assert.ok(results.some((r) => r.title === "NewJeans 라이브 공연 목록"));
  });

  test("대한 → title starting with 대한민국 matched by prefix", () => {
    const results = chaza.search("대한");
    assert.ok(results.some((r) => r.title === "대한민국 민법 제157조"));
  });
});

describe("e2e: empty results", () => {
  test("non-existent token → (almost) no hits", () => {
    // ~0.4%/doc false positives are inherent to the filter: with 50 docs a fake
    // token occasionally matches a stray doc. Assert the noise stays minimal.
    const results = chaza.search("xyzqwert");
    assert.ok(results.length <= 2);
    assert.ok(results.every((r) => r.hits === 1));
  });
});

describe("e2e: ranking order", () => {
  test("single-token ties keep document input order", () => {
    const results = chaza.search("대한민국");
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
  test("result has title, url, meta, hits", () => {
    const results = chaza.search("민법");
    assert.equal(results.length, 1);
    const r = results[0];
    assert.equal(typeof r.title, "string");
    assert.equal(typeof r.url, "string");
    assert.ok(r.meta);
    assert.equal(typeof r.meta.path, "string");
    assert.equal(r.hits, 1);
  });
});
