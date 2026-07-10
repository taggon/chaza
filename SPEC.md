# chaza

초성으로도 찾아주는 아주 작은 정적 사이트 검색 엔진 — Zig + WASM

## 버전

v1.3

## 개요

- Rust `tinysearch`에서 영감 → Zig로 작성, WASM 컴파일
- 한국어 초성 검색 지원 (차별점)
- **본문을 저장하지 않음** → 인덱스 크기가 문서 수에 크게 휘둘리지 않음
- 단일 번들 파일 + 작은 JS 로더로 배포, fetch 1회
- 쿼리 처리(토큰화·해시·조회·랭킹)는 **전부 WASM**, JS는 문자열 전달·결과 렌더링만
- **가벼움이 최우선** — 기능을 최소로 유지

## 배포 모델 · 툴체인 독립성

tinysearch는 인덱스를 만들 때마다 Rust/WASM을 재컴파일해야 함. chaza는 다름:

- **조회 런타임 WASM은 한 번만 빌드**해서 CLI에 `@embedFile`로 임베드
- 인덱스 생성 시엔 컴파일러 불필요 — **바이트 이어붙이기만** 함
- 따라서 최종 사용자는 **Zig 툴체인 없이** 단일 바이너리(`chaza`)만으로 번들 생성

### 출력 파일에 대한 주의

출력 파일명은 `chaza.wasm`이지만 **순수 WASM 모듈이 아님**. 실제로는 `[wasm][index][tail-meta]`가 이어붙은 커스텀 컨테이너임. 따라서:

- `WebAssembly.instantiateStreaming(fetch("chaza.wasm"))`을 **직접 호출하면 실패함**
- 반드시 chaza 로더를 통해 로드해야 함. 로더가 tail-meta로 앞부분만 잘라 instantiate함
- 서버가 `Content-Type: application/wasm`으로 서빙해도 로더 동작엔 무관

### 왜 데이터 세그먼트 수정이 아니라 바이트 append인가

WASM 섹션은 LEB128 길이 헤더를 가져서, 인덱스 크기가 바뀌면 데이터 섹션·메모리 섹션 길이를 재계산해야 함. 이를 피하려고 `[wasm][index][tail-meta]`로 **그냥 이어붙이고**, 로더가 tail-meta로 잘라냄.

## CLI 사용법

```bash
chaza build corpus.json -o chaza.wasm --stopwords stopwords.txt
```

예상 출력:

```
parsed 350 documents
tokenized (choseong: on, max_len 3)
built 350 binary-fuse filters (avg ~1.1 KB/doc)
wrote index: ~440 KB
embedded runtime wasm: 41 KB
→ chaza.wasm (~0.5 MB) [gzip 훨씬 작음]
```

옵션: `--config <path>`, `--stopwords <file.txt>`, `--no-choseong`, `--no-js`, `-q/--quiet`, `-h/--help`

## 입력 포맷 (tinysearch 호환)

```json
[
  {
    "title": "제목",
    "url": "https://example.com/",
    "body": "본문 (색인만, 저장 안 함)",
    "subtitle": "결과에 표시될 부제 (임의 메타 필드 예시)",
    "date": "2026-01-01",
    "views": 1000
  }
]
```

메타 값에 숫자를 써도 되지만 **전부 문자열로 저장됨** (정렬 항목 참고).

## 설정 파일 `chaza.json`

설정은 JSON 사용 (Zig 표준 라이브러리 `std.json`으로 처리, 외부 의존성 없음).

```json
{
  "schema": {
    "indexed_fields": ["title", "body"],
    "metadata_fields": ["subtitle", "date", "views"],
    "prefix_fields": ["title"],
    "url_field": "url"
  },
  "korean": {
    "choseong_search": true,
    "choseong_max_len": 3
  }
}
```

- `prefix_fields`: 단어별 edge n-gram prefix 토큰(길이 2~8, 마커 `\x02`)을 추가로 색인할 필드. **`indexed_fields`의 부분집합**이어야 함 (아니면 빌드 에러). 기본값 `["title"]`, 빈 배열이면 비활성. n 범위(2~8)는 고정 — 쿼리 측이 범위를 몰라도 동작하므로 추후 설정 개방은 하위호환

