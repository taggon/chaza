//! chaza 불용어 집합 — 파서 + 필터.
//!
//! 토큰화 파이프라인 3단계: 분절 직후, 고유 토큰 수집·초성 생성 전에 불용어 제거.
//!
//! 파일 형식 (SPEC): UTF-8, 줄 단위 하나의 불용어.
//! 앞뒤 공백 trim, 빈 줄 무시, '#'으로 시작하는 줄은 주석 무시.
//!
//! 대소문자: tokenize()가 ASCII A-Z를 소문자화하므로, 파싱 시점에 동일하게
//! ASCII 소문자화하여 저장. isStopword는 (파이프라인 계약상 이미 소문자화된)
//! 토큰을 그대로 O(1) 조회한다.

const std = @import("std");

/// 불용어 집합. 해시셋으로 O(1) 조회.
pub const StopwordSet = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,

    /// 파일 내용(UTF-8 바이트)에서 불용어 집합 파싱.
    /// 줄 단위, '#' 주석, trim, 빈 줄 무시. ASCII A-Z는 소문자화해 저장.
    /// 각 키는 allocator 소유. caller가 deinit으로 해제.
    pub fn fromFileBytes(allocator: std.mem.Allocator, file_bytes: []const u8) !StopwordSet {
        var self: StopwordSet = .{};
        errdefer self.deinit(allocator);

        var it = std.mem.splitScalar(u8, file_bytes, '\n');
        while (it.next()) |raw_line| {
            // 앞뒤 공백(스페이스·탭·CR) trim
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue; // 빈 줄 무시
            if (line[0] == '#') continue; // 주석 무시

            // ASCII 소문자화 복제 (tokenize 결과와 비교 일관성)
            const lowered = try asciiLowerDup(allocator, line);
            errdefer allocator.free(lowered);

            // 동일 키가 이미 있으면 이 복제본은 해제
            const gop = try self.set.getOrPut(allocator, lowered);
            if (gop.found_existing) {
                allocator.free(lowered);
            }
        }
        return self;
    }

    /// 토큰이 불용어인지 O(1) 조회.
    /// 파이프라인 계약상 token는 tokenize()를 거친 ASCII 소문자 토큰이어야 한다.
    pub fn isStopword(self: StopwordSet, token: []const u8) bool {
        return self.set.contains(token);
    }

    /// 집합 내 불용어 개수.
    pub fn count(self: StopwordSet) usize {
        return self.set.count();
    }

    /// 할당 해제. 각 키 문자열과 해시맵을 allocator로 반환.
    pub fn deinit(self: *StopwordSet, allocator: std.mem.Allocator) void {
        var it = self.set.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.set.deinit(allocator);
    }
};

/// 불용어 제거 비활성 상태. isStopword는 항상 false.
pub const EMPTY: StopwordSet = .{};

/// ASCII A-Z만 소문자화한 복제본 생성. 비ASCII는 그대로.
/// tokenize.appendCodepoint의 소문자화 로직과 동일.
fn asciiLowerDup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 0x20 else c;
    }
    return out;
}

// ── 단정 테스트 ────────────────────────────────────────────────────

test "빈 파일 → 빈 집합, isStopword 항상 false" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), set.count());
    try std.testing.expect(!set.isStopword("the"));
    try std.testing.expect(!set.isStopword(""));
}

test "단일 단어 파일 → 그 단어가 불용어" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(!set.isStopword("foo"));
}

test "여러 줄 → 각각 불용어" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\na\nan\nof\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("a"));
    try std.testing.expect(set.isStopword("an"));
    try std.testing.expect(set.isStopword("of"));
}

test "빈 줄 무시" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\n\n\nan\n\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "'#'로 시작하는 줄은 주석으로 무시" {
    const allocator = std.testing.allocator;
    const file =
        \\# 이것은 주석
        \\the
        \\# 다른 주석
        \\an
        \\
        \\# 앞 공백 있는 주석
    ;
    var set = try StopwordSet.fromFileBytes(allocator, file);
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
    // 주석 내용은 불용어로 등록되지 않음
    try std.testing.expect(!set.isStopword("이것은"));
    try std.testing.expect(!set.isStopword("주석"));
}

test "줄 앞뒤 공백 trim" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "   the   \n\tan\t\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
}

test "대문자 입력 → 소문자화 후 저장 (THE → the)" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "THE\nAn\nOF");
    defer set.deinit(allocator);

    // 파싱 시점 소문자화: 집합엔 소문자로 저장
    try std.testing.expectEqual(@as(usize, 3), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
    try std.testing.expect(set.isStopword("of"));
}

test "한글 불용어 (이, 가) 처리" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "이\n가\n은\n는\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), set.count());
    try std.testing.expect(set.isStopword("이"));
    try std.testing.expect(set.isStopword("가"));
    try std.testing.expect(set.isStopword("은"));
    try std.testing.expect(set.isStopword("는"));
    try std.testing.expect(!set.isStopword("안녕"));
}

test "isStopword 빈 집합 → 항상 false" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "");
    defer set.deinit(allocator);

    try std.testing.expect(!set.isStopword("the"));
    try std.testing.expect(!set.isStopword("이"));
    try std.testing.expect(!set.isStopword("anything"));
}

test "fromFileBytes 메모리 관리: deinit으로 누수 없음 (testing.allocator)" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "a\nb\nc\nd\ne\n");
    set.deinit(allocator);
    // testing.allocator는 누수 시 테스트 실패. 여기서 통과면 해제됨.
}

test "파이프라인 일관성: 파일 'THE' → tokenize('The') 토큰과 매칭" {
    const allocator = std.testing.allocator;
    const tokenize = @import("tokenize.zig");

    var set = try StopwordSet.fromFileBytes(allocator, "THE\n");
    defer set.deinit(allocator);

    // tokenize가 소문자화하므로 "The" → "the"
    var tokens: std.ArrayList([]const u8) = .empty;
    defer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }
    try tokenize.tokenize(allocator, "The quick", &tokens);

    // 첫 토큰("the")이 불용어로 매칭되어야 함
    try std.testing.expectEqualStrings("the", tokens.items[0]);
    try std.testing.expect(set.isStopword(tokens.items[0]));
    try std.testing.expect(!set.isStopword(tokens.items[1])); // "quick"
}

test "복잡한 파일: 주석 + 빈 줄 + 단어 + 대소문자 혼합" {
    const allocator = std.testing.allocator;
    const file =
        \\# English stopwords
        \\the
        \\THE
        \\a
        \\
        \\# Korean
        \\이
        \\가
        \\
        \\   of
    ;
    var set = try StopwordSet.fromFileBytes(allocator, file);
    defer set.deinit(allocator);

    // "the"와 "THE"는 동일 키 → 중복 제거
    try std.testing.expectEqual(@as(usize, 5), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("a"));
    try std.testing.expect(set.isStopword("이"));
    try std.testing.expect(set.isStopword("가"));
    try std.testing.expect(set.isStopword("of"));
}

test "CRLF 줄결미 trim 처리" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\r\nan\r\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
}

test "끝 개행 없는 파일도 파싱" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\nan");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
}

test "EMPTY 상수 → isStopword 항상 false" {
    try std.testing.expect(!EMPTY.isStopword("the"));
    try std.testing.expect(!EMPTY.isStopword(""));
    try std.testing.expectEqual(@as(usize, 0), EMPTY.count());
}
