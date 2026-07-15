//! Binary Fuse Filter — pure Zig implementation, generalized fingerprint width.
//!
//! Zig port of C reference implementation from fastfilter `binaryfusefilter.h`
//! (Thomas Mueller Graf, Daniel Lemire), extended with a runtime-selectable
//! fingerprint width (8~16 bits) stored as a bit-packed array. Shares identical
//! Zig hash code for population and lookup then eliminates bit mismatch risk.
//!
//! False positive rate ≈ 2^-w for fingerprint width w. Fixed 3 lookups.
//!
//! Two hash layers:
//!   1. chaza level (application): token → xxhash64 → u64 key (hash.zig key64)
//!   2. filter level (internal): key → murmur64(key+seed) → 3 positions + w-bit fingerprint

const std = @import("std");

const ARITY: u32 = 3;
const MAX_ITERATIONS: u32 = 100;

pub const MIN_FINGERPRINT_BITS: u5 = 8;
pub const MAX_FINGERPRINT_BITS: u5 = 16;

// ── Serialization blob header (32 bytes, little-endian) ──
// segment_length_mask = segment_length - 1 (derivable, not stored).
//
// Blob header layout (offsets 0-31):
//   Offset 0-7:   seed (u64) - used by BinaryFuseView.fromBlob
//   Offset 8-11:  size (u32) - stored but NOT read at lookup (debug/tooling)
//   Offset 12-15: segment_length (u32) - used by BinaryFuseView.fromBlob
//   Offset 16-19: segment_count (u32) - stored but NOT read at lookup
//   Offset 20-23: segment_count_length (u32) - used by BinaryFuseView.fromBlob
//   Offset 24-27: array_length (u32) - used by BinaryFuseView.fromBlob
//   Offset 28:    fingerprint_bits (u8) - used by BinaryFuseView.fromBlob
//   Offset 29-31: zero padding
//   Offset 32+:   bit-packed fingerprints (ceil(array_length * bits / 8) bytes)

pub const FUSE_BLOB_HEADER_SIZE: usize = 32;

/// ── Hash utilities (same algorithm as C reference) ──

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

/// Mix key + seed (C binary_fuse_mix_split).
inline fn mixSplit(key: u64, seed: u64) u64 {
    return murmur64(key +% seed);
}

/// w-bit fingerprint (generalizes C binary_fuse8_fingerprint).
inline fn fingerprintW(hash: u64, bits: u5) u16 {
    const mask: u32 = (@as(u32, 1) << bits) - 1;
    return @intCast((@as(u32, @truncate(hash ^ (hash >> 32)))) & mask);
}

/// Upper 64 bits of 64×64 multiplication (C binary_fuse_mulhi).
/// Zig u128 arithmetic guarantees same result as C __uint128_t.
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

/// Calculate 3 hash positions for single key (C binary_fuse8_hash).
/// index ∈ {0, 1, 2}.
inline fn hashPosition(index: u64, hash: u64, seg_len: u32, seg_count_len: u32, seg_len_mask: u32) u32 {
    var h = mulhi(hash, seg_count_len);
    h +%= index * @as(u64, seg_len);
    const hh = hash & ((@as(u64, 1) << 36) - 1);
    const shift: u6 = @intCast(36 - 18 * index);
    h ^= (hh >> shift) & @as(u64, seg_len_mask);
    return @truncate(h);
}

/// Calculate all three positions at once (C binary_fuse8_hash_batch).
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

// ── Bit-packed fingerprint array ──
//
// Element i occupies bits [i*w, i*w + w). Reads/writes touch at most 3 bytes
// (w ≤ 16, bit offset within byte ≤ 7 → 7 + 16 = 23 bits). Bounds-guarded so
// the final element may end exactly at the buffer edge.

/// Byte count of a packed array holding `count` elements of `bits` width.
pub inline fn packedLen(count: u32, bits: u5) usize {
    return (@as(usize, count) * bits + 7) / 8;
}

