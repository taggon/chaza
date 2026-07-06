//! chaza 텍스트 토큰화.
//!
//! UTF-8 텍스트를 스크립트 그룹별 run으로 분할 → 토큰 목록 생성.
//! ASCII A-Z는 소문자화. combining mark는 앞 run에 흡수.
//! 그 외 문자(기호/공백/emoji/미지원 Letter)는 분절자로 run 경계 형성.

const std = @import("std");
const script = @import("script.zig");
const ScriptGroup = script.ScriptGroup;

/// 텍스트를 토큰 목록으로 분할.
/// 각 토큰은 allocator로 소유권 있는 복사본. caller가 out_tokens의 각 원소를 free 후 deinit.
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
                // 빈 run에서 mark는 무시 (흡수할 앞글자 없음)
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

/// codepoint를 buf에 UTF-8로 추가. ASCII A-Z는 소문자화.
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

/// buf의 내용을 토큰으로 확정하여 out_tokens에 추가 후 buf 비움.
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

// ── 단정 테스트 ────────────────────────────────────────────────────

/// 테스트용: 토큰 메모리 + 리스트 해제.
fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]const u8)) void {
    for (tokens.items) |t| allocator.free(t);
    tokens.deinit(allocator);
}

test "빈 문자열 → 토큰 0개" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "", &tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "공백만 → 토큰 0개" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "   \t\n  ", &tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "단일 Latin 단어 → 소문자화" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "HELLO", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("hello", tokens.items[0]);
}

test "대소문자 혼합 Latin HelloWorld → 1 토큰 (경계 없음)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "HelloWorld", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("helloworld", tokens.items[0]);
}

test "Latin 공백 Latin → 2 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "foo bar", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("foo", tokens.items[0]);
    try std.testing.expectEqualStrings("bar", tokens.items[1]);
}

test "한글 안녕 → 1 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "안녕", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
}

test "안녕hello → 2 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "안녕hello", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
}

test "URL이 없다 → 3 토큰: url, 이, 없다" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "URL이 없다", &tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqualStrings("url", tokens.items[0]);
    try std.testing.expectEqualStrings("이", tokens.items[1]);
    try std.testing.expectEqualStrings("없다", tokens.items[2]);
}

test "Covid19 → 2 토큰: covid, 19" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "Covid19", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("covid", tokens.items[0]);
    try std.testing.expectEqualStrings("19", tokens.items[1]);
}

test "日本語ABC → 2 토큰: 日本語, abc" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "日本語ABC", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("日本語", tokens.items[0]);
    try std.testing.expectEqualStrings("abc", tokens.items[1]);
}

test "히라가나+가타카나 あア → 2 토큰 (스크립트 경계)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "あア", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("あ", tokens.items[0]);
    try std.testing.expectEqualStrings("ア", tokens.items[1]);
}

test "한자+한글 日本語안녕 → 2 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "日本語안녕", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("日本語", tokens.items[0]);
    try std.testing.expectEqualStrings("안녕", tokens.items[1]);
}

test "이모지 포함 hello🔥world → 2 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "hello🔥world", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("hello", tokens.items[0]);
    try std.testing.expectEqualStrings("world", tokens.items[1]);
}

test "구두점 a,b,c → 3 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "a,b,c", &tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.items.len);
    try std.testing.expectEqualStrings("a", tokens.items[0]);
    try std.testing.expectEqualStrings("b", tokens.items[1]);
    try std.testing.expectEqualStrings("c", tokens.items[2]);
}

test "combining mark: e + U+0301 → 1 토큰 (mark 흡수)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 'e' + combining acute accent = 결합형 é (NFD)
    try tokenize(allocator, "e\u{0301}", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    // 원본 바이트 그대로 유지: 0x65 0xCC 0x81
    try std.testing.expectEqualStrings("e\u{0301}", tokens.items[0]);
}

test "combining mark: 빈 run에서 mark 단독 → 무시 (0 토큰)" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // mark가 맨 앞에 → 흡수할 앞글자 없음 → 무시
    try tokenize(allocator, "\u{0301}", &tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "ASCII digit only 123 → 1 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "123", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("123", tokens.items[0]);
}

test "전각 숫자 １２３ → 1 토큰" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokenize(allocator, "１２３", &tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("１２３", tokens.items[0]);
}

test "combining mark가 스크립트 경계에서: 한글 + mark + Latin" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 가(U+0301)hello: mark는 가 run에 흡수, hello는 새 run
    try tokenize(allocator, "가\u{0301}hello", &tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
    try std.testing.expectEqualStrings("가\u{0301}", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
}
