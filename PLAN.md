# chaza 구현 계획 (SPEC v1.2 기준)

> SPEC.md v1.2를 구현하기 위한 작업 계획. 리스크가 큰 부분을 먼저 검증하는 SPEC의 권장 순서를 따르되, 모듈 경계를 미리 정해 두어 1~8단계 전체가 일관된 구조 안에서 진행되도록 한다.

## v1.2에서 바뀐 점 (v1.1 대비)

- **필터 기본을 binary fuse filter (BinaryFuse8)로 확정**. Bloom은 디버깅/폴백, xor는 대체 (`filter_kind`).
- **목표 오탐률**: 2% → **≈0.4%** (8비트 지문 고정).
- **구현 전략 — pure Zig 포팅 (SPEC 명시 전략에서 변경)**: SPEC v1.2는 "구성은 C `fastfilter` 재사용(`@cImport`), 조회만 Zig 포팅"을 명시하지만, 본 계획은 **구성·조회 모두 pure Zig**로 구현한다. 이유:
  - SPEC의 #1 리스크("C 구성 ↔ Zig 조회 비트 일치")를 **원천 제거** — 동일 Zig 코드로 해시 일관성 강제.
  - `@cImport`/`addTranslateC` 빌드 복잡성·외부 C 소스 의존 제거 → 크로스컴파일이 순수 Zig 경로로 단순화.
  - BinaryFuse8 구성 알고리즘은 ~120줄. 골든 테스트(삽입 키 전체 조회 → 전부 true)로 정확성 검증.
  - SPEC의 실질적 요구사항은 "binary fuse filter를 기본으로 사용"하는 것이며, C-vs-Zig는 구현 전략(요구사항 아님).
- **인덱스 포맷 version 1 → 2**: 필터 blob이 자기서술적(self-describing) 구조로 변경. DocEntry 자체는 24바이트 유지.
- 크기 추정: Bloom ~400KB/doc-set → BinaryFuse8 **~1.1KB/doc** (8비트 지문, ≈9.0 bits/entry).
- `hash_k` 필드는 Bloom 전용으로 잔존(BinaryFuse는 사용 안 함). Header 크기 32바이트 유지.

## v1.1에서 바뀐 점 (v1.0 대비) — 참고용

- **본문/원본 단어 풀 제거** → brute-force 검증 삭제. body는 색인만(토큰화해 필터에 넣고 버림). 검색 결과 판단은 필터 조회만으로 확정.
- **해시**: FNV-1a → **xxhash64** (`std.hash.XxHash64`).
- **DocEntry 구조 변경**: `words_off`/`words_len` 제거, `title_off`/`title_len`/`url_off`/`url_len` 명시적 필드로 승격.
- **search() 시그니처**: `max_results`, `sort_field_idx`, `sort_desc` 추가. 반환 `[*]const u8` (길이 접두 인코딩 — 아래 참조).
- **불용어**: adapter → **파일 기반** (`--stopwords <file.txt>`). 줄 단위, `#` 주석, 기본 리스트 없음.
- **필드별 색인/저장 분리**: title(둘 다), url(저장만), body(색인만), meta(저장만).
- **정렬**: 메타 필드 문자열 사전순, asc/desc, 값 없으면 맨 뒤, 정렬→자르기.
- 크기 추정 ~1.8 MB → **~0.5 MB**.

## 확정된 기술 결정

