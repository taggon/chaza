//! chaza choseong token generation.
//!
//! Extract choseong from Hangul syllables to create prefix choseong tokens (0x01 marker + consonant).
//! Tokenization pipeline stage 5: add choseong prefix to unique tokens → deduplication.

const std = @import("std");
const format = @import("../index/format.zig");

/// Choseong index (0~18) → compatibility jamo codepoint mapping.
/// ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ
const CHOSEONG_JAMO = [_]u21{
    0x3131, 0x3132, 0x3134, 0x3137, 0x3138,
    0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
    0x3146, 0x3147, 0x3148, 0x3149, 0x314A,
    0x314B, 0x314C, 0x314D, 0x314E,
};

/// Extract choseong index (0~18) from Hangul syllable codepoint. null if not Hangul.
pub fn choseong(cp: u21) ?u8 {
    if (cp < 0xAC00 or cp > 0xD7A3) return null;
    const s = cp - 0xAC00;
    return @intCast(s / (21 * 28));
}

/// Convert choseong index to compatibility jamo codepoint.
pub fn choseongToJamo(idx: u8) u21 {
    return CHOSEONG_JAMO[idx];
}

/// Extract prefix choseong tokens from single token.
/// Process only Hangul syllables, for each prefix length (1~min(Hangul count, max_len))
/// add new buffer of 0x01 marker + choseong consonant UTF-8 combination to out.
/// caller free each element of out.
pub fn extractPrefixes(
    allocator: std.mem.Allocator,
    token: []const u8,
    max_len: u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (token.len == 0) return;

    // Extract only choseong from Hangul syllables in token
    var jamo_list: std.ArrayList(u21) = .empty;
    defer jamo_list.deinit(allocator);

    var view = try std.unicode.Utf8View.init(token);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (choseong(cp)) |idx| {
            try jamo_list.append(allocator, choseongToJamo(idx));
        }
    }

    // Generate prefix choseong tokens (length 1..min(Hangul count, max_len))
    const limit = @min(jamo_list.items.len, @as(usize, max_len));
    var len: usize = 1;
    while (len <= limit) : (len += 1) {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.append(allocator, format.CHOSEONG_MARKER);
        for (jamo_list.items[0..len]) |jamo| {
            var tmp: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(jamo, &tmp);
            try buf.appendSlice(allocator, tmp[0..n]);
        }

        const owned = try allocator.dupe(u8, buf.items);
        try out.append(allocator, owned);
    }
}

/// Add choseong prefix to entire token list (pipeline stage 5~6).
/// Keep existing tokens + add choseong tokens + deduplicate.
pub fn addChoseongTokens(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList([]const u8),
    max_len: u8,
) !void {
    const original_len = tokens.items.len;

    // Set for deduplication (initialized with existing tokens)
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (tokens.items[0..original_len]) |t| {
        try seen.put(t, {});
    }

    // Extract choseong prefix from each original token and add
    var i: usize = 0;
    while (i < original_len) : (i += 1) {
        // Marker-tagged tokens (choseong 0x01 / prefix 0x02 / title 0x03)
        // skipped — their Hangul syllables are a prefix of some full word's,
        // so any choseong tokens they would yield are already produced by
        // that word (title copies get their own marked choseong in the generator).
        const first = tokens.items[i];
        if (first.len > 0 and first[0] <= format.TITLE_MARKER) continue;

        var prefixes: std.ArrayList([]const u8) = .empty;
        defer {
            for (prefixes.items) |p| allocator.free(p);
            prefixes.deinit(allocator);
        }

        try extractPrefixes(allocator, tokens.items[i], max_len, &prefixes);

        for (prefixes.items) |prefix| {
            if (!seen.contains(prefix)) {
                const owned = try allocator.dupe(u8, prefix);
                errdefer allocator.free(owned);
                try seen.put(owned, {});
                try tokens.append(allocator, owned);
            }
        }
    }
}

/// Check if codepoint is choseong jamo in compatibility jamo block.
/// 19 choseong jamo: ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ
pub fn isChoseongJamo(cp: u21) bool {
    for (CHOSEONG_JAMO) |jamo| {
        if (cp == jamo) return true;
    }
    return false;
}

/// Check if token composed entirely of choseong compatibility jamo. Empty token false.
pub fn isAllChoseongJamo(token: []const u8) bool {
    if (token.len == 0) return false;
    var view = std.unicode.Utf8View.init(token) catch return false;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (!isChoseongJamo(cp)) return false;
    }
    return true;
}