## 필드별 색인/저장 기본값

색인(검색 대상)과 저장(결과 표시)은 **독립된 두 축**임.

| 필드 | 색인 | 저장 | 비고 |
|------|------|------|------|
| title | O | O | 검색되고 결과에 표시 |
| url | X | O | 검색 안 됨, 결과에 표시(이동용) |
| body | O | X | 검색됨, 결과엔 안 나옴 |
| metadata_fields (임의) | X | O | 검색 안 됨, 결과에 표시 |

- **metadata_fields**: 사이트가 정의하는 **임의 필드**. 이름·개수 제약 없음. 값은 항상 문자열로 저장(숫자 입력도 문자열화). 예시 필드명은 설명용일 뿐 규격 아님
- **body**: 색인만, 저장 안 함 → 검색은 되지만 결과엔 안 나옴
- **원본 단어/본문 풀 없음** — brute-force 검증 데이터 제거

## 토큰화 파이프라인 (생성기 · 런타임 동일, 둘 다 Zig 코드 공유)

1. 소문자화 (indexed_fields)
2. 구두점·공백 분절 (입력은 UTF-8 전제)
3. 불용어 제거 (`--stopwords` 파일 제공 시)
4. 문서별 고유 토큰
5. `choseong_search`면 각 단어의 초성 prefix 토큰(길이 1~`choseong_max_len`) 추가, 마커 `\x01`
6. `prefix_fields` 소속 단어는 edge n-gram prefix 토큰(첫 2~8 코드포인트, 진부분 prefix만) 추가, 마커 `\x02`
7. title 필드 토큰(과 그 초성 토큰)은 `\x03` 마커 사본 추가 — 쿼리 시 title 매치 랭킹 신호
8. 문서별 중복 제거

- 불용어 제거는 **초성 토큰 생성 전에** 수행
- 입력은 **UTF-8 + NFC 정규화** 전제 (NFD 조합형은 초성 추출이 깨짐)

향후 확장: 언어별 토크나이저 전략 (영어=공백, 한국어=공백+초성 prefix, CJK=character bigram). 토큰화는 **CLI·WASM(둘 다 Zig, 코드 공유)** 에만, JS는 무관.

### 초성 추출 (Zig)

```zig
fn choseong(cp: u21) ?u8 {
    if (cp < 0xAC00 or cp > 0xD7A3) return null;
    const s = cp - 0xAC00;
    return @intCast(s / (21 * 28));
}
```

## 불용어 파일 (`--stopwords`)

- 형식: UTF-8, **줄 단위** 하나의 불용어
- 앞뒤 공백 trim, 빈 줄 무시
- `#`으로 시작하는 줄은 주석으로 무시
- 불용어도 색인 파이프라인과 동일하게 소문자화·NFC 정규화 후 비교
- 언어 구분 없음 — **단일 통합 집합**
- **내장 기본 리스트** (v1.3): `--stopwords` 미지정 시 CLI에 임베드된 기본 불용어(영어 기능어 + 한국어 단독 어절, 리포의 `stopwords.txt`)를 사용. `--stopwords <file>`은 기본 리스트를 **대체** (병합 아님). 빈 파일을 주면 제거 단계 비활성
- 기본 리스트 안전 기준: 소문자화 후 **단독 검색어로 쓰일 수 있는 단어 금지** — it(IT)·us(US)·may(5월)·will(인명) 같은 충돌어 제외
- 확장자는 `.txt` 권장. 파일명 전달 방식이라 사용자가 자유롭게 지정 가능
- **불용어는 검색어로도 매치되지 않음** — 색인에서 빠졌으므로 어떤 문서도 hit하지 않음. 런타임은 불용어 목록을 갖지 않으며(번들에 미포함), 검색어가 전부 불용어면 결과 없음. 이 동작은 README 불용어 설명에 명시

## 해시

