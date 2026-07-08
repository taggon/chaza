//! chaza runtime: WASM export API — in-memory search.
//!
//! For index bytes registered in global IndexView:
//! query tokenization → each doc BinaryFuse8 filter OR lookup (hits = hit token count)
//! → hits descending sort (tie: input order) → result encoding.
//! Results written to global buffer in [u32 count LE][(u32 doc_id, u32 hits) × count LE] format.

const std = @import("std");
const reader = @import("index/reader.zig");
const writer = @import("index/writer.zig");
const binary_fuse = @import("pipeline/binary_fuse.zig");
const hash = @import("pipeline/hash.zig");
const tokenize = @import("pipeline/tokenize.zig");
const choseong = @import("pipeline/choseong.zig");
const prefix = @import("pipeline/prefix.zig");

// ── Global state ──

var g_index: ?reader.IndexView = null;
var g_result_buffer: std.ArrayList(u8) = .empty;
const g_allocator: std.mem.Allocator = std.heap.page_allocator;

/// Static empty result on alloc failure (count=0 LE).
const empty_result: [4]u8 = .{ 0, 0, 0, 0 };

// ── export API ──
//
// callconv(.c) — wasm32 uses wasm-compatible C calling convention. @export exposes symbol.

/// JS memory allocation request. Secure n bytes with page_allocator and return pointer.
pub fn alloc(n: usize) callconv(.c) [*]u8 {
    const buf = g_allocator.alloc(u8, n) catch @panic("chaza: alloc failed");
    return buf.ptr;
}

/// Register index bytes. After set_index, memory grow prohibited (pointer invalidation).
pub fn set_index(ptr: [*]const u8, len: usize) callconv(.c) void {
    const bytes = ptr[0..len];
    g_index = reader.IndexView.open(bytes) catch {
        g_index = null;
        return;
    };
}

/// Max query tokens considered per search; tokens beyond this are ignored.
/// Caps hits at 16 (documented range 0~16). Bounds both false-positive noise
/// (OR lookup: each extra token adds ~0.4% per-doc FP chance) and per-search work.
/// hits stays u32 in the result buffer, so the cap can never overflow the encoding.
const max_query_tokens = 16;

/// Execute search. Return result buffer pointer ([u32 count LE][(u32 doc_id, u32 hits) × count LE]).
pub fn search(
    query_ptr: [*]const u8,
    query_len: usize,
    max_results: u32,
) callconv(.c) [*]const u8 {
    const view = g_index orelse return writeEmptyResult();

    // arena: tokenize memory all freed at search end
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Query tokenization
    var tokens: std.ArrayList([]const u8) = .empty;
    tokenize.tokenize(arena_alloc, query_ptr[0..query_len], &tokens) catch return writeEmptyResult();

    // Choseong query processing: add marker to tokens composed only of choseong jamo
    choseong.markChoseongQueries(arena_alloc, &tokens) catch return writeEmptyResult();

    // Empty query → no results
    if (tokens.items.len == 0) return writeEmptyResult();

    // Cap query tokens (hits upper bound = 16)
    if (tokens.items.len > max_query_tokens) tokens.items.len = max_query_tokens;

    // Prefix probe for the last token (the word being typed): its filter
    // lookup also tries the 0x02-marked prefix token. null when a prefix
    // match is impossible (choseong query, length outside 2~8).
    const last_prefix_key: ?u64 = blk: {
        const last = tokens.items[tokens.items.len - 1];
        const pt = prefix.makeQueryPrefixToken(arena_alloc, last) catch break :blk null;
        break :blk if (pt) |p| hash.key64(p) else null;
    };

    // Collect hit documents (OR: hits = hit token count, ≥1 is candidate)
    var candidates: std.ArrayList(ScoredDoc) = .empty;
    defer candidates.deinit(g_allocator);

    var doc_id: u32 = 0;
    while (doc_id < view.header.num_docs) : (doc_id += 1) {
        const hits = countHitTokens(view, doc_id, tokens.items, last_prefix_key);
        if (hits > 0) {
            candidates.append(g_allocator, .{ .doc_id = doc_id, .hits = hits }) catch return writeEmptyResult();
        }
    }

    // Ranking: hits descending, tie → input order (doc_id ascending)
    std.sort.pdq(ScoredDoc, candidates.items, {}, hitsDescThenDocIdAsc);

    // Truncate
    const effective_max: usize = if (max_results == 0) 20 else @intCast(max_results);
    const count: usize = @min(candidates.items.len, effective_max);

    // Result encoding: [u32 count LE][(u32 doc_id, u32 hits) × count LE]
    g_result_buffer.clearRetainingCapacity();
    appendU32LE(&g_result_buffer, @intCast(count)) catch return @ptrCast(&empty_result);
    for (0..count) |i| {
        appendU32LE(&g_result_buffer, candidates.items[i].doc_id) catch return @ptrCast(&empty_result);
        appendU32LE(&g_result_buffer, candidates.items[i].hits) catch return @ptrCast(&empty_result);
    }

    return g_result_buffer.items.ptr;
}

