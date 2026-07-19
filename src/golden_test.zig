//! chaza golden test — SPEC v1.1 (generator·runtime tokenization·hash consistency).
//!
//! Core verification:
//! 1. Generator determinism: same input → same index bytes.
//! 2. Build-query tokenization consistency: tokens tokenized at index time match at search time.
//! 3. Representative case end-to-end regression (Korean·English·choseong·OR ranking·limit).

const std = @import("std");
const generator = @import("generator.zig");
const wasm_patch = @import("wasm_patch.zig");
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
//   choseong (title ㅇ kept; body ㅊ ㅎ skipped at len 1):
//     ㅇ (title) ㅇㄴ ㅇㄴㅎ (안녕하세요), ㅊㄱ (친구), ㅎㄱ (한글)
// doc 3: title="Hello 안녕", body="hello 안녕 world chaza"
//   tokens: hello, 안녕, world, chaza
//   choseong: ㅇ (title) ㅇㄴ (안녕)
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

/// Golden corpus has 2 meta fields (author, date).
const NUM_META: u32 = 2;

fn resultCount(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

/// Walk to the i-th result entry offset.
/// Each entry: [u32 hits][title\0][url\0][meta\0 × num_meta].
fn nthEntryOff(ptr: [*]const u8, i: usize) usize {
    var off: usize = 4; // skip count
    for (0..i) |_| {
        off += 4; // hits
        const num_strings = 2 + NUM_META; // title, url, meta*N
        for (0..num_strings) |_| {
            while (ptr[off] != 0) off += 1;
            off += 1; // skip NUL
        }
    }
    return off;
}

fn resultTitle(ptr: [*]const u8, i: usize) []const u8 {
    var off = nthEntryOff(ptr, i) + 4; // skip hits
    const start = off;
    while (ptr[off] != 0) off += 1;
    return ptr[start..off];
}

fn resultHits(ptr: [*]const u8, i: usize) u32 {
    const off = nthEntryOff(ptr, i);
    return std.mem.readInt(u32, ptr[off..][0..4], .little);
}

/// Check if result set contains a title.
fn resultContains(ptr: [*]const u8, count: u32, title: []const u8) bool {
    for (0..count) |i| {
        if (std.mem.eql(u8, resultTitle(ptr, i), title)) return true;
    }
    return false;
}

/// Build patched wasm from golden corpus. caller free wasm_bytes.
fn buildGolden(allocator: std.mem.Allocator) !generator.GenerateResult {
    return generator.generate(allocator, GOLDEN_JSON, &wasm_patch.test_minimal_wasm, GOLDEN_OPTS);
}

// ── A. Deterministic index generation ──

test "golden determinism: same input twice → identical index bytes" {
    const allocator = std.testing.allocator;
    const r1 = try buildGolden(allocator);
    defer allocator.free(r1.wasm_bytes);
    const r2 = try buildGolden(allocator);
    defer allocator.free(r2.wasm_bytes);

    try std.testing.expectEqual(r1.index_size, r2.index_size);

    const idx1 = try wasm_patch.extractIndex(allocator, r1.wasm_bytes);
    defer allocator.free(idx1);
    const idx2 = try wasm_patch.extractIndex(allocator, r2.wasm_bytes);
    defer allocator.free(idx2);
    try std.testing.expectEqualSlices(u8, idx1, idx2);
}

test "golden determinism: different choseong_max_len → different index bytes" {
    const allocator = std.testing.allocator;

    const r_off = try generator.generate(allocator, GOLDEN_JSON, &wasm_patch.test_minimal_wasm, .{
        .indexed_fields = &.{ "title", "body" },
        .metadata_fields = &.{ "author", "date" },
        .choseong_max_len = 0,
    });
    defer allocator.free(r_off.wasm_bytes);

    const r_on = try buildGolden(allocator);
    defer allocator.free(r_on.wasm_bytes);

    const i_off = try wasm_patch.extractIndex(allocator, r_off.wasm_bytes);
    defer allocator.free(i_off);
    const i_on = try wasm_patch.extractIndex(allocator, r_on.wasm_bytes);
    defer allocator.free(i_on);
    // Filter fingerprint pattern differs due to choseong token presence
    try std.testing.expect(!std.mem.eql(u8, i_on, i_off));
}

test "golden determinism: stopword added → different index bytes" {
    const allocator = std.testing.allocator;
    var sw = try stopwords.StopwordSet.fromFileBytes(allocator, "hello\n");
    defer sw.deinit(allocator);

    const r_sw = try generator.generate(allocator, GOLDEN_JSON, &wasm_patch.test_minimal_wasm, .{
        .indexed_fields = &.{ "title", "body" },
        .metadata_fields = &.{ "author", "date" },
        .choseong_max_len = 3,
        .stopwords = sw,
    });
    defer allocator.free(r_sw.wasm_bytes);

    const r_no = try buildGolden(allocator);
    defer allocator.free(r_no.wasm_bytes);

    const i_sw = try wasm_patch.extractIndex(allocator, r_sw.wasm_bytes);
    defer allocator.free(i_sw);
    const i_no = try wasm_patch.extractIndex(allocator, r_no.wasm_bytes);
    defer allocator.free(i_no);
    // hello removed → filter fingerprint pattern different
    try std.testing.expect(!std.mem.eql(u8, i_sw, i_no));
}

// ── A2. Golden bytes hash regression ──

/// xxhash64 of the golden corpus index bytes, pinned at commit time.
/// The determinism tests above only compare two runs of the same build —
/// this constant catches unintended output drift BETWEEN commits
/// (format, tokenization, prefix/choseong generation, filter construction).
/// Update only for intentional pipeline/format changes.
// Updated 2026-07: v1.4 format v3 — global lo(9-bit)/hi(16-bit) filters, pairKey(doc_id, token).
// Updated 2026-07: body single-jamo choseong skipped (writer min_len=2), title keeps length-1.
const GOLDEN_INDEX_XXH64: u64 = 0x48F8E3718FB7E6F1;

test "golden hash: index bytes match pinned xxhash64" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    const h = std.hash.XxHash64.hash(0, index);
    try std.testing.expectEqual(GOLDEN_INDEX_XXH64, h);
}

