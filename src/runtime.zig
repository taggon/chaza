//! chaza runtime: WASM export API — in-memory search.
//!
//! For index bytes registered in global IndexView:
//! query tokenization → per document, probe the corpus-global lo filter with
//! pairKey(doc_id, token key) (OR lookup; hits = hit token count) plus the hi
//! filter for prefix (0x02) and title-ranking (0x03) probes → sort by hits
//! desc, title_hits desc, input order → result encoding.
//!
//! Result buffer format (NUL-separated, wasm materializes all strings):
//!   [u32 count LE]
//!   per result:
//!     [u32 hits LE]
//!     title\0 url\0 meta_value_1\0 ... meta_value_N\0

const std = @import("std");
const reader = @import("index/reader.zig");
const writer = @import("index/writer.zig");
const binary_fuse = @import("pipeline/binary_fuse.zig");
const hash = @import("pipeline/hash.zig");
const tokenize = @import("pipeline/tokenize.zig");
const choseong = @import("pipeline/choseong.zig");
const prefix = @import("pipeline/prefix.zig");
const format = @import("index/format.zig");

// ── Global state ──

var g_index: ?reader.IndexView = null;
var g_result_buffer: std.ArrayList(u8) = .empty;
var g_query_buffer: std.ArrayList(u8) = .empty;
var g_meta_names_buf: std.ArrayList(u8) = .empty;
const g_allocator: std.mem.Allocator = std.heap.page_allocator;

/// Static empty result on alloc failure (count=0 LE).
const empty_result: [4]u8 = .{ 0, 0, 0, 0 };

/// Embedded index metadata slot. The wasm patcher writes an active data
/// segment at this address carrying (ptr, len) of the embedded index, so
/// the runtime self-initializes without a JS-facing set_index call.
/// The slot is initialized to a sentinel pattern (0xFEEDFACE × 2); the
/// patcher scans the data section for this pattern to discover the slot
/// address at build time, then overwrites it with the real values.
const EmbeddedIndexMeta = extern struct {
    ptr: u32,
    len: u32,
};

const META_SENTINEL: u32 = 0xFEEDFACE;

var g_embedded_index: EmbeddedIndexMeta align(4) = .{
    .ptr = META_SENTINEL,
    .len = META_SENTINEL,
};

/// Lazily open the IndexView from the embedded metadata. Returns the cached
/// view if already open (via set_index in tests or a prior call).
///
/// The slot is read via a volatile pointer because the compiler sees no
/// writes to g_embedded_index in the wasm build (the patcher's data segment
/// overwrites it at instantiation time, which is invisible to the compiler).
/// Without volatile the optimizer would constant-fold the sentinel check
/// to always-true and eliminate the slot from the data section entirely.
fn ensureIndex() ?reader.IndexView {
    if (g_index == null) {
        const slot: *volatile EmbeddedIndexMeta = @ptrCast(&g_embedded_index);
        if (slot.ptr == META_SENTINEL or slot.len == META_SENTINEL) return null;
        const ptr: [*]const u8 = @ptrFromInt(slot.ptr);
        g_index = reader.IndexView.open(ptr[0..slot.len]) catch null;
    }
    return g_index;
}

// ── export API ──
//
// callconv(.c) — wasm32 uses wasm-compatible C calling convention. @export exposes symbol.

/// Ensure the query buffer can hold `len` bytes and return a writable pointer.
/// The runtime owns the buffer (resized in place, reused across calls), so JS
/// no longer manages query allocation policy.
pub fn prepareQuery(len: usize) callconv(.c) [*]u8 {
    g_query_buffer.resize(g_allocator, len) catch @panic("chaza: query allocation failed");
    return g_query_buffer.items.ptr;
}