| 항목 | 결정 | 비고 |
| --- | --- | --- |
| 구현 범위 | SPEC 1~8단계 전체 | 한 계획 안에서 단계별 검증 게이트 |
| CLI 배포 | 네이티브 크로스컴파일 | `zig build -Dtarget=...` |
| **필터 (v1.2)** | **Binary Fuse Filter (BinaryFuse8)** — pure Zig 구현(구성+조회) | SPEC v1.2 기본. fastfilter `binaryfusefilter.h` C 참조 구현을 Zig로 포팅. ≈0.4% 오탐(8비트 지문). Bloom=폴백 |
| **토큰→키 해시** | xxhash64(`std.hash.XxHash64`)로 토큰→u64 키. 필터 내부 해시는 binary fuse 자체 murmur64 | 두 층이 독립. 키 생성만 생성기·런타임 공유 → 비트 일치 보장 |
| 해시 함수 (Bloom 폴백) | xxhash64 + double hashing | h1/h2를 64비트 해시의 상·하위 32비트에서 파생 |
| 설정 포맷 | `chaza.json` (std.json) | SPEC v1.1 |
| 초성 토큰 마커 | `0x01` | SPEC 113행 |
| 매직넘버 | `0x5A414843` (LE 직렬화 시 파일 바이트 'C','H','A','Z') | 꼬리 메타·인덱스 헤더 공통 |
| `search()` 반환 | `[*]const u8` — `[u32 count LE][u32 doc_id × count LE]` | 결과 버퍼 주소를 반환, 첫 4바이트가 개수 |
| `search()` 인자 | `(query_ptr, query_len, max_results: u32, sort_field_idx: i32, sort_desc: bool)` | SPEC 220-226행. `max_results=0` → 기본 20, `sort_field_idx=-1` → 정렬 안 함(입력 순) |
| 다중 토큰 검색 | **AND 고정** (모든 토큰이 있는 문서만) | SPEC 153행 |
| 랭킹 | **없음** | SPEC 157행 |
| 정렬 | 메타 필드 **문자열 사전순**만. asc/desc. 값 없으면 맨 뒤. 정렬→자르기 순 | SPEC 164-171행. 숫자/날짜 의미 정렬不支持 (ISO date/zero-padding으로 입력 측 해결) |
| 불용어 | 파일 기반(`--stopwords <file.txt>`), 줄 단위, `#` 주석, 단일 집합, **기본 리스트 없음** | SPEC 131-139행. 미지정 시 제거 단계 생략 |
| 언어 어댑터 (2계층) | 1계층: wasm 내장 알고리즘(`default`만) / 2계층: 빌드 전용 dynamic lib(dlopen 슬롯만) | SPEC v1.1이 명시하지 않은 확장이지만 호환적. 어댑터 없이 MVP 진행 |
| 토큰 분절 규칙 | Letter(L\*)/Mark(M\*)/Number(Nd) 만 토큰 문자 | 나머지(구두점·기호·이모지·공백·제어)는 분절자 |
| 스크립트 분할 | 동일 스크립트 그룹 연속 run = 1 토큰 | 그룹 = `Latin` / `Hangul` / `Han` / `Hiragana` / `Katakana` / `Number` / `Other`. 조합 마크(M)는 앞 글자 run에 흡수 |
| 인덱스 헤더 `_pad` | `tokenizer_kind`(u8)로 재정의(자체 확장) | 0=`default`, 1~255=예약. MVP는 0만 |
| NFC 정규화 | 입력 전제 (직접 정규화하지 않음) | SPEC 117행. NFD 입력 시 초성 추출이 깨짐 |
| 입력 인코딩 | UTF-8 전제 | SPEC 전체 |

## 필드별 색인/저장 기본값 (SPEC 92-104행)

| 필드 | 색인(토큰화→bloom) | 저장(string-pool) | 비고 |
|------|------|------|------|
| title | O | O | 검색되고 결과에 표시 |
| url | X | O | 검색 안 됨, 결과에 표시(이동용) |
| body | O | X | 검색됨, 결과엔 안 나옴. 토큰화 후 버림 |
| metadata_fields (임의) | X | O | 검색 안 됨, 결과에 표시. 값은 항상 문자열 |

`metadata_fields`는 사이트가 정의하는 임의 필드. 이름·개수 제약 없음. 값은 항상 문자열로 저장(숫자 입력도 문자열화).

## 모듈 구조