inline fn packedGet(bytes: []const u8, bits: u5, i: u32) u16 {
    const bit: u64 = @as(u64, i) * bits;
    const byte: usize = @intCast(bit >> 3);
    const shift: u5 = @intCast(bit & 7);
    var v: u32 = bytes[byte];
    if (byte + 1 < bytes.len) v |= @as(u32, bytes[byte + 1]) << 8;
    if (byte + 2 < bytes.len) v |= @as(u32, bytes[byte + 2]) << 16;
    const mask: u32 = (@as(u32, 1) << bits) - 1;
    return @intCast((v >> shift) & mask);
}

inline fn packedSet(bytes: []u8, bits: u5, i: u32, val: u16) void {
    const bit: u64 = @as(u64, i) * bits;
    const byte: usize = @intCast(bit >> 3);
    const shift: u5 = @intCast(bit & 7);
    const mask: u32 = ((@as(u32, 1) << bits) - 1) << shift;
    var v: u32 = bytes[byte];
    if (byte + 1 < bytes.len) v |= @as(u32, bytes[byte + 1]) << 8;
    if (byte + 2 < bytes.len) v |= @as(u32, bytes[byte + 2]) << 16;
    v = (v & ~mask) | (@as(u32, val) << shift);
    bytes[byte] = @truncate(v);
    if (byte + 1 < bytes.len) bytes[byte + 1] = @truncate(v >> 8);
    if (byte + 2 < bytes.len) bytes[byte + 2] = @truncate(v >> 16);
}

// ── Parameter calculation (C binary_fuse_calculate_*) ──

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

/// Calculate filter parameters from key count (no allocation).
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

/// Total blob size in bytes for a filter holding `size` keys at `bits` width
/// (32-byte header + bit-packed fingerprints).
pub fn blobSize(size: u32, bits: u5) usize {
    return FUSE_BLOB_HEADER_SIZE + packedLen(computeParams(size).array_length, bits);
}

// ── Owned filter (for generator) ──

