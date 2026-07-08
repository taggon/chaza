//! chaza prefix (edge n-gram) token generation.
//!
//! Words from prefix_fields get edge n-gram tokens (0x02 marker + first k
//! codepoints, k = 2..min(8, len-1)) at index time, enabling
//! search-as-you-type prefix matching. The filter is exact-membership only,
//! so prefixes must be materialized as tokens — same technique as choseong
//! (0x01) prefix tokens.
//!
//! Query side: only the last query token (the word being typed) is probed
//! as a prefix token, in addition to its exact lookup.

const std = @import("std");
const format = @import("../index/format.zig");

/// Shortest indexed prefix, in codepoints. 1 is omitted — single-char
/// prefixes match too broadly (Latin especially).
pub const MIN_LEN: usize = 2;

/// Longest indexed prefix, in codepoints. Longer typed prefixes stop
/// matching until the full word matches exactly.
pub const MAX_LEN: usize = 8;

/// Extract edge n-gram prefix tokens from a single token.
/// Emits 0x02 marker + first k codepoints for k = MIN_LEN..min(MAX_LEN, cp_count-1).
/// Proper prefixes only — the full word is covered by its exact token.
/// Tokens that already carry a marker byte are skipped.
/// caller frees each element of out.
pub fn extractPrefixes(
    allocator: std.mem.Allocator,
    token: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (token.len == 0) return;
    if (token[0] == format.CHOSEONG_MARKER or token[0] == format.PREFIX_MARKER) return;

    // Byte offset of each codepoint boundary (offsets[i] = start of i-th codepoint)
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);

    var view = std.unicode.Utf8View.init(token) catch return;
    var iter = view.iterator();
    while (true) {
        try offsets.append(allocator, iter.i);
        if (iter.nextCodepoint() == null) break;
    }
    // offsets now holds cp_count+1 entries (last = token.len)
    const cp_count = offsets.items.len - 1;
    if (cp_count <= MIN_LEN) return; // no proper prefix of length ≥ MIN_LEN

    const limit = @min(MAX_LEN, cp_count - 1);
    var k: usize = MIN_LEN;
    while (k <= limit) : (k += 1) {
        const end = offsets.items[k];
        const buf = try allocator.alloc(u8, 1 + end);
        buf[0] = format.PREFIX_MARKER;
        @memcpy(buf[1..], token[0..end]);
        try out.append(allocator, buf);
    }
}

/// Build the prefix-probe token for a query token, or null when a prefix
/// lookup cannot match: token empty, already marker-tagged (choseong query),
/// or codepoint count outside MIN_LEN..MAX_LEN (never indexed).
/// caller frees the returned buffer.
pub fn makeQueryPrefixToken(
    allocator: std.mem.Allocator,
    token: []const u8,
) !?[]u8 {
    if (token.len == 0) return null;
    if (token[0] == format.CHOSEONG_MARKER or token[0] == format.PREFIX_MARKER) return null;

    const cp_count = std.unicode.utf8CountCodepoints(token) catch return null;
    if (cp_count < MIN_LEN or cp_count > MAX_LEN) return null;

    const buf = try allocator.alloc(u8, 1 + token.len);
    buf[0] = format.PREFIX_MARKER;
    @memcpy(buf[1..], token);
    return buf;
}

// ── Assertion tests ────────────────────────────────────────────────────

fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8)) void {
    for (tokens.items) |t| allocator.free(t);
    tokens.deinit(allocator);
}

test "extractPrefixes: hello → \\x02he, \\x02hel, \\x02hell (k=2..4)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "hello", &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("\x02he", out.items[0]);
    try std.testing.expectEqualStrings("\x02hel", out.items[1]);
    try std.testing.expectEqualStrings("\x02hell", out.items[2]);
}

test "extractPrefixes: 프로그래밍 (5 syllables) → 프로, 프로그, 프로그래 (k=2..4)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "프로그래밍", &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("\x02프로", out.items[0]);
    try std.testing.expectEqualStrings("\x02프로그", out.items[1]);
    try std.testing.expectEqualStrings("\x02프로그래", out.items[2]);
}

test "extractPrefixes: short words (≤ MIN_LEN cp) → no prefixes" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "hi", &out); // 2 cp: proper prefix len 1 < MIN_LEN
    try extractPrefixes(allocator, "a", &out);
    try extractPrefixes(allocator, "", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractPrefixes: long word capped at MAX_LEN" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    // 12 cp → k = 2..8 → 7 prefixes
    try extractPrefixes(allocator, "abcdefghijkl", &out);
    try std.testing.expectEqual(@as(usize, 7), out.items.len);
    try std.testing.expectEqualStrings("\x02ab", out.items[0]);
    try std.testing.expectEqualStrings("\x02abcdefgh", out.items[6]);
}

test "extractPrefixes: marker-tagged tokens skipped" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "\x01ㅇㄴ", &out);
    try extractPrefixes(allocator, "\x02hel", &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "makeQueryPrefixToken: 'hel' → \\x02hel" {
    const allocator = std.testing.allocator;
    const pt = (try makeQueryPrefixToken(allocator, "hel")).?;
    defer allocator.free(pt);
    try std.testing.expectEqualStrings("\x02hel", pt);
}

test "makeQueryPrefixToken: out-of-range lengths → null" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try makeQueryPrefixToken(allocator, "a")); // 1 cp
    try std.testing.expectEqual(@as(?[]u8, null), try makeQueryPrefixToken(allocator, "abcdefghi")); // 9 cp
    try std.testing.expectEqual(@as(?[]u8, null), try makeQueryPrefixToken(allocator, ""));
}

test "makeQueryPrefixToken: choseong-marked query token → null" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?[]u8, null), try makeQueryPrefixToken(allocator, "\x01ㄱㄴ"));
}

test "makeQueryPrefixToken: Korean 2-syllable '대한' → \\x02대한" {
    const allocator = std.testing.allocator;
    const pt = (try makeQueryPrefixToken(allocator, "대한")).?;
    defer allocator.free(pt);
    try std.testing.expectEqualStrings("\x02대한", pt);
}

test "roundtrip: query prefix token matches indexed prefix token" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "programming", &out);

    const q = (try makeQueryPrefixToken(allocator, "progr")).?;
    defer allocator.free(q);

    var found = false;
    for (out.items) |p| {
        if (std.mem.eql(u8, p, q)) found = true;
    }
    try std.testing.expect(found);
}