/// Prepend 0x01 marker to tokens that are choseong-only (=all compatibility jamo) in query tokens.
/// Replace original token slot with new buffer with marker prepended (original buffer caller-owned).
pub fn markChoseongQueries(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList([]const u8),
) !void {
    var i: usize = 0;
    while (i < tokens.items.len) : (i += 1) {
        if (isAllChoseongJamo(tokens.items[i])) {
            const old = tokens.items[i];
            const buf = try allocator.alloc(u8, 1 + old.len);
            buf[0] = format.CHOSEONG_MARKER;
            @memcpy(buf[1..], old);
            tokens.items[i] = buf;
        }
    }
}

// ── Assertion tests ────────────────────────────────────────────────────

/// Test helper: free token memory + list.
fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8)) void {
    for (tokens.items) |t| allocator.free(t);
    tokens.deinit(allocator);
}

test "choseong: 가(0xAC00) = 0 (ㄱ)" {
    try std.testing.expectEqual(@as(u8, 0), choseong(0xAC00).?);
}

test "choseong: 힣(0xD7A3) = 18 (ㅎ)" {
    try std.testing.expectEqual(@as(u8, 18), choseong(0xD7A3).?);
}

test "choseong: 안(U+C548) = 11 (ㅇ)" {
    try std.testing.expectEqual(@as(u8, 11), choseong(0xC548).?);
}

test "choseong: Latin/Hiragana/Hanja = null" {
    try std.testing.expectEqual(@as(?u8, null), choseong('a'));
    try std.testing.expectEqual(@as(?u8, null), choseong(0x3042)); // あ
    try std.testing.expectEqual(@as(?u8, null), choseong(0x4E00)); // 一
    try std.testing.expectEqual(@as(?u8, null), choseong(' '));
}

test "choseong: boundary — just before 가/after 힣 = null" {
    try std.testing.expectEqual(@as(?u8, null), choseong(0xABFF));
    try std.testing.expectEqual(@as(?u8, null), choseong(0xD7A4));
}

test "choseong: first syllable of each choseong group" {
    // First syllable of choseong index i = 0xAC00 + i * 588
    try std.testing.expectEqual(@as(u8, 0), choseong(0xAC00 + 0 * 588).?); // 가 → ㄱ
    try std.testing.expectEqual(@as(u8, 1), choseong(0xAC00 + 1 * 588).?); // 까 → ㄲ
    try std.testing.expectEqual(@as(u8, 2), choseong(0xAC00 + 2 * 588).?); // 나 → ㄴ
    try std.testing.expectEqual(@as(u8, 11), choseong(0xAC00 + 11 * 588).?); // 아 → ㅇ
    try std.testing.expectEqual(@as(u8, 18), choseong(0xAC00 + 18 * 588).?); // 하 → ㅎ
}

test "choseongToJamo: 0 = ㄱ(0x3131)" {
    try std.testing.expectEqual(@as(u21, 0x3131), choseongToJamo(0));
}

test "choseongToJamo: 18 = ㅎ(0x314E)" {
    try std.testing.expectEqual(@as(u21, 0x314E), choseongToJamo(18));
}

test "choseongToJamo: 11 = ㅇ(0x3147)" {
    try std.testing.expectEqual(@as(u21, 0x3147), choseongToJamo(11));
}

test "choseongToJamo: verify all 19 mappings" {
    const expected = [_]u21{
        0x3131, 0x3132, 0x3134, 0x3137, 0x3138,
        0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
        0x3146, 0x3147, 0x3148, 0x3149, 0x314A,
        0x314B, 0x314C, 0x314D, 0x314E,
    };
    for (expected, 0..) |exp, i| {
        try std.testing.expectEqual(exp, choseongToJamo(@intCast(i)));
    }
}

test "extractPrefixes: 안녕 max_len=3 → 2 tokens (ㅇ, ㅇㄴ)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "안녕", 3, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);

    // length 1: marker + ㅇ
    const expected_1 = "\x01\u{3147}";
    try std.testing.expectEqualStrings(expected_1, out.items[0]);

    // length 2: marker + ㅇ + ㄴ
    const expected_2 = "\x01\u{3147}\u{3134}";
    try std.testing.expectEqualStrings(expected_2, out.items[1]);
}

test "extractPrefixes: 안녕하세요 max_len=3 → 3 tokens (ㅇ, ㅇㄴ, ㅇㄴㅎ)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    // 안(ㅇ) 녕(ㄴ) 하(ㅎ) 세(ㅅ) 요(ㅇ) → prefixes 1~3: ㅇ, ㅇㄴ, ㅇㄴㅎ
    try extractPrefixes(allocator, "안녕하세요", 3, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);

    try std.testing.expectEqualStrings("\x01\u{3147}", out.items[0]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}", out.items[1]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}\u{314E}", out.items[2]);
}

test "extractPrefixes: hello max_len=3 → 0 tokens (not Hangul)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "hello", 3, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractPrefixes: empty string → 0 tokens" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "", 3, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractPrefixes: 가 max_len=3 → 1 token (ㄱ)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "가", 3, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("\x01\u{3131}", out.items[0]);
}