- 알고리즘: **xxhash** (`std.hash.XxHash64`)
- 쿼리 토큰화·해시·조회는 **전부 WASM(Zig)** 에서 수행 (경우 B)
- JS는 쿼리 **문자열만** WASM 메모리에 전달 → JS에 해시 구현 불필요
- 해시 코드가 생성기·런타임 모두 동일 Zig 구현 → 비트 불일치 위험 원천 제거

## 검색

- JS가 쿼리 문자열을 WASM 메모리에 넣고 `search(...)` 호출
- WASM이 쿼리를 색인과 **동일 파이프라인**으로 정규화·토큰화·해시
- **다중 토큰은 OR** — 토큰이 하나라도 hit인 문서가 후보. hit 토큰 수가 곧 점수
- 각 문서 필터 조회 (exact match)
- 초성/일반 구분 없이 마커 토큰이 일반 토큰처럼 동작
- **brute-force 검증 없음** — 필터가 "어느 문서에 있나"까지만
- **랭킹 = hit 토큰 수 내림차순 → title 매치 수 내림차순 → 문서 입력 순서.** 모든 토큰이 hit인 문서(AND 매치)가 자연히 최상위. hits 동점이면 **제목에 토큰이 있는 문서가 본문-전용 매치·오탐보다 위** — 각 토큰의 `\x03` 프로브로 판정 (title_hits는 내부 랭킹용, 결과에 미노출)
- **마지막 토큰은 prefix로도 조회** — 입력 중인 단어로 간주, exact 조회에 더해 `\x02` prefix 토큰(2~8자)도 조회. 둘 중 하나만 hit여도 해당 토큰 1 hit (중복 가산 없음). 초성 마커 토큰·범위 밖 길이는 prefix 조회 생략
- **쿼리 토큰 상한 16** — 17번째 이후 토큰은 무시. 상한이 없으면 OR 특성상 토큰마다 문서당 ~0.4% 오탐이 누적됨 (255 토큰이면 문서의 ~64%가 가짜 hit)
- **결과에 문서별 `hits`(매치 토큰 수) 포함** — 범위 0~16 (u8 안에 안전). JS가 랭킹 근거로 활용 가능

### 결과 개수

- `max_results`를 호출 시 전달, **0이면 기본 20** 적용

### 정렬

- **hit 토큰 수 내림차순 고정** — 동점은 문서 입력 순서. 별도 정렬 옵션 없음
- **정렬 → 자르기** 순서 (후보 전체 정렬 후 상위 N)
- 메타 필드 정렬은 v1.3에서 제거 — 날짜순 등이 필요하면 반환된 결과를 JS에서 정렬 (결과는 최대 N개라 JS 정렬 비용 무시 가능)

## 필터

- **binary fuse filter (BinaryFuse8) 단일** (2022). 정적 집합에 가장 작고(≈13% 오버헤드) 조회 3회 고정으로 빠름. 8비트 지문
- 오탐 ≈ 0.4% (지문 8비트 고정)
- **exact match만** 지원, 정적, 삭제 불가 (검색 인덱스는 1회 생성이라 부합). prefix 조회는 필터 구조상 불가 — prefix 검색이 필요하면 색인 시점에 prefix를 토큰으로 추가하는 방식뿐 (초성 검색 `\x01`·`prefix_fields` edge n-gram `\x02`이 이 방식)
- 구현: **구성·조회 모두 pure Zig** (fastfilter C 참조 구현 포팅, C 의존성 없음). 생성기·런타임이 같은 Zig 코드 공유 → 해시 비트 일치가 구조적으로 보장
- **필터 변천**: v1.0은 Bloom, v1.1에서 Bloom→xor→fuse 업그레이드 경로 검토, **v1.2에서 fuse로 단일화** — fuse가 크기·속도·오탐 모두 Bloom을 흡수해 폴백 유지 이유가 없음. Bloom·xor은 구현하지 않음
- `filter_kind` 헤더 필드는 **미래 확장을 위한 포맷 예약**으로만 잔존 (현재 값 0=binary_fuse 고정, reader/runtime은 binary_fuse 전제)

## Tail meta (16 B, little-endian)

```
magic      u32
version    u8
_reserved  [3]u8
wasm_len   u32
index_len  u32
```