```
src/
  main.zig                 CLI 진입(Juicy Main: std.process.Init / std.Io)
  cli/
    args.zig               CLI 인자 파싱(-o/--config/--stopwords/--no-choseong/--fp-rate/-q)
  config.zig               chaza.json 스키마 + std.json 파싱
  pipeline/                ★ 생성기·런타임이 공유하는 핵심 모듈 (계약의 실체)
    tokenize.zig           default 토크나이저 (스크립트 분할 + 소문자화)
    script.zig             scriptGroupOf(cp): Latin/Hangul/Han/Hiragana/Katakana/Number/Other 매핑
    choseong.zig           초성 인덱스(0~18) 추출 + 접두 초성 토큰 생성(0x01 마커)
    stopwords.zig          불용어 파일 파서 (줄 단위, # 주석, 단일 집합) — 어댑터 아님
    hash.zig               xxhash64 → u64 키(key64) + Bloom double hashing 파생 (h1/h2)
    binary_fuse.zig        ★ BinaryFuse8 — 구성+조회+직렬화 (pure Zig, fastfilter 포팅)
    bloom.zig              Bloom filter — 폴백용 (필터 종류 확장 슬롯)
  index/
    format.zig             매직/버전/오프셋 상수 + extern struct(Header, DocEntry)
    writer.zig             생성기: 헤더·메타이름·문서테이블·문자열풀·필터 직렬화
    reader.zig             런타임: set_index 검증 + zero-parse 슬라이스 접근자
  bundle.zig               [wasm][인덱스][꼬리메타 16B] 조립 + 꼬리메타 writer/reader
  generator.zig            JSON → 토큰화 → bloom → index bytes → 번들
  runtime.zig              wasm 타겟: alloc / set_index / search exports
  tests/
    corpus.zig             고정 골든 코퍼스 + 기대값
    golden.zig             생성기/런타임 토큰화·해시 일치 검증
loader/                    ★ chaza.js 로더 소스 (사용자에게 배포되는 정적 파일)
  chaza.js                 ESM 소스: fetch → 꼬리 16B → wasm instantiate → alloc/set_index → search API
  build.mjs                (옵션) chaza.js 번들/최소화 스크립트
examples/                  샘플 corpus.json + chaza.json + 데모 HTML
```

`pipeline/`은 생성기(native)와 런타임(wasm32-freestanding) 양쪽에서 같이 import되므로, **이 디렉터리의 코드가 곧 토큰화/해시 계약 자체**다. SPEC 명세 대신 코드 공유로 강제.

`loader/chaza.js`는 모든 사이트 공통인 정적 ESM 로더. CLI가 `@embedFile`로 들고 있다가 `chaza build` 실행 시 `chaza.wasm`과 같은 디렉터리에 출력.

## 빌드 그래프 (build.zig 재구성)

1. **runtime wasm** — `wasm32-freestanding`, `ReleaseSmall`, `export` 심볼 노출. 산출물 `runtime.wasm`.
2. **loader JS** — `loader/chaza.js` 소스 (필요시 `loader/build.mjs`로 최소화).
3. **chaza CLI native exe** — 크로스컴파일 가능(`-Dtarget`). `runtime.wasm`과 `chaza.js` 양쪽을 `@embedFile`로 포함.

크로스컴파일은 `b.standardTargetOptions(.{})` 기본값으로 열어두면 `zig build -Dtarget=x86_64-linux-gnu` 식으로 동작. CI 매트릭스는 8단계에서 추가.

## 인덱스 바이너리 포맷 (SPEC v1.2, 193-203행)

```
[ Header ]
[ 메타 필드 이름 목록 ]   num_meta_fields 개의 NUL 종료 UTF-8 문자열
[ 문서 메타 테이블 ]       num_docs 개의 DocEntry (16 + 8*num_meta_fields 바이트씩)
[ 문자열 풀 ]             title / url / 메타 값 문자열 (본문·원본 단어 없음)
[ 필터 데이터 ]           각 문서의 필터 blob ([FuseBlobHeader][fingerprints] 또는 Bloom 비트 배열)
```

### Header (32바이트, extern struct) — v1.2: version=2, filter_kind 기본=binary_fuse
```
magic           u32 = 0x5A414843
version         u8  = 2
filter_kind     u8  = 0 (binary_fuse) / 1 (bloom) / 2 (xor)
hash_k          u8  (Bloom 전용 k; binary_fuse는 미사용, 0)
tokenizer_kind  u8  = 0 (default)
num_docs        u32
num_meta_fields u32  (사용자 metadata_fields 개수 — title/url 제외)
meta_names_off  u32
doc_table_off   u32
string_pool_off u32
filters_off     u32
```