test "extractPrefixes: max_len=1 → length 1 prefixes only" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "안녕하세요", 1, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("\x01\u{3147}", out.items[0]);
}

test "extractPrefixes: choseong tokens always start with 0x01 marker" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "한글", 3, &out);
    for (out.items) |tok| {
        try std.testing.expectEqual(@as(u8, 0x01), tok[0]);
    }
}

test "extractPrefixes: combining mark token — mark ignored" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    // 가\u{0301}: 가(ㄱ) + combining mark → 1 choseong
    try extractPrefixes(allocator, "가\u{0301}", 3, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("\x01\u{3131}", out.items[0]);
}

test "addChoseongTokens: keep existing tokens + add choseong tokens + deduplicate" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // Original tokens: "안녕", "hello" (allocator-owned copies)
    try tokens.append(allocator, try allocator.dupe(u8, "안녕"));
    try tokens.append(allocator, try allocator.dupe(u8, "hello"));

    try addChoseongTokens(allocator, &tokens, 3);

    // Original 2 + choseong 2 (ㅇ, ㅇㄴ) = 4
    try std.testing.expectEqual(@as(usize, 4), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
    // Choseong tokens
    try std.testing.expectEqualStrings("\x01\u{3147}", tokens.items[2]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}", tokens.items[3]);
}

test "addChoseongTokens: two words with same choseong → deduplicate" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 안녕(ㅇㄴ), 애니(ㅇㄴ) → choseong prefixes ㅇ, ㅇㄴ duplicated
    try tokens.append(allocator, try allocator.dupe(u8, "안녕"));
    try tokens.append(allocator, try allocator.dupe(u8, "애니"));

    try addChoseongTokens(allocator, &tokens, 3);

    // Original 2 + choseong 2 (ㅇ, ㅇㄴ — deduplicated)
    try std.testing.expectEqual(@as(usize, 4), tokens.items.len);
}

test "addChoseongTokens: empty list → no change" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try addChoseongTokens(allocator, &tokens, 3);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "addChoseongTokens: non-Hangul tokens only → no choseong" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokens.append(allocator, try allocator.dupe(u8, "hello"));
    try tokens.append(allocator, try allocator.dupe(u8, "world"));

    try addChoseongTokens(allocator, &tokens, 3);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
}

test "Integrated pipeline: tokenize → addChoseongTokens" {
    const allocator = std.testing.allocator;
    const tokenize = @import("tokenize.zig");

    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize.tokenize(allocator, "안녕 hello", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);

    try addChoseongTokens(allocator, &tokens, 3);

    // ["안녕", "hello", 0x01ㅇ, 0x01ㅇㄴ]
    try std.testing.expectEqual(@as(usize, 4), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
    try std.testing.expectEqualStrings("\x01\u{3147}", tokens.items[2]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}", tokens.items[3]);

    // All choseong tokens start with marker 0x01
    try std.testing.expectEqual(@as(u8, 0x01), tokens.items[2][0]);
    try std.testing.expectEqual(@as(u8, 0x01), tokens.items[3][0]);
}

test "isChoseongJamo: ㄱ(0x3131) = true" {
    try std.testing.expect(isChoseongJamo(0x3131));
}

test "isChoseongJamo: ㄴ(0x3134) = true" {
    try std.testing.expect(isChoseongJamo(0x3134));
}

test "isChoseongJamo: ㅏ(0x314F) = false (jungseong)" {
    try std.testing.expect(!isChoseongJamo(0x314F));
}

test "isChoseongJamo: 'a' = false" {
    try std.testing.expect(!isChoseongJamo('a'));
}

test "isAllChoseongJamo: ㄱㄴ = true" {
    try std.testing.expect(isAllChoseongJamo("ㄱㄴ"));
}

test "isAllChoseongJamo: 안녕 = false (complete syllable)" {
    try std.testing.expect(!isAllChoseongJamo("안녕"));
}

test "isAllChoseongJamo: empty string = false" {
    try std.testing.expect(!isAllChoseongJamo(""));
}

test "isAllChoseongJamo: hello = false" {
    try std.testing.expect(!isAllChoseongJamo("hello"));
}

test "markChoseongQueries: [ㄱㄴ, hello] → [0x01ㄱㄴ, hello]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tokens: std.ArrayList([]const u8) = .empty;
    try tokens.append(allocator, try allocator.dupe(u8, "ㄱㄴ"));
    try tokens.append(allocator, try allocator.dupe(u8, "hello"));

    try markChoseongQueries(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("\x01ㄱㄴ", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
}

test "markChoseongQueries: [안녕] → [안녕] (no change)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tokens: std.ArrayList([]const u8) = .empty;
    try tokens.append(allocator, try allocator.dupe(u8, "안녕"));

    try markChoseongQueries(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
}