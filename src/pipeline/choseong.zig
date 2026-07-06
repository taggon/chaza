//! chaza 초성(choseong) 토큰 생성.
//!
//! 한글 음절에서 초성을 추출해 접두 초성 토큰(0x01 마커 + 자음) 생성.
//! 토큰화 파이프라인 5단계: 고유 토큰에 choseong prefix 추가 → 중복 제거.

const std = @import("std");
const format = @import("../index/format.zig");

/// 초성 인덱스(0~18) → 호환 자모 codepoint 매핑.
/// ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ
const CHOSEONG_JAMO = [_]u21{
    0x3131, 0x3132, 0x3134, 0x3137, 0x3138,
    0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
    0x3146, 0x3147, 0x3148, 0x3149, 0x314A,
    0x314B, 0x314C, 0x314D, 0x314E,
};

/// 한글 음절 codepoint에서 초성 인덱스(0~18) 추출. 한글이 아니면 null.
pub fn choseong(cp: u21) ?u8 {
    if (cp < 0xAC00 or cp > 0xD7A3) return null;
    const s = cp - 0xAC00;
    return @intCast(s / (21 * 28));
}

/// 초성 인덱스를 호환 자모 codepoint로 변환.
pub fn choseongToJamo(idx: u8) u21 {
    return CHOSEONG_JAMO[idx];
}

/// 단일 토큰에서 접두 초성 토큰들 추출.
/// 한글 음절만 처리하며, 각 접두 길이(1~min(한글 수, max_len))별로
/// 0x01 마커 + 초성 자음 UTF-8 조합의 새 버퍼를 out에 추가.
/// caller가 out의 각 원소를 free.
pub fn extractPrefixes(
    allocator: std.mem.Allocator,
    token: []const u8,
    max_len: u8,
    out: *std.ArrayList([]const u8),
) !void {
    if (token.len == 0) return;

    // 토큰에서 한글 음절의 초성만 추출
    var jamo_list: std.ArrayList(u21) = .empty;
    defer jamo_list.deinit(allocator);

    var view = try std.unicode.Utf8View.init(token);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (choseong(cp)) |idx| {
            try jamo_list.append(allocator, choseongToJamo(idx));
        }
    }

    // 접두 초성 토큰 생성 (길이 1..min(한글 수, max_len))
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

/// 토큰 리스트 전체에 choseong prefix 추가 (파이프라인 5~6단계).
/// 기존 토큰 유지 + 초성 토큰 추가 + 중복 제거.
pub fn addChoseongTokens(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayList([]const u8),
    max_len: u8,
) !void {
    const original_len = tokens.items.len;

    // 중복 제거용 set (기존 토큰으로 초기화)
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    for (tokens.items[0..original_len]) |t| {
        try seen.put(t, {});
    }

    // 각 원본 토큰에서 초성 prefix 추출 및 추가
    var i: usize = 0;
    while (i < original_len) : (i += 1) {
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

/// codepoint가 호환 자모 블록의 초성 자모인지 확인.
/// 초성 자모 19개: ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ
pub fn isChoseongJamo(cp: u21) bool {
    for (CHOSEONG_JAMO) |jamo| {
        if (cp == jamo) return true;
    }
    return false;
}

/// 토큰이 전부 초성 호환 자모로만 이루어졌는지. 빈 토큰은 false.
pub fn isAllChoseongJamo(token: []const u8) bool {
    if (token.len == 0) return false;
    var view = std.unicode.Utf8View.init(token) catch return false;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (!isChoseongJamo(cp)) return false;
    }
    return true;
}

/// 쿼리 토큰 중 초성 전용 토큰(=모두 호환 자모)에 0x01 마커를 앞에 붙임.
/// 기존 토큰 슬롯을 마커 붙인 새 버퍼로 교체 (기존 버퍼는 caller 소유).
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

// ── 단정 테스트 ────────────────────────────────────────────────────

/// 테스트용: 토큰 메모리 + 리스트 해제.
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

test "choseong: 라틴/히라가나/한자 = null" {
    try std.testing.expectEqual(@as(?u8, null), choseong('a'));
    try std.testing.expectEqual(@as(?u8, null), choseong(0x3042)); // あ
    try std.testing.expectEqual(@as(?u8, null), choseong(0x4E00)); // 一
    try std.testing.expectEqual(@as(?u8, null), choseong(' '));
}

test "choseong: 경계값 — 가 직전·힣 직후 = null" {
    try std.testing.expectEqual(@as(?u8, null), choseong(0xABFF));
    try std.testing.expectEqual(@as(?u8, null), choseong(0xD7A4));
}

test "choseong: 각 초성 그룹의 첫 음절" {
    // 초성 인덱스 i의 첫 음절 = 0xAC00 + i * 588
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

test "choseongToJamo: 전체 19개 매핑 검증" {
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

test "extractPrefixes: 안녕 max_len=3 → 2개 (ㅇ, ㅇㄴ)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "안녕", 3, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);

    // 길이 1: marker + ㅇ
    const expected_1 = "\x01\u{3147}";
    try std.testing.expectEqualStrings(expected_1, out.items[0]);

    // 길이 2: marker + ㅇ + ㄴ
    const expected_2 = "\x01\u{3147}\u{3134}";
    try std.testing.expectEqualStrings(expected_2, out.items[1]);
}

test "extractPrefixes: 안녕하세요 max_len=3 → 3개 (ㅇ, ㅇㄴ, ㅇㄴㅎ)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    // 안(ㅇ) 녕(ㄴ) 하(ㅎ) 세(ㅅ) 요(ㅇ) → 접두 1~3: ㅇ, ㅇㄴ, ㅇㄴㅎ
    try extractPrefixes(allocator, "안녕하세요", 3, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);

    try std.testing.expectEqualStrings("\x01\u{3147}", out.items[0]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}", out.items[1]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}\u{314E}", out.items[2]);
}