### DocEntry (24바이트 고정 접두 + 가변 메타) — v1.1에서 변경 없음
```
DocEntryPrefix {
  filter_off  u32   // filters 구역 기준 (필터 blob 시작)
  filter_len  u32   // 필터 blob 전체 길이 (헤더 포함)
  title_off   u32   // string_pool 기준
  title_len   u32
  url_off     u32   // string_pool 기준
  url_len     u32
}
MetaEntry[num_meta_fields] {
  off u32  // string_pool 기준
  len u32
}
```

### 필터 blob — 자기서술적 (filter_kind에 따라 내부 구조 상이)

DocEntry의 `filter_off`/`filter_len`은 blob 시작/끝만 가리킴. blob 내부 구조는 `filter_kind`에 따라 결정. 이 설계 덕분에 DocEntry는 필터 종류와 무관하게 24바이트 고정.

#### BinaryFuse8 blob (기본)
```
FuseBlobHeader (28바이트, little-endian) {
  seed                 u64   // 구성 시 결정된 무작위 시드
  size                 u32   // 원본 키 개수
  segment_length       u32   // 세그먼트 길이 (2의 거듭제곱)
  segment_count        u32   // 세그먼트 개수
  segment_count_length u32   // segment_count * segment_length
  array_length         u32   // 지문 배열 길이
}
Fingerprints[array_length]  u8   // 8비트 지문
```
- `segment_length_mask = segment_length - 1` (역산 가능, 저장 생략)
- 조회: `murmur64(key + seed)` → 3개 위치 산출 → 지문 XOR == 0 이면 hit
- 크기: 약 `n * 1.125` 바이트 (≈9.0 bits/entry)

#### Bloom blob (폴백)
```
BloomBlobHeader (8바이트) {
  m  u32   // 비트 수
  k  u8    // 해시 개수
  _pad u8
}
Bits[m/8]  u8
```

### TailMeta (16바이트, 파일 맨 끝)
```
magic      u32
version    u8
_reserved  [3]u8
wasm_len   u32
index_len  u32
```

## 토큰화 파이프라인 (SPEC 107-119행)

생성기·런타임 양쪽에서 동일(Zig 코드 공유):

1. 소문자화 (ASCII A-Z → a-z)
2. 구두점·공백 분절 (Letter/Mark/Number만 토큰 문자)
3. 동일 스크립트 그룹 연속 run = 1 토큰. 그룹 전환 시 토큰 경계.
4. 불용어 제거 (`--stopwords` 파일 제공 시 — 줄 단위, `#` 주석, 단일 집합)
5. 문서별 고유 토큰 집합 확정
6. `choseong_search`면 각 단어의 초성 prefix 토큰(1~`choseong_max_len`글자)에 `0x01` 마커를 붙여 추가
7. (다시) 중복 제거

불용어 제거는 **초성 토큰 생성 전**에 수행. 입력은 UTF-8 + NFC 전제.

## 검색 파이프라인 (SPEC 149-171행)

1. JS가 쿼리 문자열을 wasm 메모리에 넣고 `search(query_ptr, query_len, max_results, sort_field_idx, sort_desc)` 호출
2. wasm이 쿼리를 토큰화 파이프라인과 **동일하게** 정규화
3. 각 토큰을 `key64`로 u64 키 변환 후 각 문서 필터에 조회 (binary_fuse: 3회 지문 XOR)
4. **모든 토큰이 hit인 문서**만 후보 (AND 고정)
5. 정렬 (`sort_field_idx >= 0`이면 해당 메타 필드 문자열 사전순, asc/desc, 값 없으면 맨 뒤)
6. `max_results`만큼 자르기 (0 → 20)
7. 결과를 `[u32 count][u32 doc_id × count]` 형태의 버퍼에 기록하고 포인터 반환

**brute-force 검증 없음**, **랭킹 없음**, **초성/일반 분기 없음** (마커 토큰이 일반 토큰처럼 조회됨).

## Binary Fuse Filter (BinaryFuse8) — SPEC v1.2 기본

