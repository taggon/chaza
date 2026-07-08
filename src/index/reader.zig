//! chaza index reader: zero-parse slice view of serialized index bytes.
//!
//! IndexView doesn't own index bytes — caller manages buffer lifetime.
//! All offsets header-relative, each accessor validates slice bounds.
//! DocEntryPrefix.filter_off is filters section-relative.
//! title_off / url_off / MetaEntry.off are string_pool-relative.

const std = @import("std");
const fmt = @import("format.zig");

pub const Header = fmt.Header;
pub const DocEntryPrefix = fmt.DocEntryPrefix;
pub const MetaEntry = fmt.MetaEntry;
pub const MAGIC = fmt.MAGIC;
pub const VERSION = fmt.VERSION;
pub const HEADER_SIZE = fmt.HEADER_SIZE;

/// Index open failure reasons.
pub const OpenError = error{
    InvalidMagic,
    InvalidVersion,
    Truncated,
};

/// zero-parse view of serialized index bytes.
/// `bytes` caller-owned — must outlive IndexView.
/// All slice fields point inside `bytes`.
pub const IndexView = struct {
    bytes: []const u8,
    header: *const Header,
    /// Meta field name list raw bytes (NUL-terminated strings).
    meta_names: []const u8,
    /// Document metadata table raw bytes.
    doc_table: []const u8,
    /// String pool (title / url / meta values).
    string_pool: []const u8,
    /// Filter data (filter blobs).
    filters: []const u8,

    /// Open index bytes as view.
    /// Validate header magic/version + verify each section offset within bytes bounds.
    pub fn open(bytes: []const u8) OpenError!IndexView {
        if (bytes.len < HEADER_SIZE) return error.Truncated;

        const header: *const Header = @ptrCast(@alignCast(bytes.ptr));
        if (header.magic != MAGIC) return error.InvalidMagic;
        if (header.version != VERSION) return error.InvalidVersion;

        const names_off = header.meta_names_off;
        const doc_off = header.doc_table_off;
        const pool_off = header.string_pool_off;
        const filt_off = header.filters_off;
        const len: usize = bytes.len;

        // Verify each offset non-decreasing and within bytes bounds
        if (names_off > len or doc_off > len or pool_off > len or filt_off > len) return error.Truncated;
        if (!(names_off <= doc_off and doc_off <= pool_off and pool_off <= filt_off)) return error.Truncated;

        return .{
            .bytes = bytes,
            .header = header,
            .meta_names = bytes[names_off..doc_off],
            .doc_table = bytes[doc_off..pool_off],
            .string_pool = bytes[pool_off..filt_off],
            .filters = bytes[filt_off..len],
        };
    }

    /// One DocEntry byte stride = 24 + 8 * num_meta_fields.
    inline fn docStride(self: IndexView) usize {
        return fmt.docEntrySize(self.header.num_meta_fields);
    }

    /// DocEntryPrefix pointer by document id. null if doc_id >= num_docs or out of bounds.
    pub fn docEntry(self: IndexView, doc_id: u32) ?*const DocEntryPrefix {
        if (doc_id >= self.header.num_docs) return null;
        const base: usize = self.header.doc_table_off;
        const stride = self.docStride();
        const off = base + @as(usize, doc_id) * stride;
        if (off + @sizeOf(DocEntryPrefix) > self.bytes.len) return null;
        const ptr: [*]const u8 = self.bytes.ptr + off;
        return @ptrCast(@alignCast(ptr));
    }

    /// Document's meta entry slice. null if out of bounds.
    /// field_idx is user metadata_fields index (unrelated to title/url).
    pub fn docMetaEntries(self: IndexView, doc_id: u32) ?[]const MetaEntry {
        const prefix = self.docEntry(doc_id) orelse return null;
        const nmf: usize = self.header.num_meta_fields;
        if (nmf == 0) return &[_]MetaEntry{};
        const prefix_bytes: [*]const u8 = @ptrCast(prefix);
        const after: [*]const u8 = prefix_bytes + @sizeOf(DocEntryPrefix);
        const start_off = (@intFromPtr(after) - @intFromPtr(self.bytes.ptr));
        const need = nmf * @sizeOf(MetaEntry);
        if (start_off + need > self.bytes.len) return null;
        const meta_ptr: [*]const MetaEntry = @ptrCast(@alignCast(after));
        return meta_ptr[0..nmf];
    }

    /// Document title (within string_pool). null if doc_id out of bounds.
    pub fn title(self: IndexView, doc_id: u32) ?[]const u8 {
        const prefix = self.docEntry(doc_id) orelse return null;
        const off: usize = prefix.title_off;
        const ln: usize = prefix.title_len;
        if (off + ln > self.string_pool.len) return null;
        return self.string_pool[off .. off + ln];
    }

    /// Document URL (within string_pool). null if doc_id out of bounds.
    pub fn url(self: IndexView, doc_id: u32) ?[]const u8 {
        const prefix = self.docEntry(doc_id) orelse return null;
        const off: usize = prefix.url_off;
        const ln: usize = prefix.url_len;
        if (off + ln > self.string_pool.len) return null;
        return self.string_pool[off .. off + ln];
    }

    /// Filter blob slice (within filters section).
    pub fn docFilter(self: IndexView, doc_id: u32) ?[]const u8 {
        const prefix = self.docEntry(doc_id) orelse return null;
        const off: usize = prefix.filter_off;
        const ln: usize = prefix.filter_len;
        if (off + ln > self.filters.len) return null;
        return self.filters[off .. off + ln];
    }

    /// Specific meta field value (within string_pool). null if doc_id or field_idx is out of bounds.
    /// field_idx is user metadata_fields index (unrelated to title/url).
    pub fn metaValue(self: IndexView, doc_id: u32, field_idx: usize) ?[]const u8 {
        const metas = self.docMetaEntries(doc_id) orelse return null;
        if (field_idx >= metas.len) return null;
        const m = metas[field_idx];
        const off: usize = m.off;
        const ln: usize = m.len;
        if (off + ln > self.string_pool.len) return null;
        return self.string_pool[off .. off + ln];
    }

    /// Meta field name (idx-th NUL-terminated string). null if out of bounds.
    /// Upper bound checked by num_meta_fields — prevents misinterpreting zero padding as empty string.
    pub fn metaNameAt(self: IndexView, idx: usize) ?[]const u8 {
        if (idx >= self.header.num_meta_fields) return null;
        const region = self.meta_names;
        var i: usize = 0;
        var count: usize = 0;
        while (i < region.len) {
            const start = i;
            while (i < region.len and region[i] != 0) : (i += 1) {}
            if (i >= region.len) return null; // NUL termination missing → corrupted
            if (count == idx) return region[start..i];
            count += 1;
            i += 1; // skip NUL
        }
        return null;
    }
};