pub const BinaryFuse = struct {
    seed: u64,
    size: u32,
    segment_length: u32,
    segment_count: u32,
    segment_count_length: u32,
    array_length: u32,
    fingerprint_bits: u5,
    /// Bit-packed fingerprint array (packedLen(array_length, fingerprint_bits) bytes).
    fingerprints: []u8,
    allocator: std.mem.Allocator,

    inline fn segLenMask(self: BinaryFuse) u32 {
        return self.segment_length - 1;
    }

    /// Allocate filter capable of holding `size` keys with `bits`-wide fingerprints.
    pub fn init(allocator: std.mem.Allocator, size: u32, bits: u5) !BinaryFuse {
        std.debug.assert(bits >= MIN_FINGERPRINT_BITS and bits <= MAX_FINGERPRINT_BITS);
        const p = computeParams(size);
        const fingerprints = try allocator.alloc(u8, packedLen(p.array_length, bits));
        @memset(fingerprints, 0);

        return .{
            .seed = 0,
            .size = size,
            .segment_length = p.segment_length,
            .segment_count = p.segment_count,
            .segment_count_length = p.segment_count_length,
            .array_length = p.array_length,
            .fingerprint_bits = bits,
            .fingerprints = fingerprints,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BinaryFuse) void {
        self.allocator.free(self.fingerprints);
    }

    /// Returns true if the key is (probably) in the set. False positive rate ≈ 2^-bits.
    pub fn contains(self: BinaryFuse, key: u64) bool {
        const hash = mixSplit(key, self.seed);
        const f = fingerprintW(hash, self.fingerprint_bits);
        const hb = hashBatch(hash, self.segment_length, self.segment_count_length, self.segLenMask());
        const result = f ^
            packedGet(self.fingerprints, self.fingerprint_bits, hb.h0) ^
            packedGet(self.fingerprints, self.fingerprint_bits, hb.h1) ^
            packedGet(self.fingerprints, self.fingerprint_bits, hb.h2);
        return result == 0;
    }

    /// Populate the filter. `keys` may be mutated (sorted/deduplicated in place).
    pub fn populate(self: *BinaryFuse, keys: []u64) !void {
        var size: u32 = @intCast(keys.len);
        if (size != self.size) return error.SizeMismatch;

        if (size == 0) return; // empty filter - nothing to populate

        const a = self.allocator;
        const capacity = self.array_length;

        var rng_counter: u64 = 0x726b2b9d438b9d4d;
        self.seed = rngSplitmix64(&rng_counter);

        // C reference callocs reverse_order/t2count/t2hash (read-before-write in the
        // counting loop); alone/reverse_h are malloc'd there (write-before-read).
        const reverse_order = try a.alloc(u64, size + 1);
        defer a.free(reverse_order);
        const alone = try a.alloc(u32, capacity);
        defer a.free(alone);
        const t2count = try a.alloc(u8, capacity);
        defer a.free(t2count);
        @memset(t2count, 0);
        const reverse_h = try a.alloc(u8, size);
        defer a.free(reverse_h);
        const t2hash = try a.alloc(u64, capacity);
        defer a.free(t2hash);
        @memset(t2hash, 0);

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

            // Initialize startPos
            for (0..block) |i| {
                start_pos[i] = @intCast((@as(u64, @intCast(i)) * @as(u64, size)) >> block_bits);
            }

            // Distribute hashes into segments
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

            // Count occurrences
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

                // Duplicate detection
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

            // Peel the hypergraph
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

        // Assign fingerprints (in reverse peeling order)
        const bits = self.fingerprint_bits;
        var i: u32 = size;
        while (i > 0) {
            i -= 1;
            const hash = reverse_order[i];
            const xor2 = fingerprintW(hash, bits);
            const found = reverse_h[i];
            h012[0] = hashPosition(0, hash, seg_len, seg_count_len, seg_len_mask);
            h012[1] = hashPosition(1, hash, seg_len, seg_count_len, seg_len_mask);
            h012[2] = hashPosition(2, hash, seg_len, seg_count_len, seg_len_mask);
            h012[3] = h012[0];
            h012[4] = h012[1];
            packedSet(self.fingerprints, bits, h012[found], xor2 ^
                packedGet(self.fingerprints, bits, h012[found + 1]) ^
                packedGet(self.fingerprints, bits, h012[found + 2]));
        }
    }

    /// Total serialized blob byte count = 32 (header) + packed fingerprint bytes.
    pub fn blobBytes(self: BinaryFuse) usize {
        return FUSE_BLOB_HEADER_SIZE + self.fingerprints.len;
    }

    /// Write blob header + fingerprints to buf. buf.len >= blobBytes required.
    pub fn writeBlob(self: BinaryFuse, buf: []u8) void {
        std.debug.assert(buf.len >= self.blobBytes());
        std.mem.writeInt(u64, buf[0..8], self.seed, .little);
        std.mem.writeInt(u32, buf[8..12], self.size, .little);
        std.mem.writeInt(u32, buf[12..16], self.segment_length, .little);
        std.mem.writeInt(u32, buf[16..20], self.segment_count, .little);
        std.mem.writeInt(u32, buf[20..24], self.segment_count_length, .little);
        std.mem.writeInt(u32, buf[24..28], self.array_length, .little);
        buf[28] = self.fingerprint_bits;
        buf[29] = 0;
        buf[30] = 0;
        buf[31] = 0;
        @memcpy(buf[32..][0..self.fingerprints.len], self.fingerprints);
    }
};

/// Remove duplicates from keys (sort then adjacent comparison). Return new length.
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

// ── zero-copy view (for runtime) ──

/// Create view from serialized blob bytes. No allocation.
pub const BinaryFuseView = struct {
    seed: u64,
    segment_length: u32,
    segment_count_length: u32,
    segment_length_mask: u32,
    fingerprint_bits: u5,
    /// Bit-packed fingerprint array.
    fingerprints: []const u8,

    /// Parse view from blob bytes. null if blob too short or width invalid.
    pub fn fromBlob(blob: []const u8) ?BinaryFuseView {
        if (blob.len < FUSE_BLOB_HEADER_SIZE) return null;
        const seed = std.mem.readInt(u64, blob[0..8], .little);
        const seg_len = std.mem.readInt(u32, blob[12..16], .little);
        const seg_count_len = std.mem.readInt(u32, blob[20..24], .little);
        const array_length = std.mem.readInt(u32, blob[24..28], .little);
        const bits_raw = blob[28];
        if (bits_raw < MIN_FINGERPRINT_BITS or bits_raw > MAX_FINGERPRINT_BITS) return null;
        const bits: u5 = @intCast(bits_raw);
        const fp_len = packedLen(array_length, bits);
        if (blob.len < FUSE_BLOB_HEADER_SIZE + fp_len) return null;
        const fingerprints = blob[FUSE_BLOB_HEADER_SIZE..][0..fp_len];
        return .{
            .seed = seed,
            .segment_length = seg_len,
            .segment_count_length = seg_count_len,
            .segment_length_mask = seg_len - 1,
            .fingerprint_bits = bits,
            .fingerprints = fingerprints,
        };
    }

    /// Is key in set?
    pub fn contains(self: BinaryFuseView, key: u64) bool {
        const hash = mixSplit(key, self.seed);
        const f = fingerprintW(hash, self.fingerprint_bits);
        const hb = hashBatch(hash, self.segment_length, self.segment_count_length, self.segment_length_mask);
        const result = f ^
            packedGet(self.fingerprints, self.fingerprint_bits, hb.h0) ^
            packedGet(self.fingerprints, self.fingerprint_bits, hb.h1) ^
            packedGet(self.fingerprints, self.fingerprint_bits, hb.h2);
        return result == 0;
    }
};

// ── Assertion tests ────────────────────────────────────────────────────

test "packedGet/packedSet: roundtrip across widths and offsets" {
    var buf: [64]u8 = .{0} ** 64;
    const widths = [_]u5{ 8, 9, 10, 11, 13, 16 };
    for (widths) |w| {
        @memset(&buf, 0);
        const count: u32 = @intCast((buf.len * 8) / w);
        const mask: u16 = @intCast((@as(u32, 1) << w) - 1);
        // write a distinctive pattern to every slot, then read all back
        for (0..count) |i| {
            const val: u16 = @intCast((i *% 2654435761) & mask);
            packedSet(&buf, w, @intCast(i), val);
        }
        for (0..count) |i| {
            const val: u16 = @intCast((i *% 2654435761) & mask);
            try std.testing.expectEqual(val, packedGet(&buf, w, @intCast(i)));
        }
    }
}

test "packedSet: neighbors survive interleaved writes (no bit bleed)" {
    var buf: [16]u8 = .{0} ** 16;
    const w: u5 = 11;
    packedSet(&buf, w, 0, 0x7FF);
    packedSet(&buf, w, 2, 0x555);
    packedSet(&buf, w, 1, 0x2AA);
    try std.testing.expectEqual(@as(u16, 0x7FF), packedGet(&buf, w, 0));
    try std.testing.expectEqual(@as(u16, 0x2AA), packedGet(&buf, w, 1));
    try std.testing.expectEqual(@as(u16, 0x555), packedGet(&buf, w, 2));
}

test "populate: output independent of allocator memory contents (uninit t2count/t2hash regression)" {
    // C reference callocs t2count/t2hash/reverse_order; a port that plain-allocs
    // them reads garbage on the first iteration. Building the same key set on
    // top of 0x00-filled vs 0xFF-filled memory must yield byte-identical blobs.
    var keys: [200]u64 = undefined;
    for (&keys, 0..) |*k, i| k.* = @as(u64, i) *% 0x9E3779B97F4A7C15;

    var blobs: [2][]u8 = undefined;
    var bufs: [2][64 * 1024]u8 = undefined;
    var storage: [2][blobSize(200, 8)]u8 = undefined;

    for (0..2) |round| {
        @memset(&bufs[round], if (round == 0) 0x00 else 0xFF);
        var fba = std.heap.FixedBufferAllocator.init(&bufs[round]);
        const a = fba.allocator();

        var keys_copy = keys;
        var f = try BinaryFuse.init(a, keys.len, 8);
        defer f.deinit();
        try f.populate(&keys_copy);

        f.writeBlob(storage[round][0..f.blobBytes()]);
        blobs[round] = storage[round][0..f.blobBytes()];

        for (keys) |k| try std.testing.expect(f.contains(k));
    }

    try std.testing.expectEqualSlices(u8, blobs[0], blobs[1]);
}

test "calculateSegmentLength: size=0 → 4" {
    try std.testing.expectEqual(@as(u32, 4), calculateSegmentLength(0));
}

test "computeParams: size=0 → minimum filter" {
    const p = computeParams(0);
    try std.testing.expectEqual(@as(u32, 4), p.segment_length);
    // segment_count=1, array_length = (1+2)*4 = 12
    try std.testing.expectEqual(@as(u32, 1), p.segment_count);
    try std.testing.expectEqual(@as(u32, 12), p.array_length);
}

test "blobSize: size=0 → 32 + 12 (8-bit) / 32 + 24 (16-bit)" {
    try std.testing.expectEqual(@as(usize, 44), blobSize(0, 8));
    try std.testing.expectEqual(@as(usize, 56), blobSize(0, 16));
}

test "blobSize: monotonically increasing (approximately)" {
    const widths = [_]u5{ 8, 10, 16 };
    for (widths) |w| {
        const s0 = blobSize(0, w);
        const s10 = blobSize(10, w);
        const s100 = blobSize(100, w);
        const s1000 = blobSize(1000, w);
        try std.testing.expect(s0 <= s10);
        try std.testing.expect(s10 <= s100);
        try std.testing.expect(s100 <= s1000);
    }
}

test "blobSize: wider fingerprints scale packed bytes proportionally" {
    const p = computeParams(10000);
    const bytes8 = blobSize(10000, 8) - FUSE_BLOB_HEADER_SIZE;
    const bytes10 = blobSize(10000, 10) - FUSE_BLOB_HEADER_SIZE;
    const bytes16 = blobSize(10000, 16) - FUSE_BLOB_HEADER_SIZE;
    try std.testing.expectEqual(@as(usize, p.array_length), bytes8);
    try std.testing.expectEqual(packedLen(p.array_length, 10), bytes10);
    try std.testing.expectEqual(@as(usize, p.array_length) * 2, bytes16);
}

test "calculateSegmentLength: power of 2" {
    const seg = calculateSegmentLength(1000);
    try std.testing.expect(seg > 0);
    // Verify power of 2
    try std.testing.expect((seg & (seg - 1)) == 0);
}

test "calculateSegmentLength: upper limit bound even for large n" {
    const seg = calculateSegmentLength(10_000_000);
    try std.testing.expect(seg > 0);
    try std.testing.expect(seg <= 262144);
    try std.testing.expect((seg & (seg - 1)) == 0); // power of 2
}

test "BinaryFuse: empty filter (size=0) — non-inserted keys mostly false" {
    var f = try BinaryFuse.init(std.testing.allocator, 0, 8);
    defer f.deinit();
    try f.populate(&.{});
    // All fingerprints in empty filter are 0. contains(key) true only if fingerprintW(hash)==0 (≈0.4%).
    var false_count: u32 = 0;
    for (0..1000) |i| {
        if (!f.contains(@as(u64, i))) false_count += 1;
    }
    try std.testing.expect(false_count > 900);
}

test "BinaryFuse: single key" {
    var f = try BinaryFuse.init(std.testing.allocator, 1, 10);
    defer f.deinit();
    var keys = [_]u64{12345};
    try f.populate(&keys);
    try std.testing.expect(f.contains(12345));
}

test "BinaryFuse: multiple keys — all inserted keys true (all widths)" {
    const widths = [_]u5{ 8, 9, 10, 11, 16 };
    for (widths) |w| {
        const n: u32 = 100;
        var f = try BinaryFuse.init(std.testing.allocator, n, w);
        defer f.deinit();

        var keys: [100]u64 = undefined;
        for (0..n) |i| keys[i] = @as(u64, i * 1000 + 7);
        try f.populate(&keys);

        for (keys) |k| {
            try std.testing.expect(f.contains(k));
        }
    }
}

test "BinaryFuse: false positive rate ≈ 2^-w per width" {
    // 50k inserted keys, 200k non-inserted probes. Expected FP counts:
    // w=8 → ~781, w=9 → ~391, w=10 → ~195, w=11 → ~98, w=16 → ~3. Verify
    // each within a generous factor-2 band (chi-square noise stays well inside it).
    const n: u32 = 50000;
    const probes: u32 = 200000;
    const widths = [_]u5{ 8, 9, 10, 11, 16 };
    const expected = [_]f64{ 781.25, 390.6, 195.3, 97.7, 3.05 };

    const keys_buf = try std.testing.allocator.alloc(u64, n);
    defer std.testing.allocator.free(keys_buf);

    for (widths, expected) |w, exp| {
        for (0..n) |i| keys_buf[i] = @as(u64, i) * 2; // even keys inserted
        var f = try BinaryFuse.init(std.testing.allocator, n, w);
        defer f.deinit();
        try f.populate(keys_buf);

        var fp: u32 = 0;
        for (0..probes) |i| {
            const odd_key = @as(u64, i) * 2 + 1; // never inserted
            if (f.contains(odd_key)) fp += 1;
        }
        const fpf = @as(f64, @floatFromInt(fp));
        try std.testing.expect(fpf < exp * 2.0 + 10.0);
        try std.testing.expect(fpf > exp / 2.0 - 5.0);
    }
}

test "BinaryFuse: serialize/deserialize roundtrip — identical lookup results (all widths)" {
    const widths = [_]u5{ 8, 9, 10, 11, 16 };
    for (widths) |w| {
        const n: u32 = 200;
        var f = try BinaryFuse.init(std.testing.allocator, n, w);
        defer f.deinit();

        var keys: [200]u64 = undefined;
        for (0..n) |i| keys[i] = @as(u64, i * 31 + 17);
        try f.populate(&keys);

        // Write blob
        const blob_size = f.blobBytes();
        const blob = try std.testing.allocator.alloc(u8, blob_size);
        defer std.testing.allocator.free(blob);
        f.writeBlob(blob);

        // Deserialize to view
        const view = BinaryFuseView.fromBlob(blob) orelse return error.UnexpectedNull;
        try std.testing.expectEqual(w, view.fingerprint_bits);

        // All inserted keys true
        for (keys) |k| {
            try std.testing.expect(view.contains(k));
        }
        // Non-inserted keys give same result as f.contains
        for (0..500) |i| {
            const k = @as(u64, i * 99 + 3);
            try std.testing.expectEqual(f.contains(k), view.contains(k));
        }
    }
}

test "BinaryFuse: large key set (1000) — all true" {
    const n: u32 = 1000;
    var f = try BinaryFuse.init(std.testing.allocator, n, 10);
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

test "BinaryFuse: same key set — deterministic (same seed to same result)" {
    const n: u32 = 50;
    const keys_a = try std.testing.allocator.alloc(u64, n);
    defer std.testing.allocator.free(keys_a);
    const keys_b = try std.testing.allocator.alloc(u64, n);
    defer std.testing.allocator.free(keys_b);
    for (0..n) |i| {
        keys_a[i] = @as(u64, i * 7 + 3);
        keys_b[i] = @as(u64, i * 7 + 3);
    }

    var f1 = try BinaryFuse.init(std.testing.allocator, n, 10);
    defer f1.deinit();
    try f1.populate(keys_a);

    var f2 = try BinaryFuse.init(std.testing.allocator, n, 10);
    defer f2.deinit();
    try f2.populate(keys_b);

    try std.testing.expectEqual(f1.seed, f2.seed);
    try std.testing.expectEqualSlices(u8, f1.fingerprints, f2.fingerprints);
}

test "BinaryFuseView.fromBlob: too short blob → null" {
    const tiny: [10]u8 = .{0} ** 10;
    try std.testing.expect(BinaryFuseView.fromBlob(&tiny) == null);
}

test "BinaryFuseView.fromBlob: invalid fingerprint width → null" {
    var f = try BinaryFuse.init(std.testing.allocator, 10, 8);
    defer f.deinit();
    var keys: [10]u64 = undefined;
    for (0..10) |i| keys[i] = @as(u64, i + 1);
    try f.populate(&keys);

    const blob = try std.testing.allocator.alloc(u8, f.blobBytes());
    defer std.testing.allocator.free(blob);
    f.writeBlob(blob);

    blob[28] = 0; // width below minimum
    try std.testing.expect(BinaryFuseView.fromBlob(blob) == null);
    blob[28] = 17; // width above maximum
    try std.testing.expect(BinaryFuseView.fromBlob(blob) == null);
}

test "BinaryFuseView.fromBlob: correct header parsing" {
    var f = try BinaryFuse.init(std.testing.allocator, 10, 11);
    defer f.deinit();
    var keys: [10]u64 = undefined;
    for (0..10) |i| keys[i] = @as(u64, i + 1);
    try f.populate(&keys);

    const blob = try std.testing.allocator.alloc(u8, f.blobBytes());
    defer std.testing.allocator.free(blob);
    f.writeBlob(blob);

    const view = BinaryFuseView.fromBlob(blob).?;
    try std.testing.expectEqual(f.seed, view.seed);
    try std.testing.expectEqual(f.segment_length, view.segment_length);
    try std.testing.expectEqual(f.segment_count_length, view.segment_count_length);
    try std.testing.expectEqual(f.fingerprint_bits, view.fingerprint_bits);
    try std.testing.expectEqual(f.fingerprints.len, view.fingerprints.len);
    try std.testing.expectEqualSlices(u8, f.fingerprints, view.fingerprints);
}

test "sortAndRemoveDup: remove duplicates" {
    var keys = [_]u64{ 5, 3, 5, 1, 3, 5, 2 };
    const new_len = sortAndRemoveDup(&keys, keys.len);
    try std.testing.expectEqual(@as(u32, 4), new_len);
    try std.testing.expectEqual(@as(u64, 1), keys[0]);
    try std.testing.expectEqual(@as(u64, 2), keys[1]);
    try std.testing.expectEqual(@as(u64, 3), keys[2]);
    try std.testing.expectEqual(@as(u64, 5), keys[3]);
}

test "BinaryFuse: duplicate keys detected during populate" {
    var keys = [_]u64{ 42, 42, 7, 7, 7, 100 };
    var f = try BinaryFuse.init(std.testing.allocator, keys.len, 10);
    defer f.deinit();
    try f.populate(&keys);

    try std.testing.expect(f.contains(42));
    try std.testing.expect(f.contains(7));
    try std.testing.expect(f.contains(100));
}