// ── Internal functions ──

/// Candidate document with its hit token count.
const ScoredDoc = struct {
    doc_id: u32,
    hits: u32,
};

/// Ranking order: hits descending, tie → doc_id ascending (input order).
fn hitsDescThenDocIdAsc(_: void, a: ScoredDoc, b: ScoredDoc) bool {
    if (a.hits != b.hits) return a.hits > b.hits;
    return a.doc_id < b.doc_id;
}

/// Count tokens hit in document's BinaryFuse8 filter (OR hits).
/// The last token also matches via its prefix token (last_prefix_key) —
/// exact-or-prefix counts as one hit.
fn countHitTokens(
    view: reader.IndexView,
    doc_id: u32,
    tokens: []const []const u8,
    last_prefix_key: ?u64,
) u32 {
    const filter_bytes = view.docFilter(doc_id) orelse return 0;
    if (filter_bytes.len == 0) return 0;
    const fuse = binary_fuse.BinaryFuse8View.fromBlob(filter_bytes) orelse return 0;
    var hits: u32 = 0;
    for (tokens, 0..) |tok, i| {
        var hit = fuse.contains(hash.key64(tok));
        if (!hit and i == tokens.len - 1) {
            if (last_prefix_key) |pk| hit = fuse.contains(pk);
        }
        if (hit) hits += 1;
    }
    return hits;
}

/// Append u32 little-endian to result buffer.
fn appendU32LE(buf: *std.ArrayList(u8), val: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, val, .little);
    try buf.appendSlice(g_allocator, &tmp);
}

/// Write empty result (count=0) to g_result_buffer and return pointer.
fn writeEmptyResult() [*]const u8 {
    g_result_buffer.clearRetainingCapacity();
    appendU32LE(&g_result_buffer, 0) catch return @ptrCast(&empty_result);
    return g_result_buffer.items.ptr;
}

// ── Assertion tests ────────────────────────────────────────────────────

const DocInput = writer.DocInput;
const IndexInput = writer.IndexInput;

/// Build test corpus of 4 documents. caller free.
fn buildCorpus(allocator: std.mem.Allocator) ![]u8 {
    const docs = [_]DocInput{
        // doc 0 carries edge n-gram prefix tokens for "world" (as the generator
        // would emit for a prefix field) to exercise last-token prefix matching.
        .{ .tokens = &.{ "hello", "world", "\x02wo", "\x02wor", "\x02worl" }, .title = "Hello World", .url = "/hello", .meta_values = &.{"2026-03-15"} },
        .{ .tokens = &.{ "hello", "zig" }, .title = "Hello Zig", .url = "/zig", .meta_values = &.{"2026-01-10"} },
        .{ .tokens = &.{ "hello", "wasm" }, .title = "Hello WASM", .url = "/wasm", .meta_values = &.{"2026-02-20"} },
        .{ .tokens = &.{ "안녕", "hello" }, .title = "안녕 Hello", .url = "/kor", .meta_values = &.{"2026-04-05"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"date"},
        .docs = &docs,
        .choseong_max_len = 3,
    };
    return writer.write(allocator, input);
}

/// Read count from result buffer.
fn resultCount(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

/// Read i-th doc_id from result buffer ((doc_id, hits) pair stride 8).
fn resultDocId(ptr: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, ptr[4 + i * 8 ..][0..4], .little);
}

/// Read i-th hits from result buffer.
fn resultHits(ptr: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, ptr[8 + i * 8 ..][0..4], .little);
}

/// Test cleanup: release g_index + clear result buffer.
pub fn testCleanup() void {
    g_index = null;
    g_result_buffer.clearRetainingCapacity();
}

test "Single token 'hello' → 4 docs hit (input order)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 3));
}