/// Return a pointer to the index info buffer:
///   [u32 num_docs LE][u32 num_meta_fields LE][name1\0 name2\0 ...]
/// JS reads this once at load time for the document count and meta field
/// schema. The buffer is built lazily on first call and cached.
pub fn metaFields() callconv(.c) [*]const u8 {
    if (g_meta_names_buf.items.len > 0) return g_meta_names_buf.items.ptr;

    const view = ensureIndex() orelse {
        appendU32LE(&g_meta_names_buf, 0) catch {};
        appendU32LE(&g_meta_names_buf, 0) catch {};
        return g_meta_names_buf.items.ptr;
    };

    appendU32LE(&g_meta_names_buf, view.header.num_docs) catch {
        g_meta_names_buf.clearRetainingCapacity();
        appendU32LE(&g_meta_names_buf, 0) catch {};
        appendU32LE(&g_meta_names_buf, 0) catch {};
        return g_meta_names_buf.items.ptr;
    };
    appendU32LE(&g_meta_names_buf, view.header.num_meta_fields) catch {
        g_meta_names_buf.clearRetainingCapacity();
        appendU32LE(&g_meta_names_buf, 0) catch {};
        appendU32LE(&g_meta_names_buf, 0) catch {};
        return g_meta_names_buf.items.ptr;
    };
    for (0..view.header.num_meta_fields) |i| {
        const name = view.metaNameAt(i) orelse "";
        appendStringNul(&g_meta_names_buf, name) catch break;
    }
    return g_meta_names_buf.items.ptr;
}

/// Register index bytes directly (test helper — not exported to wasm).
pub fn set_index(ptr: [*]const u8, len: usize) void {
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
    query_len: usize,
    max_results: u32,
) callconv(.c) [*]const u8 {
    const view = ensureIndex() orelse return writeEmptyResult();

    // arena: tokenize memory all freed at search end
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // Query bytes come from the runtime-owned query buffer
    const query_bytes = g_query_buffer.items[0..query_len];

    // Query tokenization
    var tokens: std.ArrayList([]const u8) = .empty;
    tokenize.tokenize(arena_alloc, query_bytes, &tokens) catch return writeEmptyResult();

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

    // Precompute per-token keys once: exact + 0x03 title probe (ranking signal)
    const keys = arena_alloc.alloc(TokenKeys, tokens.items.len) catch return writeEmptyResult();
    for (tokens.items, 0..) |tok, i| {
        const marked = arena_alloc.alloc(u8, tok.len + 1) catch return writeEmptyResult();
        marked[0] = format.TITLE_MARKER;
        @memcpy(marked[1..], tok);
        keys[i] = .{ .exact = hash.key64(tok), .title = hash.key64(marked) };
    }

    // Global filter views — parsed once per search, probed per (token, doc)
    const lo_fuse = binary_fuse.BinaryFuseView.fromBlob(view.loFilter() orelse return writeEmptyResult()) orelse return writeEmptyResult();
    const hi_fuse = binary_fuse.BinaryFuseView.fromBlob(view.hiFilter() orelse return writeEmptyResult()) orelse return writeEmptyResult();

    // Collect hit documents (OR: hits = hit token count, ≥1 is candidate)
    var candidates: std.ArrayList(ScoredDoc) = .empty;
    defer candidates.deinit(g_allocator);

    var doc_id: u32 = 0;
    while (doc_id < view.header.num_docs) : (doc_id += 1) {
        const score = countHitTokens(lo_fuse, hi_fuse, doc_id, keys, last_prefix_key);
        if (score.hits > 0) {
            candidates.append(g_allocator, .{
                .doc_id = doc_id,
                .hits = score.hits,
                .title_hits = score.title_hits,
            }) catch return writeEmptyResult();
        }
    }

    // Ranking: hits desc → title hits desc (title matches beat body-only
    // matches and false positives) → input order (doc_id ascending)
    std.sort.pdq(ScoredDoc, candidates.items, {}, rankLessThan);

    // Truncate
    const effective_max: usize = if (max_results == 0) 20 else @intCast(max_results);
    const count: usize = @min(candidates.items.len, effective_max);

    // Result encoding (NUL-separated, wasm materializes all strings):
    //   [u32 count LE]
    //   per result: [u32 hits LE][title\0][url\0][meta_value\0 × num_meta_fields]
    g_result_buffer.clearRetainingCapacity();
    appendU32LE(&g_result_buffer, @intCast(count)) catch return writeEmptyResult();
    for (0..count) |i| {
        const did = candidates.items[i].doc_id;
        appendU32LE(&g_result_buffer, candidates.items[i].hits) catch return writeEmptyResult();
        appendStringNul(&g_result_buffer, view.title(did) orelse "") catch return writeEmptyResult();
        appendStringNul(&g_result_buffer, view.url(did) orelse "") catch return writeEmptyResult();
        for (0..view.header.num_meta_fields) |j| {
            appendStringNul(&g_result_buffer, view.metaValue(did, j) orelse "") catch return writeEmptyResult();
        }
    }

    return g_result_buffer.items.ptr;
}

// ── Internal functions ──

