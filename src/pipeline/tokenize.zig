//! chaza text tokenization.
//!
//! Split UTF-8 text into runs by script groups → token list.
//! ASCII A-Z lowercased. Combining mark absorbed into preceding run.
//! Other characters (symbols/space/emoji/unsupported Letter) serve as delimiters forming run boundaries.

const std = @import("std");
const script = @import("script.zig");
const ScriptGroup = script.ScriptGroup;

/// Split text into token list.
/// Each token is owned copy via allocator. caller free each element of out_tokens then deinit.
pub fn tokenize(
    allocator: std.mem.Allocator,
    text: []const u8,
    out_tokens: *std.ArrayList([]const u8),
) anyerror!void {
    var view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();

    var current_group: ScriptGroup = .delimiter;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    while (iter.nextCodepoint()) |cp| {
        const group = script.scriptGroupOf(cp);

        switch (group) {
            .delimiter => {
                try flushToken(allocator, &buf, out_tokens);
                current_group = .delimiter;
            },
            .mark => {
                // mark ignored in empty run (no preceding character to absorb)
                if (current_group != .delimiter) {
                    try appendCodepoint(allocator, &buf, cp);
                }
            },
            else => {
                if (current_group == .delimiter) {
                    current_group = group;
                } else if (current_group != group) {
                    try flushToken(allocator, &buf, out_tokens);
                    current_group = group;
                }
                try appendCodepoint(allocator, &buf, cp);
            },
        }
    }
    try flushToken(allocator, &buf, out_tokens);
}

/// Append codepoint to buf as UTF-8. ASCII A-Z lowercased.
fn appendCodepoint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u21) !void {
    if (cp < 0x80) {
        var b: u8 = @intCast(cp);
        if (b >= 'A' and b <= 'Z') b += 0x20;
        try buf.append(allocator, b);
    } else {
        var tmp: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &tmp);
        try buf.appendSlice(allocator, tmp[0..len]);
    }
}

/// Finalize buf content as token, append to out_tokens, then clear buf.
fn flushToken(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    out_tokens: *std.ArrayList([]const u8),
) !void {
    if (buf.items.len == 0) return;
    const owned = try allocator.dupe(u8, buf.items);
    errdefer allocator.free(owned);
    try out_tokens.append(allocator, owned);
    buf.clearRetainingCapacity();
}

// ── Assertion tests ────────────────────────────────────────────────────

/// Test helper: free token memory + list.
fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8)) void {
    for (tokens.items) |t| allocator.free(t);
    tokens.deinit(allocator);
}

test "empty string → 0 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "", &tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "only whitespace → 0 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "   \t\n  ", &tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "single Latin word → lowercased" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "HELLO", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("hello", tokens.items[0]);
}

test "mixed case Latin HelloWorld → 1 token (no boundary)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "HelloWorld", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("helloworld", tokens.items[0]);
}

test "Latin space Latin → 2 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "foo bar", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("foo", tokens.items[0]);
    try std.testing.expectEqualStrings("bar", tokens.items[1]);
}

test "Hangul 안녕 → 1 token" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "안녕", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
}

test "안녕hello → 2 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "안녕hello", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
}

test "URL이 없다 → 3 tokens: url, 이, 없다" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "URL이 없다", &tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqualStrings("url", tokens.items[0]);
    try std.testing.expectEqualStrings("이", tokens.items[1]);
    try std.testing.expectEqualStrings("없다", tokens.items[2]);
}

test "Covid19 → 2 tokens: covid, 19" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "Covid19", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("covid", tokens.items[0]);
    try std.testing.expectEqualStrings("19", tokens.items[1]);
}

test "日本語ABC → 2 tokens: 日本語, abc" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "日本語ABC", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("日本語", tokens.items[0]);
    try std.testing.expectEqualStrings("abc", tokens.items[1]);
}

test "Hiragana+Katakana あア → 2 tokens (script boundary)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "あア", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("あ", tokens.items[0]);
    try std.testing.expectEqualStrings("ア", tokens.items[1]);
}

test "Hanja+Hangul 日本語안녕 → 2 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "日本語안녕", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("日本語", tokens.items[0]);
    try std.testing.expectEqualStrings("안녕", tokens.items[1]);
}

test "emoji included hello🔥world → 2 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "hello🔥world", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("hello", tokens.items[0]);
    try std.testing.expectEqualStrings("world", tokens.items[1]);
}

test "punctuation a,b,c → 3 tokens" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "a,b,c", &tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqualStrings("a", tokens.items[0]);
    try std.testing.expectEqualStrings("b", tokens.items[1]);
    try std.testing.expectEqualStrings("c", tokens.items[2]);
}

test "combining mark: e + U+0301 → 1 token (mark absorbed)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 'e' + combining acute accent = combined é (NFD)
    try tokenize(allocator, "e\u{0301}", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    // Preserve original bytes: 0x65 0xCC 0x81
    try std.testing.expectEqualStrings("e\u{0301}", tokens.items[0]);
}

test "combining mark: mark alone in empty run → ignored (0 tokens)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // mark at beginning → no preceding character to absorb → ignored
    try tokenize(allocator, "\u{0301}", &tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "ASCII digit only 123 → 1 token" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "123", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("123", tokens.items[0]);
}

test "Fullwidth digits １２３ → 1 token" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "１２３", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("１２３", tokens.items[0]);
}

test "combining mark at script boundary: Hangul + mark + Latin" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 가(U+0301)hello: mark absorbed into 가 run, hello new run
    try tokenize(allocator, "가\u{0301}hello", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("가\u{0301}", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
}