### 알고리즘 (fastfilter `binaryfusefilter.h` 참조)

- **두 층의 해시**: ① 토큰 → xxhash64 → u64 키 (chaza 레벨). ② 키 → `murmur64(key+seed)` → 3개 위치 + 8비트 지문 (필터 내부).
- **구성(populate)**: 키 집합에서 peel 구조를 구축. 실패 시 시드 변경·재시도 (최대 100회). 약 24바이트/엔트리 임시 메모리.
- **조회(contain)**: 3개 위치의 지문 XOR == 계산된 지문이면 hit. 고정 3회 조회, 오탐 ≈ 1/256 (0.4%).
- **mulhi**: 64×64 곱셈의 상위 64비트. Zig에서 `@as(u128, a) * @as(u128, b) >> 64`로 구현.

### 파라미터 산출 (arity=3)

- `segment_length = 1 << floor(log(n) / log(3.33) + 2.25)`, 상한 262144, n≤1이면 4
- `size_factor = max(1.125, 0.875 + 0.25 * log(1000000)/log(n))`, n≤1이면 0
- `capacity = round(n * size_factor)`
- `segment_count`, `array_length` 산출 (fastfilter `binary_fuse8_allocate` 참조)

### 직렬화

필터 blob = `[FuseBlobHeader 28B][fingerprints array_length 바이트]` (위 포맷 참조).

### Bloom filter (폴백)

- 목표 오탐 1~2% (기본 0.02). `--fp-rate`로 m·k 산출.
- 비트 수 `m = ceil(-n*ln(p)/(ln2)^2)`, 최소 64, 8의 배수 올림
- 해시 개수 `k = round((m/n)*ln2)`, [1,8] 클램프
- double hashing: 64비트 xxhash → h1/h2. `h_i = (h1 + i*h2) mod m`. h2는 홀수 보정.

## 구현 단계 (SPEC v1.1 권장 순서 매핑)

각 단계는 명시적 검증 게이트를 통과해야 다음으로 넘어간다.

### 1단계 — 인덱스 포맷 코드화 ✅ (v1.2 갱신 필요: version=2, FilterKind)
- `src/index/format.zig`: 매직/버전/오프셋/extern struct 고정 (version 2, FilterKind 기본 binary_fuse).
- 단정 테스트: 크기·오프셋·정렬·리틀엔디안·매직.

### 2단계 — 생성기 index bytes 생성 + BinaryFuse8 포팅
- `pipeline/binary_fuse.zig`: BinaryFuse8 구성+조회+직렬화 (fastfilter C 참조 → pure Zig). **구성과 조회가 같은 Zig 해시 코드 공유 → 비트 일치 강제**.
- `pipeline/hash.zig`: `key64(data) u64` 추가 (xxhash64 → 토큰→u64 키).
- pipeline 하위 모듈 구현: `tokenize.zig`, `script.zig`, `bloom.zig`(폴백).
- `index/writer.zig`: 헤더·메타이름·문서테이블·문자열풀·필터 blob(FuseBlobHeader+지문) 직렬화.
- `index/reader.zig`: IndexView로 슬라이스 접근. 필터 blob 역직렬화 헤더 파싱.
- **검증**: writer가 만든 bytes를 reader로 왕복, 모든 필드 일치. BinaryFuse8: 삽입 키 전체 조회 → 전부 true, 미삽입 → 오탐률 측정.

### 3단계 — Zig 런타임 in-memory 조회 검증 (번들·JS 없이)
- `runtime.zig`: `alloc`, `set_index`, `search` export.
- native 테스트에서 생성기 코드로 **메모리상** index bytes를 만들어 `set_index`에 직접 전달.
- `search()` 가 쿼리에 대해 올바른 doc_id 목록(`[u32 count][u32 doc_id × count]`)을 반환하는지 검증.
- wasm32 빌드가 되는 것만 확인.
- **검증**: 고정 코퍼스에서 단일 토큰 질의 → 기대 doc id 집합 일치.

### 4단계 — BinaryFuse8 오탐률 검증
- 무작위 키 집합으로 필터 구성 후 미삽입 키 조회 → 오탐률이 ≈0.4% 근처인지 속성 기반 테스트.
- (Bloom 폴백도 동일 테스트: `--fp-rate` → m·k 산수 함수.)