## 인덱스 바이너리 포맷 (flat, little-endian, 4B 정렬)

```
[header][meta-names][doc-table][string-pool][filter-data]
```

- header: magic, version, filter_kind, num_docs, num_meta_fields, offsets (fuse는 문서별 seed·segment 길이 등 파라미터 포함)
- meta-names: metadata_fields 이름 목록 (임의 개수·이름)
- doc-table: 문서별 { filter off/len(+fuse 파라미터), title off/len, url off/len, meta off/len[] }
- string-pool: title / url / 메타 문자열 (본문·원본 단어 없음)
- filter-data: 문서별 필터(지문 배열) 연결

## 크기 예상 (350 docs × ~5 KB)

- 런타임 WASM: ~40 KB (fuse 조회 코드 포함)
- 필터(binary fuse): ~400 KB (Bloom 대비 소폭 절감)
- title / url / 메타 문자열: 수십 KB
- 전체 번들: **~0.5 MB 안팎** (gzip/brotli 시 훨씬 작음)

## Zig 런타임 export API

```zig
export fn alloc(n: usize) [*]u8;
export fn set_index(ptr: [*]const u8, len: usize) void;

// max_results: 0이면 기본 20
export fn search(
    query_ptr: [*]const u8,
    query_len: usize,
    max_results: u32,
) [*]const u8;
```

- `search`는 쿼리 문자열을 받아 내부에서 토큰화·해시·조회·랭킹
- 반환 버퍼: `[u32 count][(u32 doc_id, u32 hits) × count]` (little-endian). `hits` = 매치 토큰 수(0~16)
- JS가 doc_id로 string-pool에서 title/url/메타를 꺼내 렌더링, `hits`는 결과 객체에 노출

## 통합 예시

```html
<script type="module">
  import { Chaza } from "./chaza.js";
  const chaza = await Chaza.load("./chaza.wasm");
  const results = chaza.search("ㄱㄴ");
</script>
```

## 주의

- 출력 `chaza.wasm`은 순수 wasm이 아닌 컨테이너 → 반드시 로더 경유
- 메모리 grow 시 `wasm.memory.buffer` 재할당 → TypedArray 재생성 필요
- 모든 다중 바이트 정수는 little-endian
- 입력은 UTF-8 + NFC 전제
- fuse 구성 해시와 조회 해시는 반드시 동일해야 함 — 구성·조회가 같은 pure Zig 코드를 공유하므로 구조적으로 충족

## 구현 순서

1. 인덱스 포맷 확정 (fuse 파라미터 포함)
2. 간단 입력으로 생성기 바이트 출력
3. C `fastfilter` 연결해 구성, Zig 조회 포팅·검증
4. fuse 오탐률·조회 정확도 검증
5. 초성 토큰 생성 추가
6. 번들·JS 로더 완성
7. `chaza.json` 스키마 구현
8. 골든 테스트 (구성 C ↔ 조회 Zig 해시 일치, 토큰화 일치)

## Changelog

### v1.3