/// Precomputed filter keys for one query token.
const TokenKeys = struct {
    exact: u64,
    /// key of the 0x03-marked variant — hits when the token appears in the title
    title: u64,
};

/// Per-document match score.
const Score = struct {
    hits: u32,
    title_hits: u32,
};

/// Candidate document with its ranking keys.
const ScoredDoc = struct {
    doc_id: u32,
    hits: u32,
    title_hits: u32,
};

/// Ranking order: hits desc → title_hits desc → doc_id asc (input order).
fn rankLessThan(_: void, a: ScoredDoc, b: ScoredDoc) bool {
    if (a.hits != b.hits) return a.hits > b.hits;
    if (a.title_hits != b.title_hits) return a.title_hits > b.title_hits;
    return a.doc_id < b.doc_id;
}

/// Count tokens hit for one document (OR hits), plus title hits (0x03 probe
/// in the hi filter — ranking-only signal, not part of `hits`). Exact tokens
/// probe the global lo filter; the last token also matches via its prefix
/// token in the hi filter — exact-or-prefix counts as one hit. All probes use
/// pairKey(doc_id, token key).
fn countHitTokens(
    lo_fuse: binary_fuse.BinaryFuseView,
    hi_fuse: binary_fuse.BinaryFuseView,
    doc_id: u32,
    keys: []const TokenKeys,
    last_prefix_key: ?u64,
) Score {
    var score: Score = .{ .hits = 0, .title_hits = 0 };
    for (keys, 0..) |k, i| {
        var hit = lo_fuse.contains(hash.pairKey(k.exact, doc_id));
        if (!hit and i == keys.len - 1) {
            if (last_prefix_key) |pk| hit = hi_fuse.contains(hash.pairKey(pk, doc_id));
        }
        if (hit) {
            score.hits += 1;
            if (hi_fuse.contains(hash.pairKey(k.title, doc_id))) score.title_hits += 1;
        }
    }
    return score;
}

/// Append u32 little-endian to a buffer.
fn appendU32LE(buf: *std.ArrayList(u8), val: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, val, .little);
    try buf.appendSlice(g_allocator, &tmp);
}

/// Append a byte slice followed by a NUL terminator.
fn appendStringNul(buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.appendSlice(g_allocator, s);
    try buf.append(g_allocator, 0);
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

/// buildCorpus has 1 meta field per doc.
const TEST_NUM_META: u32 = 1;

/// Walk to the i-th result entry offset (past count u32 + i variable-length entries).
/// Each entry: [u32 hits][title\0][url\0][meta\0 × num_meta].
fn nthEntryOff(ptr: [*]const u8, i: usize, num_meta: u32) usize {
    var off: usize = 4; // skip count
    for (0..i) |_| {
        off += 4; // hits
        const num_strings = 2 + num_meta; // title, url, meta*N
        for (0..num_strings) |_| {
            while (ptr[off] != 0) off += 1;
            off += 1; // skip NUL
        }
    }
    return off;
}

/// Read i-th title from result buffer (NUL-terminated after hits u32).
fn resultTitle(ptr: [*]const u8, i: usize) []const u8 {
    var off = nthEntryOff(ptr, i, TEST_NUM_META) + 4; // skip hits
    const start = off;
    while (ptr[off] != 0) off += 1;
    return ptr[start..off];
}

/// Read i-th hits from result buffer.
fn resultHits(ptr: [*]const u8, i: usize) u32 {
    const off = nthEntryOff(ptr, i, TEST_NUM_META);
    return std.mem.readInt(u32, ptr[off..][0..4], .little);
}

/// Test cleanup: release g_index + clear buffers.
pub fn testCleanup() void {
    g_index = null;
    g_embedded_index = .{ .ptr = META_SENTINEL, .len = META_SENTINEL };
    g_result_buffer.clearRetainingCapacity();
    g_query_buffer.clearRetainingCapacity();
    g_meta_names_buf.clearRetainingCapacity();
}

/// Test helper: write query into g_query_buffer and run search.
pub fn doSearch(query: []const u8, max_results: u32) [*]const u8 {
    const ptr = prepareQuery(query.len);
    @memcpy(ptr[0..query.len], query);
    return search(query.len, max_results);
}

test "Single token 'hello' → 4 docs hit (input order)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqualStrings("Hello World", resultTitle(result, 0));
    try std.testing.expectEqualStrings("Hello Zig", resultTitle(result, 1));
    try std.testing.expectEqualStrings("Hello WASM", resultTitle(result, 2));
    try std.testing.expectEqualStrings("안녕 Hello", resultTitle(result, 3));
}