### 5단계 — 초성 토큰 + 검증
- `pipeline/choseong.zig`: `choseong(cp)` + 접두 초성(1..`choseong_max_len`) 토큰 생성(0x01 마커).
- 초성 추출은 Hangul 토큰에만 적용(스크립트 분할 결과 활용).
- **검증**: ㄱㄴ, ㄱㄴㄷ, 4글자 이상 초성, 한글이 아닌 입력에 영향 없음.

### 6단계 — 번들 조립 + JS 로더 전환
- `bundle.zig`: `[runtime.wasm][index][TailMeta 16B]` writer. tail meta reader 공용.
- `loader/chaza.js` (ESM):
  1. `fetch(chaza.wasm)` → `arrayBuffer()`
  2. 마지막 16B 읽어 TailMeta 파싱, magic 검증
  3. `[0..wasm_len]` wasm instantiate, `[wasm_len..wasm_len+index_len]` 인덱스
  4. `alloc(index_len)` → grow 시 view 재생성
  5. 인덱스 복사 → `set_index(ptr, len)`
  6. `search(...)` 가 반환한 포인터에서 첫 4바이트 u32 read(count), 이후 count*4 바이트를 u32 doc_id로 해석
  7. 각 doc_id로 DocEntry에서 title/url/metaValues 읽어 렌더링
  - `Chaza.load(url)`, `chaza.search(query, { maxResults, sortFieldIdx, sortDesc })` API.
- CLI가 `chaza.wasm`과 같은 디렉터리에 `chaza.js`로 함께 출력.
- **검증**: 브라우저(Node 또는 간단 HTML)에서 end-to-end 검색 동작.

### 7단계 — chaza.json 스키마 + CLI 옵션
- `config.zig` 스키마:
  ```json
  {
    "schema": {
      "indexed_fields": ["title", "body"],
      "metadata_fields": ["subtitle", "date", "views"],
      "url_field": "url"
    },
    "korean": { "choseong_search": true, "choseong_max_len": 3 }
  }
  ```
- CLI 옵션 전체 wiring: `--config`, `--stopwords <file.txt>`, `--no-choseong`, `--fp-rate`, `-o`, `-q`.
- 불용어 파일 파서: UTF-8, 줄 단위, trim, 빈 줄 무시, `#` 주석, 단일 집합. 소문자화 후 비교.
- 콘솔 진행 로그 포맷 (SPEC 46-53행).
- **검증**: 샘플 `examples/` 코퍼스로 전 파이프라인 실행.

### 8단계 — 골든 테스트 + 배포 매트릭스
- `tests/corpus.zig`: 고정 코퍼스 + 기대 index bytes 해시(골든 파일).
- 생성기가 내는 bytes → 골든 파일과 바이트 일치 회귀 테스트.
- 생성기 토큰화 결과와 런타임의 쿼리 정규화 결과가 동일 토큰 집합을 내는지 교차 검증.
- 크로스컴파일 매트릭스: `zig build -Dtarget=` linux/macos/windows(x86_64 + aarch64).
- lazy load + prefetch 코드 예시 추가.

## 리스크와 대응

