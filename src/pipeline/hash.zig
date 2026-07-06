//! 필터용 해시 함수.
//!
//! key64: 토큰 바이트 → xxhash64 → u64 키. BinaryFuse8 필터에 사용.
//! xxhash64(`std.hash.XxHash64`). seed=0 고정.
//! 생성기·런타임이 같은 함수를 공유 → 키 일치 강제.

const std = @import("std");

/// xxhash64 seed (고정).
const SEED: u64 = 0;

/// 토큰 바이트 → u64 키 (BinaryFuse8 필터용).
/// xxhash64로 64비트 정수 키 생성. 생성기·런타임 동일 함수.
pub fn key64(data: []const u8) u64 {
    return std.hash.XxHash64.hash(SEED, data);
}

// ── 단정 테스트 ────────────────────────────────────────────────────

test "XxHash64: 빈 문자열 seed=0 → 표준값 0xEF46DB3751D8E999" {
    const h = std.hash.XxHash64.hash(0, "");
    try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), h);
}

test "XxHash64: 결정론적 — 동일 입력 동일 출력" {
    const a = std.hash.XxHash64.hash(0, "hello");
    const b = std.hash.XxHash64.hash(0, "hello");
    try std.testing.expectEqual(a, b);
}

test "XxHash64: 다른 입력 → 다른 출력" {
    const a = std.hash.XxHash64.hash(0, "hello");
    const b = std.hash.XxHash64.hash(0, "world");
    try std.testing.expect(a != b);
}

test "key64: 결정론적 — 동일 입력 동일 출력" {
    try std.testing.expectEqual(key64("hello"), key64("hello"));
    try std.testing.expectEqual(key64(""), key64(""));
    try std.testing.expectEqual(key64("안녕"), key64("안녕"));
}

test "key64: 다른 입력 → 다른 출력 (일반적으로)" {
    const a = key64("alpha");
    const b = key64("beta");
    try std.testing.expect(a != b);
}

test "key64: XxHash64 표준값 일치" {
    // 빈 문자열의 xxhash64(seed=0) = 0xEF46DB3751D8E999
    try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), key64(""));
}
