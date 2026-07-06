# chaza

초성으로도 찾아주는 아주 작은 정적 사이트 검색 엔진 — Zig + WASM

## 버전

v1.2

## 개요

- Rust `tinysearch`에서 영감 → Zig로 작성, WASM 컴파일
- 한국어 초성 검색 지원 (차별점)
- **본문을 저장하지 않음** → 인덱스 크기가 문서 수에 크게 휘둘리지 않음
- 단일 번들 파일 + 작은 JS 로더로 배포, fetch 1회
- 쿼리 처리(토큰화·해시·조회·정렬)는 **전부 WASM**, JS는 문자열 전달·결과 렌더링만
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

옵션: `--config <path>`, `--stopwords <file.txt>`, `--no-choseong`, `--fp-rate <float>`(기본 0.02), `-q/--quiet`, `-h/--help`

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
    "url_field": "url"
  },
  "korean": {
    "choseong_search": true,
    "choseong_max_len": 3
  }
}
```

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
6. 문서별 중복 제거

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
- 미지정 시 불용어 제거 단계 생략 (내장 기본 리스트 없음)
- 확장자는 `.txt` 권장. 파일명 전달 방식이라 사용자가 자유롭게 지정 가능

## 해시

- 알고리즘: **xxhash** (`std.hash.XxHash64`)
- 쿼리 토큰화·해시·조회는 **전부 WASM(Zig)** 에서 수행 (경우 B)
- JS는 쿼리 **문자열만** WASM 메모리에 전달 → JS에 해시 구현 불필요
- 해시 코드가 생성기·런타임 모두 동일 Zig 구현 → 비트 불일치 위험 원천 제거

## 검색

- JS가 쿼리 문자열을 WASM 메모리에 넣고 `search(...)` 호출
- WASM이 쿼리를 색인과 **동일 파이프라인**으로 정규화·토큰화·해시
- **다중 토큰은 AND 고정** — 모든 토큰이 있는 문서만 (옵션 없음)
- 각 문서 필터 조회 (exact match)
- 초성/일반 구분 없이 마커 토큰이 일반 토큰처럼 동작
- **brute-force 검증 없음** — 필터가 "어느 문서에 있나"까지만
- **관련도 랭킹 없음**

### 결과 개수

- `max_results`를 호출 시 전달, **0이면 기본 20** 적용

### 정렬

- 기본: 정렬 없음 → **문서 입력 순서**
- 메타 필드 기준 정렬 옵션 제공
  - **문자열 사전순만** 지원 (메타는 전부 문자열)
  - asc/desc 선택
  - 해당 메타 값이 없는 문서는 **맨 뒤**로
  - **정렬 → 자르기** 순서 (후보 전체 정렬 후 상위 N)
- 숫자/날짜 의미 정렬은 지원 안 함 → 필요 시 입력 형식으로 해결(ISO date, zero-padding). 이 한계는 README에 명시

## 필터

- 기본: **binary fuse filter** (2022). 정적 집합에 가장 작고(≈13% 오버헤드) 조회 3회 고정으로 빠름. 8비트 지문(`BinaryFuse8`) 사용
- 목표 오탐 ≈ 0.4% (8비트 지문 기준). `--fp-rate`로 지문 폭 조정 여지
- **exact match만** 지원, 정적, 삭제 불가 (검색 인덱스는 1회 생성이라 부합)
- 구현 전략: **구성(construction)은 C `fastfilter` 재사용**(`@cImport`로 연결), **조회만 Zig로 포팅**(30~50줄). 생성기·런타임 조회 해시는 동일 Zig 구현
- `filter_kind` 필드로 대체 가능:
  - **xor filter** (2019) — fuse의 전신, 약간 더 큼
  - **Bloom filter** — 가장 단순. 디버깅/폴백용으로만
- MVP 착수 시 조회 검증이 급하면 Bloom으로 파이프라인을 먼저 뚫고 fuse로 교체해도 됨(`filter_kind` 덕에 포맷 불변)

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

// sort_field_idx: -1 이면 정렬 안 함(입력 순), 그 외는 meta-names 인덱스
// max_results: 0이면 기본 20
export fn search(
    query_ptr: [*]const u8,
    query_len: usize,
    max_results: u32,
    sort_field_idx: i32,
    sort_desc: bool,
) [*]const u8;
```

- `search`는 쿼리 문자열을 받아 내부에서 토큰화·해시·조회·정렬
- doc-id 목록 반환, JS가 string-pool에서 title/url/메타를 꺼내 렌더링

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
- fuse 구성 해시와 조회 해시는 반드시 동일해야 함 (C 구성 ↔ Zig 조회 비트 일치)

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
