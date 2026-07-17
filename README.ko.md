# Chaza

![NPM Version](https://img.shields.io/npm/v/chaza-cli) [![codecov](https://codecov.io/github/taggon/chaza/graph/badge.svg?token=SQDPKO0S4S)](https://codecov.io/github/taggon/chaza) ![Test](https://github.com/taggon/chaza/workflows/Test/badge.svg) ![GitHub License](https://img.shields.io/github/license/taggon/chaza)

초성으로도 찾아주는 아주 작은 정적 사이트 검색 엔진 — Zig + WASM.

[라이브 데모](https://taggon.github.io/chaza/) | [[English]](https://github.com/taggon/chaza/blob/main/README.md)

## 특징

- **가벼움.** 인덱스는 문서 본문이 아닌 binary fuse filter만 저장. 문서 수백 페이지 기준 ~0.5 MB.
- **한국어 초성 검색.** ㄱㄴ만 입력해도 가나, 강남, 경남… 매칭.
- **쿼리 처리 전부 WASM.** JS는 문자열 전달과 결과 렌더링만.
- **최종 사용자에게 컴파일러 불필요.** 런타임 WASM이 CLI 바이너리에 포함. 인덱스 생성은 바이트 이어붙이기만.

## vs tinysearch

Chaza는 [tinysearch](https://github.com/tinysearch/tinysearch)에서 영감을 받았고 같은 코퍼스 포맷을 읽습니다. 동일한 위키백과 100문서 코퍼스(한국어+영어), 양쪽 모두 title+body 색인, Apple M1 Max, Node v22 기준:

| | chaza | tinysearch 0.10 | |
|---|---|---|---|
| 인덱스 빌드 시간 | **5.8 ms** | 4.5 s | 약 750배 빠름 |
| 검색 속도 | **6.0 µs/쿼리** | 309 µs/쿼리 | 약 50배 빠름 |
| 산출물 크기 (gzip) | **25 KB** | 60 KB | 약 2.4배 작음 |
| Recall@20 | **96.7%** | 87.5% | |
| 정밀도 | **88.0%** | 77.4% | |
| Known-item MRR@10 | **0.99** | 0.98 | |
| 오탐률 | **0.19%/doc** | 0.27%/doc | |
| 한국어 초성 검색 | ✅ (100% 검색 성공) | ❌ | |
| 단일 바이너리로 완결 | ✅ | ❌ Rust + wasm 툴체인 필요 | |

전체 결과(500/1,000문서 스케일링, 정확도 측정 방법, 한계까지 포함): [`bench/RESULTS.md`](bench/RESULTS.md). 재현 방법은 [`bench/`](bench/) 참고.

## 설치

**npm:**

```bash
npm install chaza-cli
```

**셸 (단독 바이너리):**

```bash
curl -fsSL https://raw.githubusercontent.com/taggon/chaza/main/scripts/install.sh | sh
```

macOS, Linux (x64, arm64) 플랫폼별 바이너리가 자동 선택됩니다.

## 빠른 시작

```bash
# JSON 코퍼스에서 검색 인덱스 생성
npx chaza build corpus.json -o chaza.wasm --config chaza.json
```

두 파일이 생성됩니다:

| 파일 | 설명 |
|------|------|
| `chaza.wasm` | 유효한 순수 WASM 모듈 — 검색 인덱스가 데이터 세그먼트로 내장되어 있습니다. |
| `chaza.js` | 모든 사이트 공통 ESM 로더. |

`--no-js` 옵션으로 로더 출력을 생략할 수 있습니다.

### 페이지에 적용

```html
<script type="module">
  import { Chaza } from "chaza-cli";
  const chaza = await Chaza.load("./chaza.wasm");
  const results = chaza.search("ㄱㄴ");
</script>
```

각 결과는 `{ title, url, meta, hits }` 형태입니다 — `hits`는 매칭된 쿼리 토큰 수 (0~16).

## CLI

```bash
chaza build <corpus.json> [옵션]

옵션:
  -o, --output <path>      출력 wasm 경로 (기본: chaza.wasm)
  --config <path>          chaza.json 설정 파일 경로
  --stopwords <path>       불용어 파일 (내장 기본 리스트 대체,
                           빈 파일이면 제거 비활성)
  --no-choseong            초성 검색 비활성화
  --no-js                  chaza.js 로더 출력 생략
  -q, --quiet              진행 로그 숨김
  -h, --help               도움말
```

## 입력 포맷 (tinysearch 호환)

```json
[
  {
    "title": "글 제목",
    "url": "https://example.com/posts/1",
    "body": "색인할 전체 텍스트 (출력에 저장되지 않음)",
    "path": "/posts/1",
    "date": "2026-01-01"
  }
]
```

- **title** — 색인 + 저장 (결과에 표시)
- **url** — 저장만 (결과에 표시, 검색 대상 아님)
- **body** — 색인만 (검색은 되지만 출력에 저장 안 함)
- `metadata_fields`에 지정한 나머지 필드 — 저장만, 값은 항상 문자열

숫자는 자동으로 문자열로 변환됩니다.

## 설정 파일 (`chaza.json`)

```json
{
  "schema": {
    "indexed_fields": ["title", "body"],
    "metadata_fields": ["path", "date"],
    "prefix_fields": ["title"],
    "url_field": "url"
  },
  "korean": {
    "choseong_search": true,
    "choseong_max_len": 3
  }
}
```

| 필드 | 기본값 | 설명 |
|------|--------|------|
| `indexed_fields` | `["title"]` | 토큰화하여 색인할 필드 |
| `metadata_fields` | `[]` | 표시용으로 저장할 필드 (색인 안 함) |
| `prefix_fields` | `["title"]` | 입력 중 prefix(2~8자)로도 매칭할 필드. `indexed_fields`의 부분집합이어야 함. `[]`이면 비활성 |
| `url_field` | `"url"` | URL이 들어 있는 필드 |
| `choseong_search` | `true` | 초성 접두 토큰 생성 여부 |
| `choseong_max_len` | `3` | 초성 접두 최대 길이 (1~3) |

## 검색 동작

- **다중 토큰은 OR + 매칭 수 랭킹** — 매칭 토큰이 많은 문서가 먼저 오고, 그 수가 각 결과의 `hits`로 제공됩니다. `hits` 동점이면 **제목이 매칭된 문서**가 본문-전용 매치보다 위에 옵니다.
- **마지막 검색어는 prefix(2~8자)로도 매칭** — `프로그`로 제목에 "프로그래밍"이 있는 문서를 찾음 (`prefix_fields` 대상).
- **초성 쿼리** `ㅅㅈ`는 해당 초성으로 시작하는 단어가 있는 문서에 매칭.
- **`max_results`** 기본 20: `chaza.search("hello", { maxResults: 10 })`. 결과는 `hits` 순 — 날짜순 등 다른 기준은 반환된 배열을 JS에서 정렬.

## 제약사항

- **입력은 UTF-8 + NFC 전제.** NFD(조합형) 한글은 초성 추출이 깨짐.
- **오탐 존재.** 조회의 ~0.2%가 토큰이 없는 문서에 매칭될 수 있음(title/prefix 신호는 사실상 정확한 16비트 계층 사용). 필터의 태생적 특성. 실용적 코퍼스 상한은 수천 문서 — 설계·검증 범위는 1,000문서까지.
- **정적 인덱스.** 증분 업데이트 불가. 문서 추가/삭제 시 재생성.
- **불용어는 검색 불가.** 불용어만으로 이루어진 쿼리는 결과 없음.

## 문서

- [작동 원리](docs/how-it-works.ko.md) — 토큰화 파이프라인, 초성/prefix 토큰, binary fuse filter, 번들 포맷, 규모 한계
- [SPEC.md](SPEC.md) — 포맷·동작 전체 명세

## 라이선스

MIT
