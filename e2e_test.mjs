import { Chaza } from "./test-out/chaza.js";
import { readFileSync } from "node:fs";

const bundle = readFileSync("./test-out/chaza.wasm");
const chaza = await Chaza.load(bundle);

console.log(`loaded: numDocs=${chaza._header.numDocs}, metaNames=${chaza._metaNames}`);

function run(query, opts) {
  const results = chaza.search(query, opts);
  console.log(`\n[query="${query}" opts=${JSON.stringify(opts ?? {})}] → ${results.length} hits`);
  for (const r of results.slice(0, 5)) {
    console.log(`  - ${r.title}  meta=${JSON.stringify(r.meta)}`);
  }
}

// 1. 한글 단일 토큰
run("대한민국");
// 2. 영문 토큰
run("Olympic");
// 3. 초성 2글자
run("ㅎㅁ");
// 4. 초성 3글자
run("ㄷㅎㅁㄱ");
// 5. AND 멀티토큰 (한글)
run("대한민국 민법");
// 6. 빈 결과
run("zzzzz");
// 7. 정렬 — path 기준 asc/desc
run("대한민국", { sortFieldIdx: 0, sortDesc: false });
run("대한민국", { sortFieldIdx: 0, sortDesc: true });
// 8. maxResults
run("대한민국", { maxResults: 2 });
