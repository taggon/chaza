// 진단: 인덱스 헤더, bloom 크기 분포, FP율 측정, runtime 반환 doc_id 중복 확인.
import { readFileSync } from "node:fs";
import { Chaza, parseTailMeta, readU32LE } from "./test-out/chaza.js";

const bundle = readFileSync("./test-out/chaza.wasm");
const { wasmLen, indexLen } = parseTailMeta(new Uint8Array(bundle));
const indexBytes = new Uint8Array(bundle).subarray(wasmLen, wasmLen + indexLen);
const dv = new DataView(indexBytes.buffer, indexBytes.byteOffset);

// 헤더
console.log("== HEADER ==");
console.log("magic:", "0x" + dv.getUint32(0, true).toString(16));
console.log("filter_kind:", dv.getUint8(5));
console.log("hash_k (global):", dv.getUint8(6));
console.log("num_docs:", dv.getUint32(8, true));
console.log("num_meta_fields:", dv.getUint32(12, true));
console.log("offsets:", {
  meta: dv.getUint32(16, true),
  doc: dv.getUint32(20, true),
  pool: dv.getUint32(24, true),
  filt: dv.getUint32(28, true),
});

// 각 문서의 filter_len 분포
const numDocs = dv.getUint32(8, true);
const numMeta = dv.getUint32(12, true);
const docOff = dv.getUint32(20, true);
const filtOff = dv.getUint32(28, true);
const stride = 24 + 8 * numMeta;

const lens = [];
const bitsSetRatio = [];
for (let i = 0; i < numDocs; i++) {
  const off = docOff + i * stride;
  const filterOffRel = dv.getUint32(off + 0, true);
  const filterLen = dv.getUint32(off + 4, true);
  lens.push(filterLen);
  // 비트 중 1의 비율
  let ones = 0;
  for (let b = 0; b < filterLen; b++) {
    const byte = indexBytes[filtOff + filterOffRel + b];
    ones += (byte & 1) + ((byte >> 1) & 1) + ((byte >> 2) & 1) + ((byte >> 3) & 1) +
            ((byte >> 4) & 1) + ((byte >> 5) & 1) + ((byte >> 6) & 1) + ((byte >> 7) & 1);
  }
  bitsSetRatio.push(ones / (filterLen * 8));
}
lens.sort((a, b) => a - b);
bitsSetRatio.sort((a, b) => a - b);
console.log("\n== FILTER LEN DIST ==");
console.log("min", lens[0], "p50", lens[Math.floor(numDocs/2)], "max", lens[numDocs-1]);
console.log("avg", Math.round(lens.reduce((a,b)=>a+b,0)/numDocs));
console.log("\n== BIT SET RATIO (sorted) ==");
console.log("min", bitsSetRatio[0].toFixed(3), "p25", bitsSetRatio[Math.floor(numDocs*0.25)].toFixed(3));
console.log("p50", bitsSetRatio[Math.floor(numDocs/2)].toFixed(3), "p75", bitsSetRatio[Math.floor(numDocs*0.75)].toFixed(3));
console.log("p95", bitsSetRatio[Math.floor(numDocs*0.95)].toFixed(3), "max", bitsSetRatio[numDocs-1].toFixed(3));
console.log("#docs with >50% bits set:", bitsSetRatio.filter(r => r > 0.5).length);
console.log("#docs with >80% bits set:", bitsSetRatio.filter(r => r > 0.8).length);

// 실제 FP 측정: 존재하지 않는 토큰 10개로 쿼리, 평균 hit 수
const chaza = await Chaza.load(bundle);
console.log("\n== FP TEST (random nonsense tokens) ==");
let total = 0;
for (let i = 0; i < 10; i++) {
  const q = `zzz${i}xxx${i}qqq`;
  const r = chaza.search(q);
  total += r.length;
  console.log(`  "${q}": ${r.length} hits`);
}
console.log("avg FP hits:", total / 10, "/ 687 =", (total/10/numDocs*100).toFixed(2), "%");

// runtime이 반환한 doc_id 직접 확인
console.log("\n== RAW DOC_ID for 'php debug' ==");
const ex = chaza._exports;
const enc = new TextEncoder();
const q = enc.encode("php debug");
const qPtr = ex.alloc(q.length);
new Uint8Array(ex.memory.buffer, qPtr, q.length).set(q);
const rPtr = ex.search(qPtr, q.length, 0, -1, false);
const rdv = new DataView(ex.memory.buffer);
const cnt = rdv.getUint32(rPtr, true);
const ids = [];
for (let i = 0; i < cnt; i++) ids.push(rdv.getUint32(rPtr + 4 + i*4, true));
console.log("count:", cnt, "doc_ids:", ids);
console.log("unique:", new Set(ids).size);