test "Non-existent token → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "zzznonexistentzzz";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Multiple tokens OR ranking: 'hello zig' → doc 1 (2 hits) first, rest input order" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zig";
    const result = search(q.ptr, q.len, 0);

    // doc 1 hits both tokens (hits 2) → first. docs 0/2/3 hit only 'hello' (hits 1) → input order.
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 3));
    try std.testing.expectEqual(@as(u32, 2), resultHits(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 1));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 2));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 3));
}

test "Multiple tokens OR: 'hello nonexistent' → partial matches still returned" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zzznonexistentzzz";
    const result = search(q.ptr, q.len, 0);

    // all 4 docs hit 'hello' (hits 1) → input order
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 0));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 3));
}

test "max_results=1 → return 1 only (top-ranked)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zig";
    const result = search(q.ptr, q.len, 1);

    // ranking → truncate: top-ranked doc 1 (hits 2) survives the cut
    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 2), resultHits(result, 0));
}

test "max_results=0 → default 20 (return all)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0);

    // 4 doc corpus → all 4 returned (default 20 > 4)
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
}

test "Query token cap: 17th token ignored (hits ≤ 16)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // 'hello' ×16 + 'world' as the 17th token. All tokens are known (no FP flakiness):
    // every doc contains 'hello' → hits 16 each. Without the cap doc 0 would score 17
    // via 'world'.
    var q_buf: std.ArrayList(u8) = .empty;
    defer q_buf.deinit(allocator);
    for (0..16) |_| {
        try q_buf.appendSlice(allocator, "hello ");
    }
    try q_buf.appendSlice(allocator, "world");

    const result = search(q_buf.items.ptr, q_buf.items.len, 0);
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    // doc 0 first only by input-order tie — its 'world' hit was dropped by the cap
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 16), resultHits(result, 0));
    try std.testing.expectEqual(@as(u32, 16), resultHits(result, 1));
}

test "Result buffer format: first 4 bytes LE u32 count + (doc_id, hits) pairs" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "world";
    const result = search(q.ptr, q.len, 0);

    // "world" only in doc 0
    const count = std.mem.readInt(u32, result[0..4], .little);
    try std.testing.expectEqual(@as(u32, 1), count);

    const id = std.mem.readInt(u32, result[4..8], .little);
    try std.testing.expectEqual(@as(u32, 0), id);

    const hits = std.mem.readInt(u32, result[8..12], .little);
    try std.testing.expectEqual(@as(u32, 1), hits);
}

test "Korean token '안녕' search" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "안녕";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "Choseong query 'ㅇ' → 안녕 doc (doc 3) hit" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㅇ";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "Choseong query 'ㅇㄴ' → 안녕 doc (doc 3) hit (2-char prefix match)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㅇㄴ";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "Choseong query 'ㄱ' → miss (안녕 starts with ㅇ, not ㄱ)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㄱ";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Choseong query doesn't match normal Korean: 'ㅇ' ≠ '안녕' token" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // 'ㅇ' choseong query converted to 0x01ㅇ marker token → different from original '안녕' token
    // but since choseong token 0x01ㅇ exists in filter, doc 3 hit
    const q = "ㅇ";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "English query 'hello' unaffected by choseong" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
}

test "Prefix match: query 'worl' → doc 0 via \\x02worl prefix token" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "worl";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 0));
}

test "Prefix probe applies to last token only" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // 'worl' last → doc 0 gets hello(exact) + worl(prefix) = hits 2, first
    const q1 = "hello worl";
    const r1 = search(q1.ptr, q1.len, 0);
    try std.testing.expectEqual(@as(u32, 4), resultCount(r1));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(r1, 0));
    try std.testing.expectEqual(@as(u32, 2), resultHits(r1, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r1, 1));

    // 'worl' not last → no prefix probe, every doc hits only 'hello' (hits 1)
    const q2 = "worl hello";
    const r2 = search(q2.ptr, q2.len, 0);
    try std.testing.expectEqual(@as(u32, 4), resultCount(r2));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r2, 0));
}

test "g_index not set → search → count=0" {
    g_index = null;
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Empty query → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "";
    const result = search(q.ptr, q.len, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "set_index: invalid magic → g_index=null, search → count=0" {
    var bad_bytes: [64]u8 = .{0} ** 64;
    set_index(&bad_bytes, bad_bytes.len);
    defer testCleanup();

    try std.testing.expect(g_index == null);

    const q = "test";
    const result = search(q.ptr, q.len, 0);
    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

// ── wasm export forced (avoid lazy compilation) ──
comptime {
    @export(&alloc, .{ .name = "alloc" });
    @export(&set_index, .{ .name = "set_index" });
    @export(&search, .{ .name = "search" });
}