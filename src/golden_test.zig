//! chaza 골든 테스트 — SPEC v1.1 (생성기·런타임 토큰화·해시 일치).
//!
//! 핵심 검증:
//! 1. 생성기 결정론: 같은 입력 → 같은 index bytes.
//! 2. 빌드-쿼리 토큰화 일치: 색인 시 토큰화한 토큰으로 search 시 매칭.
//! 3. 대표 케이스 end-to-end 회귀 (한글·영어·초성·AND·정렬·제한).

const std = @import("std");
const generator = @import("generator.zig");
const bundle_mod = @import("bundle.zig");
const reader = @import("index/reader.zig");
const runtime = @import("runtime.zig");
const binary_fuse = @import("pipeline/binary_fuse.zig");
const hash = @import("pipeline/hash.zig");
const stopwords = @import("pipeline/stopwords.zig");
const format = @import("index/format.zig");

// ── 골든 코퍼스 (5문서, 한글+영어 혼합) ──
//
// doc 0: title="Hello World", body="hello world programming chaza"
//   tokens: hello, world, programming, chaza
// doc 1: title="Zig Programming", body="zig wasm fast chaza"
//   tokens: zig, programming, wasm, fast, chaza
// doc 2: title="안녕하세요", body="안녕하세요 친구 한글 chaza"
//   tokens: 안녕하세요, 친구, 한글, chaza
//   초성: ㅇ ㅇㄴ ㅇㄴㅎ (안녕하세요), ㅊ ㅊㄱ (친구), ㅎ ㅎㄱ (한글)
// doc 3: title="Hello 안녕", body="hello 안녕 world chaza"
//   tokens: hello, 안녕, world, chaza
//   초성: ㅇ ㅇㄴ (안녕)
// doc 4: title="Empty Body", body="chaza"
//   tokens: empty, body, chaza
//
// metadata_fields: author(0), date(1)
// choseong_max_len: 3

const GOLDEN_JSON =
    \\[
    \\  {"title":"Hello World","url":"/hello","body":"hello world programming chaza","author":"alice","date":"2026-01-15"},
    \\  {"title":"Zig Programming","url":"/zig","body":"zig wasm fast chaza","author":"bob","date":"2026-02-20"},
    \\  {"title":"안녕하세요","url":"/annyeong","body":"안녕하세요 친구 한글 chaza","author":"charlie","date":"2026-03-10"},
    \\  {"title":"Hello 안녕","url":"/mixed","body":"hello 안녕 world chaza","author":"alice","date":"2026-01-05"},
    \\  {"title":"Empty Body","url":"/empty","body":"chaza","author":"dave","date":"2026-04-01"}
    \\]
;

const GOLDEN_OPTS = generator.GenerateOptions{
    .indexed_fields = &.{ "title", "body" },
    .metadata_fields = &.{ "author", "date" },
    .choseong_max_len = 3,
};

// 문서별 예상 토큰 (불용어 제거·중복 제거 후, 초성 토큰 제외)
const DocTokens = struct { doc_id: u32, tokens: []const []const u8 };
const golden_doc_tokens = [_]DocTokens{
    .{ .doc_id = 0, .tokens = &.{ "hello", "world", "programming", "chaza" } },
    .{ .doc_id = 1, .tokens = &.{ "zig", "programming", "wasm", "fast", "chaza" } },
    .{ .doc_id = 2, .tokens = &.{ "안녕하세요", "친구", "한글", "chaza" } },
    .{ .doc_id = 3, .tokens = &.{ "hello", "안녕", "world", "chaza" } },
    .{ .doc_id = 4, .tokens = &.{ "empty", "body", "chaza" } },
};

// ── 헬퍼 ──

fn resultCount(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

fn resultDocId(ptr: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, ptr[4 + i * 4 ..][0..4], .little);
}

/// 결과 집합에 doc_id가 포함되어 있는지 확인.
fn resultContains(ptr: [*]const u8, count: u32, doc_id: u32) bool {
    for (0..count) |i| {
        if (resultDocId(ptr, i) == doc_id) return true;
    }
    return false;
}

/// 골든 코퍼스로 bundle 생성. caller가 bundle_bytes free.
fn buildGolden(allocator: std.mem.Allocator) !generator.GenerateResult {
    return generator.generate(allocator, GOLDEN_JSON, &.{}, GOLDEN_OPTS);
}

// ── A. 결정론적 인덱스 생성 ──

test "골든 결정론: 같은 입력 두 번 → 동일 index bytes" {
    const allocator = std.testing.allocator;
    const r1 = try buildGolden(allocator);
    defer allocator.free(r1.bundle_bytes);
    const r2 = try buildGolden(allocator);
    defer allocator.free(r2.bundle_bytes);

    try std.testing.expectEqual(r1.index_size, r2.index_size);

    const v1 = try bundle_mod.open(r1.bundle_bytes);
    const v2 = try bundle_mod.open(r2.bundle_bytes);
    try std.testing.expectEqualSlices(u8, v1.index, v2.index);
}

