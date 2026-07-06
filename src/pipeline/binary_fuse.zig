//! Binary Fuse Filter (BinaryFuse8) — pure Zig 구현.
//!
//! fastfilter `binaryfusefilter.h` (Thomas Mueller Graf, Daniel Lemire)의
//! C 참조 구현을 Zig로 포팅. 구성(populate)과 조회(contain)가 동일한
//! Zig 해시 코드를 공유 → C↔Zig 비트 불일치 위험 원천 제거.
//!
//! 8비트 지문 사용. 오탐률 ≈ 1/256 (0.4%). 조회 고정 3회.
//!
//! 두 층의 해시:
//!   ① chaza 레벨: 토큰 → xxhash64 → u64 키 (hash.zig key64)
//!   ② 필터 내부: 키 → murmur64(key+seed) → 3개 위치 + 8비트 지문

const std = @import("std");

const ARITY: u32 = 3;
const MAX_ITERATIONS: u32 = 100;

// ── 직렬화 blob 헤더 (28바이트, little-endian) ──
// DocEntry.filter_off가 가리키는 필터 데이터의 선두에 옴.
// segment_length_mask = segment_length - 1 (역산 가능, 저장 생략).

pub const FUSE_BLOB_HEADER_SIZE: usize = 28;

/// ── 해시 유틸리티 (C 참조와 동일 알고리즘) ──