// ── B. Build-query tokenization consistency ──

test "golden consistency: all indexed tokens exist in the global lo filter for their document" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    const idx = try reader.IndexView.open(index);
    const fuse = binary_fuse.BinaryFuseView.fromBlob(idx.loFilter().?) orelse return error.UnexpectedNull;

    for (golden_doc_tokens) |dt| {
        for (dt.tokens) |tok| {
            try std.testing.expect(fuse.contains(hash.pairKey(hash.key64(tok), dt.doc_id)));
        }
    }
}

test "golden match: search('hello') → only documents with token hit (docs 0, 3)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "hello";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqualStrings("Hello World", resultTitle(r, 0));
    try std.testing.expectEqualStrings("Hello 안녕", resultTitle(r, 1));
}

test "golden match: search('hello') → documents without token miss (docs 1, 2, 4)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "hello";
    const r = runtime.doSearch(q, 0);
    const count = resultCount(r);

    try std.testing.expect(!resultContains(r, count, "Zig Programming"));
    try std.testing.expect(!resultContains(r, count, "안녕하세요"));
    try std.testing.expect(!resultContains(r, count, "Empty Body"));
}

// ── C. Representative golden corpus cases ──

test "golden: search('안녕') → doc 3 (exact) + doc 2 (title prefix of 안녕하세요)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    // 안녕 exact hits doc 3 — and its title contains 안녕, so the 0x03 title
    // probe ranks it first. The prefix probe \x02안녕 also pulls in doc 2
    // (title word 안녕하세요, prefix_fields=title) with no title_hits.
    // Count is not asserted exactly: filter false positives may add a doc.
    const q = "안녕";
    const r = runtime.doSearch(q, 0);
    const count = resultCount(r);

    try std.testing.expect(count >= 2);
    try std.testing.expectEqualStrings("Hello 안녕", resultTitle(r, 0)); // title match first
    try std.testing.expect(resultContains(r, count, "안녕하세요"));
}