test "골든 결정론: 다른 choseong_max_len → 다른 index bytes" {
    const allocator = std.testing.allocator;

    const r_off = try generator.generate(allocator, GOLDEN_JSON, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .metadata_fields = &.{ "author", "date" },
        .choseong_max_len = 0,
    });
    defer allocator.free(r_off.bundle_bytes);

    const r_on = try buildGolden(allocator);
    defer allocator.free(r_on.bundle_bytes);

    const v_off = try bundle_mod.open(r_off.bundle_bytes);
    const v_on = try bundle_mod.open(r_on.bundle_bytes);
    // 초성 토큰 유무로 필터 지문 패턴이 달라야 함
    try std.testing.expect(!std.mem.eql(u8, v_on.index, v_off.index));
}

test "골든 결정론: stopword 추가 → 다른 index bytes" {
    const allocator = std.testing.allocator;
    var sw = try stopwords.StopwordSet.fromFileBytes(allocator, "hello\n");
    defer sw.deinit(allocator);

    const r_sw = try generator.generate(allocator, GOLDEN_JSON, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .metadata_fields = &.{ "author", "date" },
        .choseong_max_len = 3,
        .stopwords = sw,
    });
    defer allocator.free(r_sw.bundle_bytes);

    const r_no = try buildGolden(allocator);
    defer allocator.free(r_no.bundle_bytes);

    const v_sw = try bundle_mod.open(r_sw.bundle_bytes);
    const v_no = try bundle_mod.open(r_no.bundle_bytes);
    // hello 제거 → 필터 지문 패턴 상이
    try std.testing.expect(!std.mem.eql(u8, v_sw.index, v_no.index));
}

// ── B. 빌드-쿼리 토큰화 일치 ──

test "골든 일치: 모든 색인 토큰이 해당 문서 필터에 존재" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    for (golden_doc_tokens) |dt| {
        const filter_bytes = idx.docFilter(dt.doc_id).?;
        const fuse = binary_fuse.BinaryFuse8View.fromBlob(filter_bytes) orelse return error.UnexpectedNull;
        for (dt.tokens) |tok| {
            try std.testing.expect(fuse.contains(hash.key64(tok)));
        }
    }
}

test "골든 일치: search('hello') → 토큰을 가진 문서만 hit (docs 0, 3)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "골든 일치: search('hello') → 토큰 없는 문서는 miss (docs 1, 2, 4)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);
    const count = resultCount(r);

    try std.testing.expect(!resultContains(r, count, 1));
    try std.testing.expect(!resultContains(r, count, 2));
    try std.testing.expect(!resultContains(r, count, 4));
}

// ── C. 대표 케이스 골든 코퍼스 ──

test "골든: search('안녕') → doc 3만 hit (안녕 ≠ 안녕하세요)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "안녕";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(r));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 0));
}

test "골든: search('ㅎ') → doc 2만 hit (한글로 시작하는 초성 ㅎ)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "ㅎ";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(r));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(r, 0));
}

test "골든: search('hello world') AND → docs 0, 3만 hit" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello world";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "골든: 빈 쿼리 → count=0" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

test "골든: 미존재 토큰 → count=0" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "zzznonexistentzzz";
    const r = runtime.search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

// ── D. 정렬 및 제한 ──

test "골든 정렬: date asc → 빠른 순 (3, 0, 1, 2, 4)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "chaza";
    const r = runtime.search(q.ptr, q.len, 0, 1, false); // field_idx=1 (date), asc

    try std.testing.expectEqual(@as(u32, 5), resultCount(r));
    // 2026-01-05(3), 2026-01-15(0), 2026-02-20(1), 2026-03-10(2), 2026-04-01(4)
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 1));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 2));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(r, 3));
    try std.testing.expectEqual(@as(u32, 4), resultDocId(r, 4));
}

test "골든 정렬: date desc → 늦은 순 (4, 2, 1, 0, 3)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "chaza";
    const r = runtime.search(q.ptr, q.len, 0, 1, true); // desc

    try std.testing.expectEqual(@as(u32, 5), resultCount(r));
    // 2026-04-01(4), 2026-03-10(2), 2026-02-20(1), 2026-01-15(0), 2026-01-05(3)
    try std.testing.expectEqual(@as(u32, 4), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(r, 1));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 2));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 3));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 4));
}

test "골든 정렬: metaValue null인 문서는 맨 뒤" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    // doc 4의 date MetaEntry.off를 0xFFFFFFFF로 손상 → metaValue(4, 1) → null
    const stride = format.docEntrySize(idx.header.num_meta_fields);
    const meta_byte_off = @as(usize, idx.header.doc_table_off) +
        4 * stride + @sizeOf(format.DocEntryPrefix) + @sizeOf(format.MetaEntry);
    std.mem.writeInt(u32, result.bundle_bytes[meta_byte_off..][0..4], 0xFFFFFFFF, .little);

    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "chaza";
    const r = runtime.search(q.ptr, q.len, 0, 1, false); // date asc

    try std.testing.expectEqual(@as(u32, 5), resultCount(r));
    // doc 4는 null → 맨 뒤, 나머지는 날짜순: 3, 0, 1, 2
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 1));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 2));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(r, 3));
    try std.testing.expectEqual(@as(u32, 4), resultDocId(r, 4)); // null → 맨 뒤
}

test "골든: max_results=2 → 최대 2개 반환" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "chaza";
    const r = runtime.search(q.ptr, q.len, 2, -1, false);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    // 입력 순: docs 0, 1
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 1));
}