- **검색을 AND 고정 → OR + hit 수 랭킹으로 변경**: 토큰이 하나라도 hit인 문서가 후보, hit 토큰 수 내림차순 정렬(동점은 입력 순). AND 매치가 자연히 최상위. 일부 검색어가 불용어여도 나머지 토큰으로 결과가 나옴.
- **메타 필드 정렬 제거**: `search()`에서 `sort_field_idx`/`sort_desc` 인자 삭제 → `(query_ptr, query_len, max_results)`. 정렬은 hit 수 내림차순 고정. 메타 정렬은 JS에서 결과 후처리로 대체.
- **불용어 동작 명시**: 불용어는 검색어로도 매치 안 됨(런타임에 불용어 목록 없음). 전부 불용어인 쿼리는 결과 없음. README에 명시.
- **결과에 `hits` 노출**: 반환 버퍼가 `[u32 count][(u32 doc_id, u32 hits) × count]`로 확장. JS `SearchResult`에 `hits`(매치 토큰 수) 필드 추가.
- **쿼리 토큰 상한 16**: 17번째 이후 토큰 무시 → `hits` 범위 0~16 보장, OR 오탐 노이즈·조회 비용 상한.
- **필터 단일화 명시**: Bloom(v1.0 초기 필터)·xor 대체 옵션은 구현하지 않음 — fuse가 크기·속도·오탐 모두 흡수. `--fp-rate` 옵션 삭제. `filter_kind`는 포맷 예약으로만 잔존.
- **구현 전략 현행화**: 필터 구성·조회 모두 pure Zig (v1.2의 "C 구성 재사용" 전략 폐기 — PLAN.md의 결정을 SPEC 본문에 반영).
- **prefix 검색 (search-as-you-type)**: `prefix_fields`(기본 `["title"]`, `indexed_fields`의 부분집합) 단어에 edge n-gram prefix 토큰(첫 2~8 코드포인트, 마커 `\x02`, 진부분 prefix만) 색인. 쿼리 마지막 토큰은 exact + prefix 병행 조회(하나만 hit여도 1 hit). 비용은 title 기준 문서당 수십 바이트. 인덱스 포맷 변경 없음.
- **기본 불용어 내장**: `--stopwords` 미지정 시 임베드된 안전 리스트(영어 기능어 + 한국어 단독 어절) 적용. 파일 지정 시 대체, 빈 파일이면 비활성. 필터 크기 약 4% 절감 (위키 1,000문서 실측).
- **title 매치 랭킹 (2차 정렬 키)**: title 필드 토큰과 그 초성 토큰을 `\x03` 마커 사본으로 추가 색인(문서당 ~2% 크기). 쿼리 시 토큰마다 `\x03` 프로브로 title_hits를 세어 hits 동점을 가름 — 오탐·본문 매치가 제목 매치 위에 오던 문제 해소 (known-item MRR@10 0.38→0.98 @1,000문서). 결과 버퍼·JS API 불변.

### v1.2

- **필터 기본을 binary fuse filter로 확정**. Bloom은 디버깅/폴백 옵션으로 격하, xor는 대체 옵션 유지 (`filter_kind`).
- 구현 전략 명시: **구성은 C `fastfilter` 재사용, 조회만 Zig 포팅**.
- 필터 크기 추정 소폭 하향(~430 KB → ~400 KB), 오탐 목표를 8비트 지문 기준(≈0.4%)으로 갱신.
- 인덱스 포맷 header/doc-table에 fuse 파라미터(seed·segment 등) 반영.
- 구현 순서·주의 사항에 C↔Zig 해시 일치 항목 추가.

### v1.1

- **본문/원본 단어 풀 제거**: body는 색인(토큰화)만 하고 버림. 결과 판단은 title로.
- **brute-force 검증 단계 삭제**.
- **필드별 색인/저장 기본값 표 추가**.
- **필터 업그레이드 경로 정리** (Bloom→xor→binary fuse).
- **크기 추정 갱신**: ~1.8 MB → ~0.5 MB.
- **출력 파일명 변경**: `chaza.bundle` → `chaza.wasm`.
- **metadata_fields 명확화**: 임의 필드, 값은 문자열 저장.
- **설정 파일 포맷 변경**: `chaza.toml` → `chaza.json`.
- **해시 방식 확정 (경우 B)** + **xxhash 확정**.
- **불용어 처리 변경**: CLI `--stopwords <file.txt>`.
- **검색 동작 확정**: 다중 토큰 AND 고정, 랭킹 없음, `max_results` 기본 20, 메타 문자열 사전순 정렬 옵션.
- **입력 전제 명시**: UTF-8 + NFC.
- **문서 상단 버전 섹션 추가**.

### v1.0

- 초기 스펙. 단일 번들 `[wasm][index][tail-meta]`, tail-meta 분리, Zig 툴체인 독립 생성기.
- tinysearch 호환 JSON 입력, `chaza.toml` 스키마.
- 토큰화 파이프라인.
- Bloom filter + brute-force 검증(원본 단어 저장).
- 초성 prefix 색인, 2단계 검색.
- 크기 추정 ~1.8 MB.