// ── Assertion tests ────────────────────────────────────────────────────
//
// Hand-coded fixture (96 bytes):
//
//   Offset   Section             Content
//   ─────────────────────────────────────────────────────
//   0        Header (32B)        magic / version / offsets
//   32       meta_names (8B)     "date\0" + 3B padding (align4)
//   40       doc_table (32B)     DocEntryPrefix(24B) + MetaEntry(8B)
//   72       string_pool (16B)   "Hi"(2) + "/a"(2) + "2026-01-01"(10) + 2B padding
//   88       filters (8B)        0xAA 0xBB 0xCC 0xDD 0xEE 0xFF 0x11 0x22
//   ─────────────────────────────────────────────────────
//   Total 96 bytes
//
// string_pool relative offsets:
//   title  → off=0,  len=2  ("Hi")
//   url    → off=2,  len=2  ("/a")
//   meta   → off=4,  len=10 ("2026-01-01")

const meta_name = "date";
const title_str = "Hi";
const url_str = "/a";
const meta_val = "2026-01-01";
const filter_bits = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22 };

const NAMES_RAW = meta_name.len + 1; // "date\0" = 5
const NAMES_SIZE = (NAMES_RAW + 3) & ~@as(usize, 3); // align4 → 8
const DOC_STRIDE = fmt.docEntrySize(1); // 24 + 8 = 32
const POOL_RAW = title_str.len + url_str.len + meta_val.len; // 2+2+10 = 14
const POOL_SIZE = (POOL_RAW + 3) & ~@as(usize, 3); // align4 → 16
const FILTERS_SIZE = filter_bits.len; // 8

