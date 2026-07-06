import { Chaza } from "./test-out/chaza.js";
import { readFileSync } from "node:fs";

const bundle = readFileSync("./test-out/chaza.wasm");
const chaza = await Chaza.load(bundle);

console.log(`loaded: numDocs=${chaza._header.numDocs}, metaNames=${chaza._metaNames}`);

function run(query, opts) {
  const results = chaza.search(query, opts);
  console.log(`\n[query="${query}" opts=${JSON.stringify(opts ?? {})}] → ${results.length} hits`);
  for (const r of results.slice(0, 5)) {
    console.log(`  - ${r.title} → ${r.url}  meta=${JSON.stringify(r.meta)}`);
  }
}

// 1. 한글 단일 토큰
run("소주");
// 2. 영문 + 한글 혼합
run("xdebug");
// 3. 초성 2글자
run("ㅅㅈ");
// 4. 초성 3글자
run("ㅅㅈㅇ");
// 5. AND 멀티토큰 (한글)
run("소주 화학");
// 6. AND 멀티토큰 (영문)
run("php debug");
// 7. 빈 결과
run("zzzzz");
// 8. 정렬 — title 기준 asc
run("소주", { sortFieldIdx: -1 });
run("소주", { sortFieldIdx: 0, sortDesc: false });
run("소주", { sortFieldIdx: 0, sortDesc: true });
// 9. maxResults
run("소주", { maxResults: 2 });
