//! chaza golden test — SPEC v1.1 (generator·runtime tokenization·hash consistency).
//!
//! Core verification:
//! 1. Generator determinism: same input → same index bytes.
//! 2. Build-query tokenization consistency: tokens tokenized at index time match at search time.
//! 3. Representative case end-to-end regression (Korean·English·choseong·OR ranking·limit).

const std = @import("std");
const generator = @import("generator.zig");
const bundle_mod = @import("bundle.zig");
const reader = @import("index/reader.zig");
const runtime = @import("runtime.zig");
const binary_fuse = @import("pipeline/binary_fuse.zig");
const hash = @import("pipeline/hash.zig");
const stopwords = @import("pipeline/stopwords.zig");

// ── Golden corpus (5 documents, Korean+English mixed) ──
//
// doc 0: title="Hello World", body="hello world programming chaza"
//   tokens: hello, world, programming, chaza
// doc 1: title="Zig Programming", body="zig wasm fast chaza"
//   tokens: zig, programming, wasm, fast, chaza
// doc 2: title="안녕하세요", body="안녕하세요 친구 한글 chaza"
//   tokens: 안녕하세요, 친구, 한글, chaza
//   choseong: ㅇ ㅇㄴ ㅇㄴㅎ (안녕하세요), ㅊ ㅊㄱ (친구), ㅎ ㅎㄱ (한글)
// doc 3: title="Hello 안녕", body="hello 안녕 world chaza"
//   tokens: hello, 안녕, world, chaza
//   choseong: ㅇ ㅇㄴ (안녕)
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

// Expected tokens per document (after stopwords removal·deduplication, excluding choseong tokens)
const DocTokens = struct { doc_id: u32, tokens: []const []const u8 };
const golden_doc_tokens = [_]DocTokens{
    .{ .doc_id = 0, .tokens = &.{ "hello", "world", "programming", "chaza" } },
    .{ .doc_id = 1, .tokens = &.{ "zig", "programming", "wasm", "fast", "chaza" } },
    .{ .doc_id = 2, .tokens = &.{ "안녕하세요", "친구", "한글", "chaza" } },
    .{ .doc_id = 3, .tokens = &.{ "hello", "안녕", "world", "chaza" } },
    .{ .doc_id = 4, .tokens = &.{ "empty", "body", "chaza" } },
};

// ── Helpers ──

fn resultCount(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

fn resultDocId(ptr: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, ptr[4 + i * 8 ..][0..4], .little);
}

fn resultHits(ptr: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, ptr[8 + i * 8 ..][0..4], .little);
}

/// Check if result set contains doc_id.
fn resultContains(ptr: [*]const u8, count: u32, doc_id: u32) bool {
    for (0..count) |i| {
        if (resultDocId(ptr, i) == doc_id) return true;
    }
    return false;
}

/// Build bundle from golden corpus. caller free bundle_bytes.
fn buildGolden(allocator: std.mem.Allocator) !generator.GenerateResult {
    return generator.generate(allocator, GOLDEN_JSON, &.{}, GOLDEN_OPTS);
}

// ── A. Deterministic index generation ──

test "golden determinism: same input twice → identical index bytes" {
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

test "golden determinism: different choseong_max_len → different index bytes" {
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
    // Filter fingerprint pattern differs due to choseong token presence
    try std.testing.expect(!std.mem.eql(u8, v_on.index, v_off.index));
}

test "golden determinism: stopword added → different index bytes" {
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
    // hello removed → filter fingerprint pattern different
    try std.testing.expect(!std.mem.eql(u8, v_sw.index, v_no.index));
}

// ── A2. Golden bytes hash regression ──

/// xxhash64 of the golden corpus index bytes, pinned at commit time.
/// The determinism tests above only compare two runs of the same build —
/// this constant catches unintended output drift BETWEEN commits
/// (format, tokenization, prefix/choseong generation, filter construction).
/// Update only for intentional pipeline/format changes.
const GOLDEN_INDEX_XXH64: u64 = 0x3474f037bf512abf;

test "golden hash: index bytes match pinned xxhash64" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const h = std.hash.XxHash64.hash(0, view.index);
    try std.testing.expectEqual(GOLDEN_INDEX_XXH64, h);
}

// ── B. Build-query tokenization consistency ──

test "golden consistency: all indexed tokens exist in corresponding document filter" {
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

test "golden match: search('hello') → only documents with token hit (docs 0, 3)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "golden match: search('hello') → documents without token miss (docs 1, 2, 4)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello";
    const r = runtime.search(q.ptr, q.len, 0);
    const count = resultCount(r);

    try std.testing.expect(!resultContains(r, count, 1));
    try std.testing.expect(!resultContains(r, count, 2));
    try std.testing.expect(!resultContains(r, count, 4));
}

// ── C. Representative golden corpus cases ──

test "golden: search('안녕') → doc 3 (exact) + doc 2 (title prefix of 안녕하세요)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    // 안녕 exact hits doc 3. As the last (typed) token it also probes \x02안녕,
    // which doc 2 carries from its title word 안녕하세요 (prefix_fields=title).
    const q = "안녕";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "golden prefix: search('hel') → title-word prefix hits docs 0, 3" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    // 'hel' exact matches nothing; prefix \x02hel comes from titles containing
    // 'Hello' (docs 0, 3). doc 1's body has no prefix tokens (body ∉ prefix_fields).
    const q = "hel";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "golden prefix: body words get no prefix tokens ('progr' → no hits)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    // 'programming' exists in doc 0/1 bodies and doc 1 title.
    // 'progr' (5cp) probes \x02progr — generated only from title words:
    // doc 1 title 'Zig Programming' → \x02progr exists → doc 1 hit.
    // doc 0 has 'programming' only in body → no prefix token → miss.
    const q = "progr";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(r));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 0));
}

test "golden: search('ㅎ') → doc 2 only hit (ㅎ choseong starting word 한글)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "ㅎ";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(r));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(r, 0));
}

test "golden: search('hello world') → docs 0, 3 hit (both tokens, tie → input order)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello world";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "golden: empty query → count=0" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

test "golden: non-existent token → count=0" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "zzznonexistentzzz";
    const r = runtime.search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

// ── D. Ranking and limiting ──

test "golden ranking: 'hello programming' → doc 0 (2 hits) first, then partial matches (1, 3)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello programming";
    const r = runtime.search(q.ptr, q.len, 0);

    // doc 0: hello+programming (hits 2). doc 1: programming (1). doc 3: hello (1).
    try std.testing.expectEqual(@as(u32, 3), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 1));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 2));
    try std.testing.expectEqual(@as(u32, 2), resultHits(r, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r, 1));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r, 2));
}

test "golden ranking: unknown token doesn't kill partial matches ('hello zzznonexistentzzz')" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "hello zzznonexistentzzz";
    const r = runtime.search(q.ptr, q.len, 0);

    // 'hello' docs (0, 3) survive with hits 1 — the unknown token no longer zeroes results
    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(r, 1));
}

test "golden: max_results=2 → return max 2 (top-ranked first)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    runtime.set_index(view.index.ptr, view.index.len);
    defer runtime.testCleanup();

    const q = "chaza";
    const r = runtime.search(q.ptr, q.len, 2);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    // All docs hits 1 → input order: docs 0, 1
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(r, 1));
}