const NAMES_OFF = HEADER_SIZE; // 32
const DOC_OFF = NAMES_OFF + NAMES_SIZE; // 40
const POOL_OFF = DOC_OFF + DOC_STRIDE; // 72
const FILT_OFF = POOL_OFF + POOL_SIZE; // 88
const TOTAL = FILT_OFF + FILTERS_SIZE; // 96

/// Directly construct small index (1 meta, 1 doc) bytes in little-endian.
fn buildTinyIndex() [TOTAL]u8 {
    var buf: [TOTAL]u8 = [_]u8{0} ** TOTAL;

    // Header (32B)
    std.mem.writeInt(u32, buf[0..4], MAGIC, .little);
    buf[4] = VERSION;
    buf[5] = @intFromEnum(fmt.FilterKind.binary_fuse);
    buf[6] = 0; // hash_k (unused for binary_fuse)
    buf[7] = @intFromEnum(fmt.TokenizerKind.default);
    std.mem.writeInt(u32, buf[8..12], 1, .little); // num_docs
    std.mem.writeInt(u32, buf[12..16], 1, .little); // num_meta_fields
    std.mem.writeInt(u32, buf[16..20], NAMES_OFF, .little);
    std.mem.writeInt(u32, buf[20..24], DOC_OFF, .little);
    std.mem.writeInt(u32, buf[24..28], POOL_OFF, .little);
    std.mem.writeInt(u32, buf[28..32], FILT_OFF, .little);

    // Meta field name "date\0" + padding
    @memcpy(buf[NAMES_OFF..][0..meta_name.len], meta_name);
    buf[NAMES_OFF + meta_name.len] = 0;

    // DocEntryPrefix (24B) — filter / title / url
    const dep = DOC_OFF;
    std.mem.writeInt(u32, buf[dep..][0..4], 0, .little); // filter_off
    std.mem.writeInt(u32, buf[dep + 4 ..][0..4], filter_bits.len, .little); // filter_len
    std.mem.writeInt(u32, buf[dep + 8 ..][0..4], 0, .little); // title_off
    std.mem.writeInt(u32, buf[dep + 12 ..][0..4], title_str.len, .little); // title_len
    std.mem.writeInt(u32, buf[dep + 16 ..][0..4], title_str.len, .little); // url_off
    std.mem.writeInt(u32, buf[dep + 20 ..][0..4], url_str.len, .little); // url_len

    // MetaEntry (8B) — meta value after title+url
    const me = dep + @sizeOf(DocEntryPrefix);
    std.mem.writeInt(u32, buf[me..][0..4], title_str.len + url_str.len, .little); // off
    std.mem.writeInt(u32, buf[me + 4 ..][0..4], meta_val.len, .little); // len

    // String pool: title + url + meta value
    var sp: usize = POOL_OFF;
    @memcpy(buf[sp..][0..title_str.len], title_str);
    sp += title_str.len;
    @memcpy(buf[sp..][0..url_str.len], url_str);
    sp += url_str.len;
    @memcpy(buf[sp..][0..meta_val.len], meta_val);

    // Filter bits
    @memcpy(buf[FILT_OFF..][0..filter_bits.len], &filter_bits);

    return buf;
}

test "open: Truncated — bytes < HEADER_SIZE" {
    const tiny: [4]u8 = .{ 0, 0, 0, 0 };
    try std.testing.expectError(error.Truncated, IndexView.open(&tiny));
}