test "Non-existent token → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "zzznonexistentzzz";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Multiple tokens OR ranking: 'hello zig' → doc 1 (2 hits) first, rest input order" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zig";
    const result = doSearch(q, 0);

    // doc 1 hits both tokens (hits 2) → first. docs 0/2/3 hit only 'hello' (hits 1) → input order.
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqualStrings("Hello Zig", resultTitle(result, 0));
    try std.testing.expectEqualStrings("Hello World", resultTitle(result, 1));
    try std.testing.expectEqualStrings("Hello WASM", resultTitle(result, 2));
    try std.testing.expectEqualStrings("안녕 Hello", resultTitle(result, 3));
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
    const result = doSearch(q, 0);

    // all 4 docs hit 'hello' (hits 1) → input order
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 0));
    try std.testing.expectEqualStrings("Hello World", resultTitle(result, 0));
    try std.testing.expectEqualStrings("Hello Zig", resultTitle(result, 1));
    try std.testing.expectEqualStrings("Hello WASM", resultTitle(result, 2));
    try std.testing.expectEqualStrings("안녕 Hello", resultTitle(result, 3));
}

test "max_results=1 → return 1 only (top-ranked)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zig";
    const result = doSearch(q, 1);

    // ranking → truncate: top-ranked doc 1 (hits 2) survives the cut
    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqualStrings("Hello Zig", resultTitle(result, 0));
    try std.testing.expectEqual(@as(u32, 2), resultHits(result, 0));
}

test "max_results=0 → default 20 (return all)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = doSearch(q, 0);

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

    const result = doSearch(q_buf.items, 0);
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    // doc 0 first only by input-order tie — its 'world' hit was dropped by the cap
    try std.testing.expectEqualStrings("Hello World", resultTitle(result, 0));
    try std.testing.expectEqual(@as(u32, 16), resultHits(result, 0));
    try std.testing.expectEqual(@as(u32, 16), resultHits(result, 1));
}

test "Result buffer format: count + hits + NUL-separated strings" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "world";
    const result = doSearch(q, 0);

    // "world" only in doc 0 → count=1
    const count = std.mem.readInt(u32, result[0..4], .little);
    try std.testing.expectEqual(@as(u32, 1), count);

    // hits = 1 (only "world" matched)
    const hits = std.mem.readInt(u32, result[4..8], .little);
    try std.testing.expectEqual(@as(u32, 1), hits);

    // title starts at byte 8, NUL-terminated
    try std.testing.expectEqual(@as(u8, 'H'), result[8]);
    const title = std.mem.sliceTo(result[8..], 0);
    try std.testing.expectEqualStrings("Hello World", title);
}

test "Korean token '안녕' search" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "안녕";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqualStrings("안녕 Hello", resultTitle(result, 0));
}

test "Choseong query 'ㅇ' → no hit (writer-level single-jamo choseong skipped)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // Writer corpus tokens are body-level: single-jamo choseong (min_len=2)
    // skips \x01ㅇ, so 'ㅇ' no longer matches '안녕'. Use 'ㅇㄴ' for 2-char match.
    const q = "ㅇ";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Choseong query 'ㅇㄴ' → 안녕 doc (doc 3) hit (2-char prefix match)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㅇㄴ";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqualStrings("안녕 Hello", resultTitle(result, 0));
}

test "Choseong query 'ㄱ' → miss (안녕 starts with ㅇ, not ㄱ)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㄱ";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Choseong query doesn't match normal Korean: 'ㅇ' ≠ '안녕' token" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // 'ㅇㄴ' choseong query converted to 0x01ㅇㄴ marker token → different from '안녕' token
    // but since choseong token 0x01ㅇㄴ exists in filter, doc 3 hit
    const q = "ㅇㄴ";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqualStrings("안녕 Hello", resultTitle(result, 0));
}

test "English query 'hello' unaffected by choseong" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
}

test "Prefix match: query 'worl' → doc 0 via \\x02worl prefix token" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "worl";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqualStrings("Hello World", resultTitle(result, 0));
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
    const r1 = doSearch(q1, 0);
    try std.testing.expectEqual(@as(u32, 4), resultCount(r1));
    try std.testing.expectEqualStrings("Hello World", resultTitle(r1, 0));
    try std.testing.expectEqual(@as(u32, 2), resultHits(r1, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r1, 1));

    // 'worl' not last → no prefix probe, every doc hits only 'hello' (hits 1)
    const q2 = "worl hello";
    const r2 = doSearch(q2, 0);
    try std.testing.expectEqual(@as(u32, 4), resultCount(r2));
    try std.testing.expectEqual(@as(u32, 1), resultHits(r2, 0));
}