test "golden prefix: search('hel') → title-word prefix hits docs 0, 3" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    // 'hel' exact matches nothing; prefix \x02hel comes from titles containing
    // 'Hello' (docs 0, 3). doc 1's body has no prefix tokens (body ∉ prefix_fields).
    const q = "hel";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqualStrings("Hello World", resultTitle(r, 0));
    try std.testing.expectEqualStrings("Hello 안녕", resultTitle(r, 1));
}

test "golden prefix: body words get no prefix tokens ('progr' → no hits)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    // 'programming' exists in doc 0/1 bodies and doc 1 title.
    // 'progr' (5cp) probes \x02progr — generated only from title words:
    // doc 1 title 'Zig Programming' → \x02progr exists → doc 1 hit.
    // doc 0 has 'programming' only in body → no prefix token → miss.
    const q = "progr";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(r));
    try std.testing.expectEqualStrings("Zig Programming", resultTitle(r, 0));
}

test "golden: search('ㅎ') → no hit (body-only single-jamo choseong skipped)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    // '한글' is body-only in doc 2; single-jamo choseong (\x01ㅎ) is not
    // generated for body tokens (writer min_len=2). 'ㅎ' → 0 results.
    const q = "ㅎ";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

test "golden: search('ㅇ') → docs 2, 3 hit (title single-jamo choseong preserved)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    // '안녕하세요' is a title word in doc 2; '안녕' is a title word in doc 3.
    // Title tokens keep length-1 choseong (\x01ㅇ) from the generator.
    const q = "ㅇ";
    const r = runtime.doSearch(q, 0);
    const count = resultCount(r);

    try std.testing.expect(count >= 2);
    try std.testing.expect(resultContains(r, count, "안녕하세요"));
    try std.testing.expect(resultContains(r, count, "Hello 안녕"));
}

test "golden: search('hello world') → docs 0, 3 hit (both tokens, tie → input order)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "hello world";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqualStrings("Hello World", resultTitle(r, 0));
    try std.testing.expectEqualStrings("Hello 안녕", resultTitle(r, 1));
}

test "golden: empty query → count=0" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

test "golden: non-existent token → count=0" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "zzznonexistentzzz";
    const r = runtime.doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(r));
}

// ── D. Ranking and limiting ──

test "golden ranking: 'hello programming' → doc 0 (2 hits) first, then partial matches (1, 3)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "hello programming";
    const r = runtime.doSearch(q, 0);

    // doc 0: hello+programming (hits 2). doc 1: programming (1). doc 3: hello (1).
    try std.testing.expectEqual(@as(u32, 3), resultCount(r));
    try std.testing.expectEqualStrings("Hello World", resultTitle(r, 0));
    try std.testing.expectEqualStrings("Zig Programming", resultTitle(r, 1));
    try std.testing.expectEqualStrings("Hello 안녕", resultTitle(r, 2));
    try std.testing.expectEqual(@as(u32, 2), resultHits(r, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r, 1));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r, 2));
}

test "golden ranking: unknown token doesn't kill partial matches ('hello zzznonexistentzzz')" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "hello zzznonexistentzzz";
    const r = runtime.doSearch(q, 0);

    // 'hello' docs (0, 3) survive with hits 1 — the unknown token no longer zeroes results
    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    try std.testing.expectEqualStrings("Hello World", resultTitle(r, 0));
    try std.testing.expectEqualStrings("Hello 안녕", resultTitle(r, 1));
}

test "golden: max_results=2 → return max 2 (top-ranked first)" {
    const allocator = std.testing.allocator;
    const result = try buildGolden(allocator);
    defer allocator.free(result.wasm_bytes);

    const index = try wasm_patch.extractIndex(allocator, result.wasm_bytes);
    defer allocator.free(index);
    runtime.set_index(index.ptr, index.len);
    defer runtime.testCleanup();

    const q = "chaza";
    const r = runtime.doSearch(q, 2);

    try std.testing.expectEqual(@as(u32, 2), resultCount(r));
    // All docs hits 1 → input order: docs 0, 1
    try std.testing.expectEqualStrings("Hello World", resultTitle(r, 0));
    try std.testing.expectEqualStrings("Zig Programming", resultTitle(r, 1));
}