test "open: InvalidMagic" {
    var buf: [TOTAL]u8 align(4) = buildTinyIndex();
    buf[0] = 0x00; // corrupt magic first byte
    try std.testing.expectError(error.InvalidMagic, IndexView.open(&buf));
}

test "open: InvalidVersion" {
    var buf: [TOTAL]u8 align(4) = buildTinyIndex();
    buf[4] = 99; // unsupported version
    try std.testing.expectError(error.InvalidVersion, IndexView.open(&buf));
}

test "open: normal — read header fields" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expectEqual(MAGIC, v.header.magic);
    try std.testing.expectEqual(VERSION, v.header.version);
    try std.testing.expectEqual(@as(u32, 1), v.header.num_docs);
    try std.testing.expectEqual(@as(u32, 1), v.header.num_meta_fields);
    try std.testing.expectEqual(@as(u8, 0), v.header.hash_k);
}

test "open: section slice lengths match" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expectEqual(NAMES_SIZE, v.meta_names.len);
    try std.testing.expectEqual(DOC_STRIDE, v.doc_table.len);
    try std.testing.expectEqual(POOL_SIZE, v.string_pool.len);
    try std.testing.expectEqual(FILTERS_SIZE, v.filters.len);
}

test "docEntry(0): DocEntryPrefix title/url fields" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const e = v.docEntry(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(u32, 0), e.filter_off);
    try std.testing.expectEqual(@as(u32, filter_bits.len), e.filter_len);
    try std.testing.expectEqual(@as(u32, 0), e.title_off);
    try std.testing.expectEqual(@as(u32, title_str.len), e.title_len);
    try std.testing.expectEqual(@as(u32, title_str.len), e.url_off);
    try std.testing.expectEqual(@as(u32, url_str.len), e.url_len);
}

test "title(0): expected title string" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const t = v.title(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(title_str, t);
}

test "url(0): expected URL string" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const u = v.url(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(url_str, u);
}

test "docMetaEntries(0): slice length 1" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const metas = v.docMetaEntries(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), metas.len);
    try std.testing.expectEqual(@as(u32, title_str.len + url_str.len), metas[0].off);
    try std.testing.expectEqual(@as(u32, meta_val.len), metas[0].len);
}

test "metaValue(0, 0): expected meta value" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const mv = v.metaValue(0, 0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(meta_val, mv);
}

test "docFilter(0): expected bit array" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const f = v.docFilter(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualSlices(u8, &filter_bits, f);
}

test "metaNameAt(0): expected field name" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const name = v.metaNameAt(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(meta_name, name);
}

test "out of bounds doc_id → null (docEntry, title, url, docMetaEntries, metaValue)" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expect(v.docEntry(1) == null);
    try std.testing.expect(v.docEntry(999) == null);
    try std.testing.expect(v.title(1) == null);
    try std.testing.expect(v.title(999) == null);
    try std.testing.expect(v.url(1) == null);
    try std.testing.expect(v.url(999) == null);
    try std.testing.expect(v.docMetaEntries(1) == null);
    try std.testing.expect(v.docFilter(1) == null);
    try std.testing.expect(v.metaValue(1, 0) == null);
    try std.testing.expect(v.metaValue(999, 0) == null);
}

test "metaValue: field_idx out of bounds → null" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expect(v.metaValue(0, 1) == null);
    try std.testing.expect(v.metaValue(0, 99) == null);
}

test "metaNameAt: idx out of bounds → null" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expect(v.metaNameAt(1) == null);
    try std.testing.expect(v.metaNameAt(99) == null);
}

test "open: offset reversal → Truncated" {
    var buf: [TOTAL]u8 align(4) = buildTinyIndex();
    // Make doc_table_off larger than pool_off to cause reversal
    std.mem.writeInt(u32, buf[20..24], POOL_OFF + 1, .little);
    try std.testing.expectError(error.Truncated, IndexView.open(&buf));
}