test "Title boost: title match outranks earlier body-only match on equal hits" {
    const allocator = std.testing.allocator;
    // doc 0: 'alpha' in body only. doc 1: 'alpha' in title (0x03-marked copy,
    // as the generator emits). Equal hits → title_hits breaks the tie in
    // favor of doc 1 despite its higher doc id.
    const docs = [_]DocInput{
        .{ .tokens = &.{ "alpha", "beta" }, .title = "Beta", .url = "/b", .meta_values = &.{""} },
        .{ .tokens = &.{ "alpha", "gamma", "\x03alpha" }, .title = "Alpha", .url = "/a", .meta_values = &.{""} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"date"},
        .docs = &docs,
        .choseong_max_len = 3,
    };
    const bytes = try writer.write(allocator, input);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "alpha";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 2), resultCount(result));
    try std.testing.expectEqualStrings("Alpha", resultTitle(result, 0)); // title match first
    try std.testing.expectEqualStrings("Beta", resultTitle(result, 1));
    // hits unchanged by the title probe — both docs matched 1 token
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultHits(result, 1));
}

test "g_index not set → search → count=0" {
    g_index = null;
    defer testCleanup();

    const q = "hello";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "Empty query → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "";
    const result = doSearch(q, 0);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "set_index: invalid magic → g_index=null, search → count=0" {
    var bad_bytes: [64]u8 = .{0} ** 64;
    set_index(&bad_bytes, bad_bytes.len);
    defer testCleanup();

    try std.testing.expect(g_index == null);

    const q = "test";
    const result = doSearch(q, 0);
    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

// ── prepareQuery tests ──

test "prepareQuery: returns writable memory of requested size" {
    const len: usize = 256;
    const ptr = prepareQuery(len);
    const buf: [*]u8 = ptr;
    for (0..len) |i| buf[i] = @intCast(i % 256);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    try std.testing.expectEqual(@as(u8, 42), buf[42]);
    try std.testing.expectEqual(@as(u8, 255), buf[255]);
    g_query_buffer.clearRetainingCapacity();
}

test "prepareQuery: reuse grows the buffer in place" {
    const p1 = prepareQuery(64);
    p1[0] = 0xAA;
    try std.testing.expectEqual(@as(u8, 0xAA), g_query_buffer.items[0]);

    // grow → items may move but the buffer covers the new size
    const p2 = prepareQuery(4096);
    try std.testing.expectEqual(@as(usize, 4096), g_query_buffer.items.len);
    p2[4095] = 0xBB;
    try std.testing.expectEqual(@as(u8, 0xBB), g_query_buffer.items[4095]);
    g_query_buffer.clearRetainingCapacity();
}

test "ensureIndex: null when no index registered (metadata slot at sentinel)" {
    defer testCleanup();
    try std.testing.expect(ensureIndex() == null);
}

test "ensureIndex: returns cached view after set_index" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // ensureIndex returns the same cached view set by set_index
    const view1 = ensureIndex();
    const view2 = ensureIndex();
    try std.testing.expect(view1 != null);
    try std.testing.expect(view2 != null);
}

// ── metaFields tests ──

test "metaFields: returns [num_docs][num_meta][name\\0...] for the loaded index" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const ptr = metaFields();
    const num_docs = std.mem.readInt(u32, ptr[0..4], .little);
    const num_meta = std.mem.readInt(u32, ptr[4..8], .little);
    try std.testing.expectEqual(@as(u32, 4), num_docs);
    try std.testing.expectEqual(@as(u32, 1), num_meta);
    // "date" NUL-terminated after the two u32s
    const name = std.mem.sliceTo(ptr[8..], 0);
    try std.testing.expectEqualStrings("date", name);
}

test "metaFields: returns zeros when no index loaded" {
    defer testCleanup();
    const ptr = metaFields();
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ptr[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, ptr[4..8], .little));
}

// ── wasm export forced (avoid lazy compilation) ──
comptime {
    @export(&prepareQuery, .{ .name = "prepare_query" });
    @export(&metaFields, .{ .name = "meta_fields" });
    @export(&search, .{ .name = "search" });
}