test "extractPrefixes: hello max_len=3 → 0개 (한글 아님)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "hello", 3, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractPrefixes: 빈 문자열 → 0개" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "", 3, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "extractPrefixes: 가 max_len=3 → 1개 (ㄱ)" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "가", 3, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("\x01\u{3131}", out.items[0]);
}

test "extractPrefixes: max_len=1 → 길이 1 접두만" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "안녕하세요", 1, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("\x01\u{3147}", out.items[0]);
}

test "extractPrefixes: 초성 토큰은 항상 0x01 마커로 시작" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    try extractPrefixes(allocator, "한글", 3, &out);
    for (out.items) |tok| {
        try std.testing.expectEqual(@as(u8, 0x01), tok[0]);
    }
}

test "extractPrefixes: combining mark 포함 토큰 — mark는 무시" {
    const allocator = std.testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &out);

    // 가\u{0301}: 가(ㄱ) + combining mark → 초성 1개
    try extractPrefixes(allocator, "가\u{0301}", 3, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("\x01\u{3131}", out.items[0]);
}

test "addChoseongTokens: 기존 토큰 유지 + 초성 토큰 추가 + 중복 제거" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 원본 토큰: "안녕", "hello" (allocator 소유 복사본)
    try tokens.append(allocator, try allocator.dupe(u8, "안녕"));
    try tokens.append(allocator, try allocator.dupe(u8, "hello"));

    try addChoseongTokens(allocator, &tokens, 3);

    // 기존 2 + 초성 2 (ㅇ, ㅇㄴ) = 4
    try std.testing.expectEqual(@as(usize, 4), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
    try std.testing.expectEqualStrings("hello", tokens.items[1]);
    // 초성 토큰
    try std.testing.expectEqualStrings("\x01\u{3147}", tokens.items[2]);
    try std.testing.expectEqualStrings("\x01\u{3147}\u{3134}", tokens.items[3]);
}

test "addChoseongTokens: 같은 초성을 가진 두 단어 → 중복 제거" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    // 안녕(ㅇㄴ), 애니(ㅇㄴ) → 초성 접두 ㅇ, ㅇㄴ이 중복
    try tokens.append(allocator, try allocator.dupe(u8, "안녕"));
    try tokens.append(allocator, try allocator.dupe(u8, "애니"));

    try addChoseongTokens(allocator, &tokens, 3);

    // 기존 2 + 초성 2 (ㅇ, ㅇㄴ — 중복 제거됨)
    try std.testing.expectEqual(@as(usize, 4), tokens.items.len);
}

test "addChoseongTokens: 빈 리스트 → 변화 없음" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try addChoseongTokens(allocator, &tokens, 3);
    try std.testing.expectEqual(@as(usize, 0), tokens.items.len);
}

test "addChoseongTokens: 비한글 토큰만 → 초성 없음" {
    const allocator = std.testing.allocator;
    var tokens: std.ArrayList([]const u8) = .empty;
    defer freeTokens(allocator, &tokens);

    try tokens.append(allocator, try allocator.dupe(u8, "hello"));
    try tokens.append(allocator, try allocator.dupe(u8, "world"));

    try addChoseongTokens(allocator, &tokens, 3);
    try std.testing.expectEqual(@as(usize, 2), tokens.items.len);
}

test "통합 파이프라인: tokenize → addChoseongTokens" {
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

    // 모든 초성 토큰은 마커 0x01로 시작
    try std.testing.expectEqual(@as(u8, 0x01), tokens.items[2][0]);
    try std.testing.expectEqual(@as(u8, 0x01), tokens.items[3][0]);
}

test "isChoseongJamo: ㄱ(0x3131) = true" {
    try std.testing.expect(isChoseongJamo(0x3131));
}

test "isChoseongJamo: ㄴ(0x3134) = true" {
    try std.testing.expect(isChoseongJamo(0x3134));
}

test "isChoseongJamo: ㅏ(0x314F) = false (중성)" {
    try std.testing.expect(!isChoseongJamo(0x314F));
}

test "isChoseongJamo: 'a' = false" {
    try std.testing.expect(!isChoseongJamo('a'));
}

test "isAllChoseongJamo: ㄱㄴ = true" {
    try std.testing.expect(isAllChoseongJamo("ㄱㄴ"));
}

test "isAllChoseongJamo: 안녕 = false (완성형)" {
    try std.testing.expect(!isAllChoseongJamo("안녕"));
}

test "isAllChoseongJamo: 빈 문자열 = false" {
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

test "markChoseongQueries: [안녕] → [안녕] (변경 없음)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tokens: std.ArrayList([]const u8) = .empty;
    try tokens.append(allocator, try allocator.dupe(u8, "안녕"));

    try markChoseongQueries(allocator, &tokens);

    try std.testing.expectEqual(@as(usize, 1), tokens.items.len);
    try std.testing.expectEqualStrings("안녕", tokens.items[0]);
}
