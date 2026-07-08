# chaza

초성으로도 찾아주는 아주 작은 정적 사이트 검색 엔진 — Zig + WASM. 초성만 입력해도 한국어 문서를 찾아줍니다.

## 왜 만들었나?

- **가볍다.** 인덱스는 문서 본문이 아닌 binary fuse filter만 저장. 문서 수백 페이지 기준 ~0.5 MB.
- **한국어 초성 검색.** ㄱㄴ만 입력해도 가나, 강남, 경남… 매칭.
- **쿼리 처리 전부 WASM.** 토큰화·해시·조회·랭킹이 번들된 WASM 안에서. JS는 문자열 전달과 결과 렌더링만.
- **최종 사용자에게 컴파일러 불필요.** 런타임 WASM이 CLI 바이너리에 포함. 인덱스 생성은 바이트 이어붙이기만 — 도구 설치 없이.

## 설치

**npm:**

```bash
npm install chaza
```

**셸 (단독 바이너리):**

```bash
curl -fsSL https://raw.githubusercontent.com/taggon/chaza/main/scripts/install.sh | sh
```

macOS, Linux (x64, arm64) 플랫폼별 바이너리가 자동 선택됩니다.

## 빠른 시작

```bash
# JSON 코퍼스에서 검색 인덱스 생성
npx chaza build corpus.json -o chaza.bundle --config chaza.json
```

두 파일이 생성됩니다:

| 파일 | 설명 |
|------|------|
| `chaza.bundle` | 번들: `[runtime.wasm][index][꼬리메타 16 B]`. **순수 WASM 모듈이 아님** — 로더를 거쳐 로드. |
| `chaza.js` | 모든 사이트 공통 ESM 로더. |

`--no-js` 옵션으로 로더 출력을 생략할 수 있습니다.

### 페이지에 적용

```html
<script type="module">
  import { Chaza } from "chaza";
  const chaza = await Chaza.load("./chaza.bundle");
  const results = chaza.search("ㄱㄴ");
</script>
```

각 결과는 `{ title, url, meta, hits }` 형태입니다 — `hits`는 매칭된 쿼리 토큰 수 (0~16).

## CLI

```bash
chaza build <corpus.json> [옵션]

옵션:
  -o, --output <path>      출력 번들 경로 (기본: chaza.bundle)
  --config <path>          chaza.json 설정 파일 경로
  --stopwords <path>       불용어 파일 (줄 단위)
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
    "url": "https://example.com/post",
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

- **다중 토큰은 OR + 매칭 수 랭킹.** 토큰이 하나라도 매칭되는 문서가 결과에 포함되고, 매칭된 토큰 수가 많은 문서가 먼저 옵니다. 모든 토큰이 매칭되는 문서(AND 매치)가 자연히 최상위. 동점은 문서 입력 순서.
- **결과마다 `hits` 포함** — 매칭된 쿼리 토큰 수 (범위 0~16). 강한 매치 표시나 약한 매치 필터링에 활용.
- **쿼리 토큰은 최대 16개까지만 처리.** 17번째 이후는 무시 (오탐 노이즈·조회 비용 상한).
- **마지막 검색어는 prefix로도 매칭.** 입력 중인 마지막 토큰(2~8자)은 `prefix_fields`(기본 title) 단어의 앞부분과도 매칭 — `프로그`로 "프로그래밍"이 제목에 있는 문서를 찾음. 그 외 필드는 여전히 단어 완전 일치.
- **초성 토큰은 일반 토큰처럼 동작.** `ㅅㅈ` 쿼리는 해당 초성으로 시작하는 단어가 있는 문서에 매칭.
- **`max_results`** 기본 20, 0이면 기본값 적용.

```js
chaza.search("hello", { maxResults: 10 });
```

### 정렬

결과는 항상 매칭 토큰 수 내림차순입니다. 날짜순 등 다른 기준이 필요하면 반환된 결과 배열을 JS에서 정렬하세요 (결과는 최대 `max_results`개라 비용이 무시할 수준입니다).

## 작동 원리

### 토큰화 파이프라인 (생성기·런타임 동일)

1. 소문자화 (ASCII A–Z)
2. 스크립트 그룹별 분절 (Latin, Hangul, Han, Hiragana, Katakana, Number)
3. 불용어 제거 (`--stopwords` 파일)
4. 문서별 고유 토큰
5. `choseong_search`가 켜져 있으면 초성 접두 토큰 추가 (마커 `\x01`, 길이 1~`choseong_max_len`)
6. `prefix_fields` 소속 단어는 edge n-gram 접두 토큰 추가 (마커 `\x02`, 첫 2~8 코드포인트)
7. 다시 중복 제거

생성기와 런타임이 같은 Zig 토큰화 코드를 공유 — 비트 수준 일치가 보장됩니다.

**불용어는 색인에서만 제거됩니다.** 불용어 목록은 번들에 포함되지 않으므로 런타임은 쿼리에서 불용어를 걸러내지 못하며, 불용어를 검색하면 어떤 문서와도 매칭되지 않습니다. 검색어 일부가 불용어라면 나머지 토큰으로 매칭되고(OR 랭킹), **전부 불용어라면 결과가 비어 있습니다.**

### 필터: Binary Fuse (BinaryFuse8)

문서마다 고유의 [binary fuse filter](https://arxiv.org/abs/2201.01174)가 생성됩니다 — 정적 확률 집합 자료구조로, 오탐률 ~0.4% (8비트 지문, 조회 시 고정 3회). 토큰당 약 **9비트**를 사용합니다.

토큰 → xxhash64 → 64비트 키 → binary fuse 내부 해시 → 3개 위치 + 지문 XOR.

필터만 저장되며, 원본 텍스트나 토큰은 저장되지 않습니다.

### 번들 포맷

```
[runtime.wasm][인덱스 바이트][꼬리메타 16 B]
```

꼬리메타에 `wasm_len`과 `index_len`이 리틀엔디안으로 저장됩니다. 로더가 마지막 16바이트를 읽어 WASM과 인덱스 영역을 분리한 뒤, WASM을 인스턴스화하고 인덱스를 주입합니다.

`chaza.bundle`은 **유효한 WASM 모듈이 아님** — 반드시 `chaza.js` 로더를 거쳐야 합니다.

## 제약사항

- **입력은 UTF-8 + NFC 전제.** NFD(조합형) 한글은 초성 추출이 깨짐.
- **메타 필드 정렬 없음.** 결과는 매칭 토큰 수 내림차순 고정. 다른 기준 정렬은 JS에서 결과 후처리.
- **불용어는 검색 불가.** 색인에서 제거되므로 불용어만으로 이루어진 쿼리는 결과 없음.
- **정적 인덱스.** 증분 업데이트 불가. 문서 추가/삭제 시 코퍼스에서 재생성.
- **오탐 존재.** 약 0.4%의 쿼리가 실제로는 토큰이 없는 문서에 매칭될 수 있음. 별도 검증 단계 없음.

## 감사

[tinysearch](https://github.com/tinysearch/tinysearch)에서 영감을 받았습니다.

## 라이선스

MIT
