//! Filter hash functions.
//!
//! key64: token bytes → xxhash64 → u64 key. Used for BinaryFuse filter.
//! xxhash64 (std.hash.XxHash64). seed=0 fixed.
//! Generator and runtime share same function → forces key consistency.

const std = @import("std");

/// xxhash64 seed (fixed).
const SEED: u64 = 0;

/// token bytes → u64 key (for BinaryFuse filter).
/// Generate 64-bit integer key via xxhash64. Same function for generator·runtime.
pub fn key64(data: []const u8) u64 {
    return std.hash.XxHash64.hash(SEED, data);
}

/// (token key, doc_id) → global-filter key. The v1.4 index keeps every
/// (token, document) pair in one corpus-wide filter; the doc_id is mixed
/// through the splitmix64 finalizer so consecutive ids spread over the full
/// 64-bit space before XOR with the token key. Same function for
/// generator·runtime.
pub fn pairKey(token_key: u64, doc_id: u32) u64 {
    var z = @as(u64, doc_id) +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return token_key ^ (z ^ (z >> 31));
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

test "pairKey: deterministic and doc-sensitive" {
    const k = key64("hello");
    try std.testing.expectEqual(pairKey(k, 7), pairKey(k, 7));
    // Same token, different docs → different keys
    try std.testing.expect(pairKey(k, 0) != pairKey(k, 1));
    // Different tokens, same doc → different keys
    try std.testing.expect(pairKey(key64("a"), 3) != pairKey(key64("b"), 3));
}

test "pairKey: doc_id=0 still mixed (not identity)" {
    const k = key64("hello");
    try std.testing.expect(pairKey(k, 0) != k);
}