//! Filter hash functions.
//!
//! key64: token bytes → xxhash64 → u64 key. Used for BinaryFuse8 filter.
//! xxhash64 (std.hash.XxHash64). seed=0 fixed.
//! Generator and runtime share same function → forces key consistency.

const std = @import("std");

/// xxhash64 seed (fixed).
const SEED: u64 = 0;

/// token bytes → u64 key (for BinaryFuse8 filter).
/// Generate 64-bit integer key via xxhash64. Same function for generator·runtime.
pub fn key64(data: []const u8) u64 {
    return std.hash.XxHash64.hash(SEED, data);
}

// ── Assertion tests ────────────────────────────────────────────────────

test "XxHash64: empty string seed=0 → standard value 0xEF46DB3751D8E999" {
    const h = std.hash.XxHash64.hash(0, "");
    try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), h);
}

test "XxHash64: deterministic — same input same output" {
    const a = std.hash.XxHash64.hash(0, "hello");
    const b = std.hash.XxHash64.hash(0, "hello");
    try std.testing.expectEqual(a, b);
}

test "XxHash64: different input → different output" {
    const a = std.hash.XxHash64.hash(0, "hello");
    const b = std.hash.XxHash64.hash(0, "world");
    try std.testing.expect(a != b);
}

test "key64: deterministic — same input same output" {
    try std.testing.expectEqual(key64("hello"), key64("hello"));
    try std.testing.expectEqual(key64(""), key64(""));
    try std.testing.expectEqual(key64("안녕"), key64("안녕"));
}

test "key64: different input → different output (usually)" {
    const a = key64("alpha");
    const b = key64("beta");
    try std.testing.expect(a != b);
}

test "key64: matches XxHash64 standard value" {
    // xxhash64(seed=0) of empty string = 0xEF46DB3751D8E999
    try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), key64(""));
}