/// murmur64 finalizer (C binary_fuse_murmur64).
inline fn murmur64(h: u64) u64 {
    var x = h;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

/// key + seed를 믹스 (C binary_fuse_mix_split).
inline fn mixSplit(key: u64, seed: u64) u64 {
    return murmur64(key +% seed);
}

/// 빠른 모듈러 감소 (C binary_fuse_reduce). hash * n >> 32.
inline fn reduce(hash: u32, n: u32) u32 {
    return @intCast((@as(u64, hash) * @as(u64, n)) >> 32);
}

/// 8비트 지문 (C binary_fuse8_fingerprint).
inline fn fingerprint8(hash: u64) u8 {
    return @truncate(hash ^ (hash >> 32));
}

/// 64×64 곱셈의 상위 64비트 (C binary_fuse_mulhi).
/// Zig u128 산술로 C __uint128_t와 동일 결과 보장.
inline fn mulhi(a: u64, b: u64) u64 {
    return @truncate((@as(u128, a) * @as(u128, b)) >> 64);
}

/// splitmix64 PRNG (C binary_fuse_rng_splitmix64).
inline fn rngSplitmix64(counter: *u64) u64 {
    counter.* +%= 0x9E3779B97F4A7C15;
    var z = counter.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

inline fn mod3(x: u8) u8 {
    return if (x > 2) x - 3 else x;
}

/// 단일 키의 3개 해시 위치 산출 (C binary_fuse8_hash).
/// index ∈ {0, 1, 2}.
inline fn hashPosition(index: u64, hash: u64, seg_len: u32, seg_count_len: u32, seg_len_mask: u32) u32 {
    var h = mulhi(hash, seg_count_len);
    h +%= index * @as(u64, seg_len);
    const hh = hash & ((@as(u64, 1) << 36) - 1);
    const shift: u6 = @intCast(36 - 18 * index);
    h ^= (hh >> shift) & @as(u64, seg_len_mask);
    return @truncate(h);
}

/// 세 위치를 한 번에 산출 (C binary_fuse8_hash_batch).
pub const HashBatch = struct { h0: u32, h1: u32, h2: u32 };

inline fn hashBatch(hash: u64, seg_len: u32, seg_count_len: u32, seg_len_mask: u32) HashBatch {
    const hi = mulhi(hash, seg_count_len);
    var ans: HashBatch = .{
        .h0 = @truncate(hi),
        .h1 = undefined,
        .h2 = undefined,
    };
    ans.h1 = ans.h0 + seg_len;
    ans.h2 = ans.h1 + seg_len;
    ans.h1 ^= @as(u32, @truncate(hash >> 18)) & seg_len_mask;
    ans.h2 ^= @as(u32, @truncate(hash)) & seg_len_mask;
    return ans;
}

// ── 파라미터 산출 (C binary_fuse_calculate_*) ──

fn calculateSegmentLength(size: u32) u32 {
    if (size == 0) return 4;
    const d = @log(@as(f64, @floatFromInt(size)));
    const exponent = @floor(d / @log(3.33) + 2.25);
    var seg: u32 = @as(u32, 1) << @as(u5, @intFromFloat(exponent));
    if (seg > 262144) seg = 262144;
    return seg;
}

fn calculateSizeFactor(size: u32) f64 {
    if (size <= 1) return 0;
    return @max(1.125, 0.875 + 0.25 * @log(1000000.0) / @log(@as(f64, @floatFromInt(size))));
}

/// 키 개수로부터 필터 파라미터 산출 (할당 없음).
pub const Params = struct {
    segment_length: u32,
    segment_count: u32,
    segment_count_length: u32,
    array_length: u32,
};

pub fn computeParams(size: u32) Params {
    const seg_len = calculateSegmentLength(size);
    const size_factor = calculateSizeFactor(size);
    const capacity: u32 = if (size <= 1) 0 else @intFromFloat(@round(@as(f64, @floatFromInt(size)) * size_factor));

    var init_seg_count: u32 = 0;
    if (capacity > 0) {
        init_seg_count = (capacity + seg_len - 1) / seg_len;
        if (init_seg_count >= ARITY) {
            init_seg_count -= ARITY - 1;
        }
    }

    var array_length: u32 = (init_seg_count + ARITY - 1) * seg_len;
    var seg_count: u32 = if (array_length == 0) 0 else (array_length + seg_len - 1) / seg_len;
    if (seg_count <= ARITY - 1) {
        seg_count = 1;
    } else {
        seg_count -= ARITY - 1;
    }
    array_length = (seg_count + ARITY - 1) * seg_len;
    const seg_count_length = seg_count * seg_len;

    return .{
        .segment_length = seg_len,
        .segment_count = seg_count,
        .segment_count_length = seg_count_length,
        .array_length = array_length,
    };
}

/// 키 개수로부터 blob 전체 바이트 수 (28 헤더 + 지문).
pub fn blobSize(size: u32) usize {
    return FUSE_BLOB_HEADER_SIZE + computeParams(size).array_length;
}

// ── 소유형 필터 (생성기용) ──

pub const BinaryFuse8 = struct {
    seed: u64,
    size: u32,
    segment_length: u32,
    segment_count: u32,
    segment_count_length: u32,
    array_length: u32,
    fingerprints: []u8,
    allocator: std.mem.Allocator,

    inline fn segLenMask(self: BinaryFuse8) u32 {
        return self.segment_length - 1;
    }

    /// size개 키를 담을 수 있는 필터 할당.
    pub fn init(allocator: std.mem.Allocator, size: u32) !BinaryFuse8 {
        const p = computeParams(size);
        const fingerprints = try allocator.alloc(u8, p.array_length);
        @memset(fingerprints, 0);

        return .{
            .seed = 0,
            .size = size,
            .segment_length = p.segment_length,
            .segment_count = p.segment_count,
            .segment_count_length = p.segment_count_length,
            .array_length = p.array_length,
            .fingerprints = fingerprints,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BinaryFuse8) void {
        self.allocator.free(self.fingerprints);
    }

    /// key가 집합에 있는가? (오탐 가능 ≈ 0.4%)
    pub fn contains(self: BinaryFuse8, key: u64) bool {
        const hash = mixSplit(key, self.seed);
        const f = fingerprint8(hash);
        const hb = hashBatch(hash, self.segment_length, self.segment_count_length, self.segLenMask());
        const result = f ^ self.fingerprints[hb.h0] ^ self.fingerprints[hb.h1] ^ self.fingerprints[hb.h2];
        return result == 0;
    }

    /// keys로 필터 구성. keys는 변경될 수 있음 (중복 제거 시 재정렬).
    pub fn populate(self: *BinaryFuse8, keys: []u64) !void {
        var size: u32 = @intCast(keys.len);
        if (size != self.size) return error.SizeMismatch;

        if (size == 0) return; // 빈 필터

        const a = self.allocator;
        const capacity = self.array_length;

        var rng_counter: u64 = 0x726b2b9d438b9d4d;
        self.seed = rngSplitmix64(&rng_counter);

        const reverse_order = try a.alloc(u64, size + 1);
        defer a.free(reverse_order);
        const alone = try a.alloc(u32, capacity);
        defer a.free(alone);
        const t2count = try a.alloc(u8, capacity);
        defer a.free(t2count);
        const reverse_h = try a.alloc(u8, size);
        defer a.free(reverse_h);
        const t2hash = try a.alloc(u64, capacity);
        defer a.free(t2hash);

        var block_bits: u5 = 1;
        while ((@as(u64, 1) << block_bits) < self.segment_count) {
            block_bits += 1;
        }
        const block: u32 = @as(u32, 1) << block_bits;
        const start_pos = try a.alloc(u32, block);
        defer a.free(start_pos);

        var h012: [5]u32 = .{ 0, 0, 0, 0, 0 };

        @memset(reverse_order, 0);
        reverse_order[size] = 1; // sentinel

        const seg_len = self.segment_length;
        const seg_count_len = self.segment_count_length;
        const seg_len_mask = self.segLenMask();

        var loop: u32 = 0;
        while (true) : (loop += 1) {
            if (loop + 1 > MAX_ITERATIONS) return error.ConstructionFailed;

            // startPos 초기화
            for (0..block) |i| {
                start_pos[i] = @intCast((@as(u64, @intCast(i)) * @as(u64, size)) >> block_bits);
            }

            // 해시 분배
            const mask_block: u32 = block - 1;
            for (0..size) |i| {
                const hash = murmur64(keys[i] +% self.seed);
                var seg_idx: u32 = @intCast(hash >> @as(u6, @intCast(64 - @as(u32, block_bits))));
                while (reverse_order[start_pos[seg_idx]] != 0) {
                    seg_idx += 1;
                    seg_idx &= mask_block;
                }
                reverse_order[start_pos[seg_idx]] = hash;
                start_pos[seg_idx] += 1;
            }

            // 카운팅
            var err: bool = false;
            var duplicates: u32 = 0;
            for (0..size) |i| {
                const hash = reverse_order[i];
                const h0 = hashPosition(0, hash, seg_len, seg_count_len, seg_len_mask);
                t2count[h0] +%= 4;
                t2hash[h0] ^= hash;
                const h1 = hashPosition(1, hash, seg_len, seg_count_len, seg_len_mask);
                t2count[h1] +%= 4;
                t2count[h1] ^= 1;
                t2hash[h1] ^= hash;
                const h2 = hashPosition(2, hash, seg_len, seg_count_len, seg_len_mask);
                t2count[h2] +%= 4;
                t2hash[h2] ^= hash;
                t2count[h2] ^= 2;

                // 중복 검출
                if ((t2hash[h0] & t2hash[h1] & t2hash[h2]) == 0) {
                    if ((t2hash[h0] == 0 and t2count[h0] == 8) or
                        (t2hash[h1] == 0 and t2count[h1] == 8) or
                        (t2hash[h2] == 0 and t2count[h2] == 8))
                    {
                        duplicates += 1;
                        t2count[h0] -%= 4;
                        t2hash[h0] ^= hash;
                        t2count[h1] -%= 4;
                        t2count[h1] ^= 1;
                        t2hash[h1] ^= hash;
                        t2count[h2] -%= 4;
                        t2count[h2] ^= 2;
                        t2hash[h2] ^= hash;
                    }
                }
                if (t2count[h0] < 4) err = true;
                if (t2count[h1] < 4) err = true;
                if (t2count[h2] < 4) err = true;
            }

            if (err) {
                @memset(reverse_order[0..size], 0);
                @memset(t2count, 0);
                @memset(t2hash, 0);
                self.seed = rngSplitmix64(&rng_counter);
                continue;
            }

            // 필링 (peeling)
            var q_size: u32 = 0;
            for (0..capacity) |i| {
                alone[q_size] = @intCast(i);
                if ((t2count[i] >> 2) == 1) q_size += 1;
            }

            var stack_size: u32 = 0;
            while (q_size > 0) {
                q_size -= 1;
                const index = alone[q_size];
                if ((t2count[index] >> 2) == 1) {
                    const hash = t2hash[index];
                    h012[1] = hashPosition(1, hash, seg_len, seg_count_len, seg_len_mask);
                    h012[2] = hashPosition(2, hash, seg_len, seg_count_len, seg_len_mask);
                    h012[3] = hashPosition(0, hash, seg_len, seg_count_len, seg_len_mask);
                    h012[4] = h012[1];
                    const found = t2count[index] & 3;
                    reverse_h[stack_size] = found;
                    reverse_order[stack_size] = hash;
                    stack_size += 1;

                    const other1 = h012[found + 1];
                    alone[q_size] = other1;
                    if ((t2count[other1] >> 2) == 2) q_size += 1;
                    t2count[other1] -%= 4;
                    t2count[other1] ^= mod3(found + 1);
                    t2hash[other1] ^= hash;

                    const other2 = h012[found + 2];
                    alone[q_size] = other2;
                    if ((t2count[other2] >> 2) == 2) q_size += 1;
                    t2count[other2] -%= 4;
                    t2count[other2] ^= mod3(found + 2);
                    t2hash[other2] ^= hash;
                }
            }

            if (stack_size + duplicates == size) {
                size = stack_size;
                break;
            }

            if (duplicates > 0) {
                size = sortAndRemoveDup(keys, size);
            }
            @memset(reverse_order[0..size], 0);
            @memset(t2count, 0);
            @memset(t2hash, 0);
            self.seed = rngSplitmix64(&rng_counter);
        }

        // 지문 할당 (역순)
        var i: u32 = size;
        while (i > 0) {
            i -= 1;
            const hash = reverse_order[i];
            const xor2 = fingerprint8(hash);
            const found = reverse_h[i];
            h012[0] = hashPosition(0, hash, seg_len, seg_count_len, seg_len_mask);
            h012[1] = hashPosition(1, hash, seg_len, seg_count_len, seg_len_mask);
            h012[2] = hashPosition(2, hash, seg_len, seg_count_len, seg_len_mask);
            h012[3] = h012[0];
            h012[4] = h012[1];
            self.fingerprints[h012[found]] = @truncate(
                @as(u32, xor2) ^
                    @as(u32, self.fingerprints[h012[found + 1]]) ^
                    @as(u32, self.fingerprints[h012[found + 2]]),
            );
        }
    }

    /// 직렬화 blob 전체 바이트 수 = 28 (헤더) + array_length (지문).
    pub fn blobBytes(self: BinaryFuse8) usize {
        return FUSE_BLOB_HEADER_SIZE + self.array_length;
    }

    /// blob 헤더 + 지문을 buf에 기록. buf.len >= blobBytes여야 함.
    pub fn writeBlob(self: BinaryFuse8, buf: []u8) void {
        std.debug.assert(buf.len >= self.blobBytes());
        std.mem.writeInt(u64, buf[0..8], self.seed, .little);
        std.mem.writeInt(u32, buf[8..12], self.size, .little);
        std.mem.writeInt(u32, buf[12..16], self.segment_length, .little);
        std.mem.writeInt(u32, buf[16..20], self.segment_count, .little);
        std.mem.writeInt(u32, buf[20..24], self.segment_count_length, .little);
        std.mem.writeInt(u32, buf[24..28], self.array_length, .little);
        @memcpy(buf[28..][0..self.array_length], self.fingerprints);
    }
};

/// keys에서 중복 제거 (정렬 후 인접 비교). 새 길이 반환.
fn sortAndRemoveDup(keys: []u64, len: usize) u32 {
    std.mem.sort(u64, keys[0..len], {}, std.sort.asc(u64));
    if (len <= 1) return @intCast(len);
    var j: usize = 1;
    var i: usize = 1;
    while (i < len) : (i += 1) {
        if (keys[i] != keys[i - 1]) {
            keys[j] = keys[i];
            j += 1;
        }
    }
    return @intCast(j);
}

// ── zero-copy 뷰 (런타임용) ──

/// 직렬화된 blob 바이트에서 뷰 생성. 할당 없음.
pub const BinaryFuse8View = struct {
    seed: u64,
    segment_length: u32,
    segment_count_length: u32,
    segment_length_mask: u32,
    fingerprints: []const u8,

    /// blob 바이트에서 뷰 파싱. blob이 너무 짧으면 null.
    pub fn fromBlob(blob: []const u8) ?BinaryFuse8View {
        if (blob.len < FUSE_BLOB_HEADER_SIZE) return null;
        const seed = std.mem.readInt(u64, blob[0..8], .little);
        const seg_len = std.mem.readInt(u32, blob[12..16], .little);
        const seg_count_len = std.mem.readInt(u32, blob[20..24], .little);
        const array_length = std.mem.readInt(u32, blob[24..28], .little);
        if (blob.len < FUSE_BLOB_HEADER_SIZE + array_length) return null;
        const fingerprints = blob[28..][0..array_length];
        return .{
            .seed = seed,
            .segment_length = seg_len,
            .segment_count_length = seg_count_len,
            .segment_length_mask = seg_len - 1,
            .fingerprints = fingerprints,
        };
    }

    /// key가 집합에 있는가?
    pub fn contains(self: BinaryFuse8View, key: u64) bool {
        const hash = mixSplit(key, self.seed);
        const f = fingerprint8(hash);
        const hb = hashBatch(hash, self.segment_length, self.segment_count_length, self.segment_length_mask);
        const result = f ^ self.fingerprints[hb.h0] ^ self.fingerprints[hb.h1] ^ self.fingerprints[hb.h2];
        return result == 0;
    }
};

// ── 단정 테스트 ────────────────────────────────────────────────────

test "calculateSegmentLength: size=0 → 4" {
    try std.testing.expectEqual(@as(u32, 4), calculateSegmentLength(0));
}

test "computeParams: size=0 → 최소 필터" {
    const p = computeParams(0);
    try std.testing.expectEqual(@as(u32, 4), p.segment_length);
    // segment_count=1, array_length = (1+2)*4 = 12
    try std.testing.expectEqual(@as(u32, 1), p.segment_count);
    try std.testing.expectEqual(@as(u32, 12), p.array_length);
}

test "blobSize: size=0 → 28 + 12 = 40" {
    try std.testing.expectEqual(@as(usize, 40), blobSize(0));
}

test "blobSize: 단조 증가 (대략)" {
    const s0 = blobSize(0);
    const s10 = blobSize(10);
    const s100 = blobSize(100);
    const s1000 = blobSize(1000);
    try std.testing.expect(s0 <= s10);
    try std.testing.expect(s10 <= s100);
    try std.testing.expect(s100 <= s1000);
}

test "calculateSegmentLength: 2의 거듭제곱" {
    const seg = calculateSegmentLength(1000);
    try std.testing.expect(seg > 0);
    // 2의 거듭제곱 확인
    try std.testing.expect((seg & (seg - 1)) == 0);
}

test "calculateSegmentLength: 큰 n에서도 상한 이하" {
    const seg = calculateSegmentLength(10_000_000);
    try std.testing.expect(seg > 0);
    try std.testing.expect(seg <= 262144);
    try std.testing.expect((seg & (seg - 1)) == 0); // 2의 거듭제곱
}

test "BinaryFuse8: 빈 필터 (size=0) — 미삽입 키는 대부분 false" {
    var f = try BinaryFuse8.init(std.testing.allocator, 0);
    defer f.deinit();
    try f.populate(&.{});
    // 빈 필터의 모든 지문은 0. contains(key)는 fingerprint8(hash)==0일 때만 true (≈0.4%).
    // 여러 키를 시도해 대부분 false인지 확인.
    var false_count: u32 = 0;
    for (0..1000) |i| {
        if (!f.contains(@as(u64, i))) false_count += 1;
    }
    // 대부분 false (일부 오탐 허용)
    try std.testing.expect(false_count > 900);
}

test "BinaryFuse8: 단일 키" {
    var f = try BinaryFuse8.init(std.testing.allocator, 1);
    defer f.deinit();
    var keys = [_]u64{12345};
    try f.populate(&keys);
    try std.testing.expect(f.contains(12345));
}

test "BinaryFuse8: 여러 키 — 삽입한 키 전부 true" {
    const n: u32 = 100;
    var f = try BinaryFuse8.init(std.testing.allocator, n);
    defer f.deinit();

    var keys: [100]u64 = undefined;
    for (0..n) |i| keys[i] = @as(u64, i * 1000 + 7);
    try f.populate(&keys);

    for (keys) |k| {
        try std.testing.expect(f.contains(k));
    }
}

test "BinaryFuse8: 미삽입 키 — 대부분 false" {
    const n: u32 = 10000;
    var f = try BinaryFuse8.init(std.testing.allocator, n);
    defer f.deinit();

    var keys: [10000]u64 = undefined;
    for (0..n) |i| keys[i] = @as(u64, i * 2); // 짝수
    try f.populate(&keys);

    // 홀수는 삽입 안 함 → 오탐률 ≈ 0.4%
    var false_positives: u32 = 0;
    const test_count: u32 = 10000;
    for (0..test_count) |i| {
        const odd_key = @as(u64, i * 2 + 1);
        if (f.contains(odd_key)) false_positives += 1;
    }
    const fp_rate = @as(f64, @floatFromInt(false_positives)) / @as(f64, @floatFromInt(test_count));
    // 이론적 ≈ 0.0039 (0.39%). 여유 있게 2% 미만 확인.
    try std.testing.expect(fp_rate < 0.02);
}

test "BinaryFuse8: 직렬화/역직렬화 왕복 — 동일 조회 결과" {
    const n: u32 = 200;
    var f = try BinaryFuse8.init(std.testing.allocator, n);
    defer f.deinit();

    var keys: [200]u64 = undefined;
    for (0..n) |i| keys[i] = @as(u64, i * 31 + 17);
    try f.populate(&keys);

    // blob 기록
    const blob_size = f.blobBytes();
    const blob = try std.testing.allocator.alloc(u8, blob_size);
    defer std.testing.allocator.free(blob);
    f.writeBlob(blob);

    // 뷰로 역직렬화
    const view = BinaryFuse8View.fromBlob(blob) orelse return error.UnexpectedNull;

    // 삽입 키 전부 true
    for (keys) |k| {
        try std.testing.expect(view.contains(k));
    }
    // 미삽입 키는 f.contains와 동일 결과
    for (0..500) |i| {
        const k = @as(u64, i * 99 + 3);
        try std.testing.expectEqual(f.contains(k), view.contains(k));
    }
}

test "BinaryFuse8: 큰 키 집합 (1000) — 전체 true" {
    const n: u32 = 1000;
    var f = try BinaryFuse8.init(std.testing.allocator, n);
    defer f.deinit();

    var keys: [1000]u64 = undefined;
    for (0..n) |i| keys[i] = @as(u64, 0x1000_0000_0000_0000) | @as(u64, i);
    try f.populate(&keys);

    var all_found = true;
    for (keys) |k| {
        if (!f.contains(k)) {
            all_found = false;
            break;
        }
    }
    try std.testing.expect(all_found);
}

test "BinaryFuse8: 같은 키 집합 — 결정론적 (같은 seed → 같은 결과)" {
    const n: u32 = 50;
    const keys_a = try std.testing.allocator.alloc(u64, n);
    defer std.testing.allocator.free(keys_a);
    const keys_b = try std.testing.allocator.alloc(u64, n);
    defer std.testing.allocator.free(keys_b);
    for (0..n) |i| {
        keys_a[i] = @as(u64, i * 7 + 3);
        keys_b[i] = @as(u64, i * 7 + 3);
    }

    var f1 = try BinaryFuse8.init(std.testing.allocator, n);
    defer f1.deinit();
    try f1.populate(keys_a);

    var f2 = try BinaryFuse8.init(std.testing.allocator, n);
    defer f2.deinit();
    try f2.populate(keys_b);

    try std.testing.expectEqual(f1.seed, f2.seed);
    try std.testing.expectEqualSlices(u8, f1.fingerprints, f2.fingerprints);
}

test "BinaryFuse8View.fromBlob: 너무 짧은 blob → null" {
    const tiny: [10]u8 = .{0} ** 10;
    try std.testing.expect(BinaryFuse8View.fromBlob(&tiny) == null);
}

test "BinaryFuse8View.fromBlob: 올바른 헤더 파싱" {
    var f = try BinaryFuse8.init(std.testing.allocator, 10);
    defer f.deinit();
    var keys: [10]u64 = undefined;
    for (0..10) |i| keys[i] = @as(u64, i + 1);
    try f.populate(&keys);

    const blob = try std.testing.allocator.alloc(u8, f.blobBytes());
    defer std.testing.allocator.free(blob);
    f.writeBlob(blob);

    const view = BinaryFuse8View.fromBlob(blob).?;
    try std.testing.expectEqual(f.seed, view.seed);
    try std.testing.expectEqual(f.segment_length, view.segment_length);
    try std.testing.expectEqual(f.segment_count_length, view.segment_count_length);
    try std.testing.expectEqual(f.array_length, @as(u32, @intCast(view.fingerprints.len)));
    try std.testing.expectEqualSlices(u8, f.fingerprints, view.fingerprints);
}

test "sortAndRemoveDup: 중복 제거" {
    var keys = [_]u64{ 5, 3, 5, 1, 3, 5, 2 };
    const new_len = sortAndRemoveDup(&keys, keys.len);
    try std.testing.expectEqual(@as(u32, 4), new_len);
    try std.testing.expectEqual(@as(u64, 1), keys[0]);
    try std.testing.expectEqual(@as(u64, 2), keys[1]);
    try std.testing.expectEqual(@as(u64, 3), keys[2]);
    try std.testing.expectEqual(@as(u64, 5), keys[3]);
}