- **`@embedFile` 경로 연결**: 빌드 단계 의존성 그래프로 명시.
- **wasm memory grow로 인한 view 무효화**: `alloc` 직후에만 buffer view 생성, `set_index` 이후엔 grow 없음을 런타임 코드에서 보장.
- **extern struct 정렬**: 가변 길이 구역 4바이트 패딩. `@offsetOf` 단정 테스트.
- **BinaryFuse8 구성 정확성**: pure Zig 포팅이므로 구성 버그 가능. 골든 테스트(삽입 키 전체 true, 오탐률 ≈0.4%)로 검증. C 참조 구현과 출력 비교 회귀 테스트 추가 가능.
- **필터 종류 호환성**: `filter_kind`로 blob 내부 구조가 다름. reader는 header의 `filter_kind`를 먼저 보고 디스패치.
- **정렬이 문자열 사전순만**: README에 명시. 숫자/날짜 정렬 필요 시 ISO date/zero-padding을 입력에서 해결.
- **Zig 0.16.0 API**: `std.process.Init`, `std.Io`, `std.hash.XxHash64` 등 최신 API. zig 스킬 참조.
- **Zig 0.16 `@embedFile`는 패키지 경로 안에서만 동작**: build.zig에서 WriteFile 단계로 `runtime.wasm`/`chaza.js`를 캐시 디렉터리에 복사하고, 그 디렉터리를 익명 모듈의 root로 만들어 `@embedFile`이 접근하도록 구성.
- **Zig 0.16 wasm32-freestanding + ReleaseSmall**: `export_symbol_names`를 명시하지 않으면 `-fno-entry`와 lazy DCE 결합 시 export 심볼이 모두 날아감 (43바이트 stub 출력). `runtime_mod.export_symbol_names = &.{ "alloc", "set_index", "search" }`로 강제 보존.
- **BinaryFuse8 mulhi 정확성**: Zig `u128` 곱셈으로 상위 64비트 산출 — C `__uint128_t`와 동일 결과 보장.

## 배포 산출물

`chaza build corpus.json -o chaza.wasm` 한 번에 두 파일이 나온다:

- `chaza.wasm` — 사이트별 내용이 다른 번들(runtime wasm + 인덱스 + 꼬리메타). **순수 wasm이 아님** — 반드시 로더 경유.
- `chaza.js` — 모든 사이트 공통인 정적 ESM 로더. CLI가 embedFile로 들고 재공.

```html
<script type="module">
  import { Chaza } from "./chaza.js";
  const chaza = await Chaza.load("./chaza.wasm");
  const results = chaza.search("ㄱㄴ");
</script>
```

## 확장 포인트 (언어 어댑터 2계층)

SPEC v1.1이 명시하지 않은 자체 확장 설계. 호환적이며 MVP는 default만 제공.

### 1계층: 공통 알고리즘 (wasm 내장)
- 빌드·쿼리 양쪽에서 도는 순수 결정론적 알고리즘.
- 헤더 `tokenizer_kind`(u8)로 선택.
- MVP: `default` (0)만 — 스크립트 분할 + 소문자화.
- 예약: `cjk_bigram` (1) 등.

### 2계층: 언어 어댑터 (빌드 전용 dynamic lib)
- 빌드 시점에만 실행. 무거운 사전·형태소 분석기 활용.
- CLI가 `dlopen`으로 로드. ABI stub만 정의(MVP).
- 어댑터는 호환되는 `tokenizer_kind` 선언.

### 계약
어댑터가 만든 토큰은 지정된 1계층 알고리즘의 쿼리 토큰화 결과와 매칭 가능해야 함. n-gram 자체는 1계층 알고리즘으로 충분(사전 불필요). 2계층은 사전 기반 형태소 분석기 전용.

### 필터 종류
- `filter_kind` 0 = binary_fuse (기본, BinaryFuse8), 1 = bloom (폴백), 2 = xor (예약).
- 구성·조회 모두 pure Zig (fastfilter C 참조 구현을 Zig로 포팅 — C 의존성 없음).
- 필터 blob은 자기서술적 구조(filter_kind에 따라 내부 헤더 상이). DocEntry는 필터 종류 무관 24바이트 고정.

## 수행 순서 요약

1 → 2 (게이트: writer/reader 왕복 일치 + BinaryFuse8 삽입키 전체 true) → 3 (게이트: native 조회 성공) → 4 (게이트: 오탐률 ≈0.4% 측정) → 5 (게이트: 초성 쿼리 정답) → 6 (게이트: 브라우저 end-to-end) → 7 (게이트: chaza.json 전 옵션 동작) → 8 (게이트: 골든 회귀 + 크로스컴파일 통과).

v1.1 → v1.2 전환 산출물: format.zig(version=2, FilterKind 갱신), binary_fuse.zig(신규), hash.zig(key64 추가), writer.zig/reader.zig(필터 blob 직렬화 갱신), generator.zig/bloom_fp_test.zig(필터 교체)를 먼저 갱신한 뒤 3단계로 진행.
