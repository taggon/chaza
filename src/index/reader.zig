//! chaza 인덱스 판독기: 직렬화된 인덱스 바이트를 zero-parse 슬라이스 뷰로 노출.
//!
//! IndexView는 인덱스 바이트를 소유하지 않는다 — caller가 버퍼 수명 관리.
//! 모든 오프셋은 헤더 기준이며, 각 접근자는 슬라이스 범위를 검증한다.
//! DocEntryPrefix의 filter_off는 filters 구역 기준.
//! title_off / url_off / MetaEntry.off는 string_pool 기준.

const std = @import("std");
const fmt = @import("format.zig");

pub const Header = fmt.Header;
pub const DocEntryPrefix = fmt.DocEntryPrefix;
pub const MetaEntry = fmt.MetaEntry;
pub const MAGIC = fmt.MAGIC;
pub const VERSION = fmt.VERSION;
pub const HEADER_SIZE = fmt.HEADER_SIZE;

/// 인덱스 열기 실패 원인.
pub const OpenError = error{
    InvalidMagic,
    InvalidVersion,
    Truncated,
};

/// 직렬화된 인덱스 바이트에 대한 zero-parse 뷰.
/// `bytes`는 caller 소유 — IndexView보다 오래 살아야 한다.
/// 모든 슬라이스 필드는 `bytes` 내부를 가리킨다.
pub const IndexView = struct {
    bytes: []const u8,
    header: *const Header,
    /// 메타 필드 이름 목록 원시 바이트 (NUL 종료 문자열들).
    meta_names: []const u8,
    /// 문서 메타 테이블 원시 바이트.
    doc_table: []const u8,
    /// 문자열 풀 (title / url / 메타 값).
    string_pool: []const u8,
    /// 필터 데이터 (필터 blob).
    filters: []const u8,

    /// 인덱스 바이트를 뷰로 열기.
    /// 헤더 매직/버전 검증 + 각 구역 오프셋이 bytes 범위 내인지 확인.
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

        // 각 오프셋이 단조 증가하며 bytes 범위 내인지 검증.
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

    /// 한 DocEntry의 바이트 stride = 24 + 8 * num_meta_fields.
    inline fn docStride(self: IndexView) usize {
        return fmt.docEntrySize(self.header.num_meta_fields);
    }

    /// 문서 id로 DocEntryPrefix 포인터. doc_id >= num_docs 또는 범위 초과면 null.
    pub fn docEntry(self: IndexView, doc_id: u32) ?*const DocEntryPrefix {
        if (doc_id >= self.header.num_docs) return null;
        const base: usize = self.header.doc_table_off;
        const stride = self.docStride();
        const off = base + @as(usize, doc_id) * stride;
        if (off + @sizeOf(DocEntryPrefix) > self.bytes.len) return null;
        const ptr: [*]const u8 = self.bytes.ptr + off;
        return @ptrCast(@alignCast(ptr));
    }

    /// 해당 문서의 메타 엔트리 슬라이스. 범위 초과면 null.
    /// field_idx는 사용자 metadata_fields 인덱스 (title/url과 무관).
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

    /// 문서 제목 (string_pool 내). doc_id 범위 초과면 null.
    pub fn title(self: IndexView, doc_id: u32) ?[]const u8 {
        const prefix = self.docEntry(doc_id) orelse return null;
        const off: usize = prefix.title_off;
        const ln: usize = prefix.title_len;
        if (off + ln > self.string_pool.len) return null;
        return self.string_pool[off .. off + ln];
    }

    /// 문서 URL (string_pool 내). doc_id 범위 초과면 null.
    pub fn url(self: IndexView, doc_id: u32) ?[]const u8 {
        const prefix = self.docEntry(doc_id) orelse return null;
        const off: usize = prefix.url_off;
        const ln: usize = prefix.url_len;
        if (off + ln > self.string_pool.len) return null;
        return self.string_pool[off .. off + ln];
    }

    /// 필터 blob 슬라이스 (filters 구역 내).
    pub fn docFilter(self: IndexView, doc_id: u32) ?[]const u8 {
        const prefix = self.docEntry(doc_id) orelse return null;
        const off: usize = prefix.filter_off;
        const ln: usize = prefix.filter_len;
        if (off + ln > self.filters.len) return null;
        return self.filters[off .. off + ln];
    }

    /// 특정 메타 필드 값 (string_pool 내). field_idx 초과면 null.
    /// field_idx는 사용자 metadata_fields 인덱스 (title/url과 무관).
    pub fn metaValue(self: IndexView, doc_id: u32, field_idx: usize) ?[]const u8 {
        const metas = self.docMetaEntries(doc_id) orelse return null;
        if (field_idx >= metas.len) return null;
        const m = metas[field_idx];
        const off: usize = m.off;
        const ln: usize = m.len;
        if (off + ln > self.string_pool.len) return null;
        return self.string_pool[off .. off + ln];
    }

    /// 메타 필드 이름 (idx번째 NUL 종료 문자열). 범위 초과면 null.
    /// num_meta_fields로 상한 검사 — 정렬 패딩 zero를 빈 문자열로 오인 방지.
    pub fn metaNameAt(self: IndexView, idx: usize) ?[]const u8 {
        if (idx >= self.header.num_meta_fields) return null;
        const region = self.meta_names;
        var i: usize = 0;
        var count: usize = 0;
        while (i < region.len) {
            const start = i;
            while (i < region.len and region[i] != 0) : (i += 1) {}
            if (i >= region.len) return null; // NUL 종료 부재 → 손상
            if (count == idx) return region[start..i];
            count += 1;
            i += 1; // NUL 건너뜀
        }
        return null;
    }
};

// ── 단정 테스트 ────────────────────────────────────────────────────
//
// SPEC v1.1 핸드코딩 fixture (96바이트):
//
//   오프셋  구역                내용
//   ─────────────────────────────────────────────────────
//   0       Header (32B)        magic / version / offsets
//   32      meta_names (8B)     "date\0" + 3B 패딩 (align4)
//   40      doc_table (32B)     DocEntryPrefix(24B) + MetaEntry(8B)
//   72      string_pool (16B)   "Hi"(2) + "/a"(2) + "2026-01-01"(10) + 2B 패딩
//   88      filters (8B)        0xAA 0xBB 0xCC 0xDD 0xEE 0xFF 0x11 0x22
//   ─────────────────────────────────────────────────────
//   총 96바이트
//
// string_pool 상대 오프셋:
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

/// 작은 인덱스(메타 1개, 문서 1개) 바이트를 리틀엔디안으로 직접 구성.
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

    // 메타 필드 이름 "date\0" + 패딩
    @memcpy(buf[NAMES_OFF..][0..meta_name.len], meta_name);
    buf[NAMES_OFF + meta_name.len] = 0;

    // DocEntryPrefix (24B) — v1.1: filter / title / url
    const dep = DOC_OFF;
    std.mem.writeInt(u32, buf[dep..][0..4], 0, .little); // filter_off
    std.mem.writeInt(u32, buf[dep + 4 ..][0..4], filter_bits.len, .little); // filter_len
    std.mem.writeInt(u32, buf[dep + 8 ..][0..4], 0, .little); // title_off
    std.mem.writeInt(u32, buf[dep + 12 ..][0..4], title_str.len, .little); // title_len
    std.mem.writeInt(u32, buf[dep + 16 ..][0..4], title_str.len, .little); // url_off
    std.mem.writeInt(u32, buf[dep + 20 ..][0..4], url_str.len, .little); // url_len

    // MetaEntry (8B) — meta 값은 title+url 뒤
    const me = dep + @sizeOf(DocEntryPrefix);
    std.mem.writeInt(u32, buf[me..][0..4], title_str.len + url_str.len, .little); // off
    std.mem.writeInt(u32, buf[me + 4 ..][0..4], meta_val.len, .little); // len

    // 문자열 풀: title + url + meta 값
    var sp: usize = POOL_OFF;
    @memcpy(buf[sp..][0..title_str.len], title_str);
    sp += title_str.len;
    @memcpy(buf[sp..][0..url_str.len], url_str);
    sp += url_str.len;
    @memcpy(buf[sp..][0..meta_val.len], meta_val);

    // 필터 비트
    @memcpy(buf[FILT_OFF..][0..filter_bits.len], &filter_bits);

    return buf;
}

test "open: Truncated — bytes가 HEADER_SIZE 미만" {
    const tiny: [4]u8 = .{ 0, 0, 0, 0 };
    try std.testing.expectError(error.Truncated, IndexView.open(&tiny));
}

test "open: InvalidMagic" {
    var buf: [TOTAL]u8 align(4) = buildTinyIndex();
    buf[0] = 0x00; // 매직 첫 바이트 훼손
    try std.testing.expectError(error.InvalidMagic, IndexView.open(&buf));
}

test "open: InvalidVersion" {
    var buf: [TOTAL]u8 align(4) = buildTinyIndex();
    buf[4] = 99; // 지원 않는 버전
    try std.testing.expectError(error.InvalidVersion, IndexView.open(&buf));
}

test "open: 정상 — 헤더 필드 읽기" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expectEqual(MAGIC, v.header.magic);
    try std.testing.expectEqual(VERSION, v.header.version);
    try std.testing.expectEqual(@as(u32, 1), v.header.num_docs);
    try std.testing.expectEqual(@as(u32, 1), v.header.num_meta_fields);
    try std.testing.expectEqual(@as(u8, 0), v.header.hash_k);
}

test "open: 구역 슬라이스 길이 일치" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expectEqual(NAMES_SIZE, v.meta_names.len);
    try std.testing.expectEqual(DOC_STRIDE, v.doc_table.len);
    try std.testing.expectEqual(POOL_SIZE, v.string_pool.len);
    try std.testing.expectEqual(FILTERS_SIZE, v.filters.len);
}

test "docEntry(0): DocEntryPrefix title/url 필드" {
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

test "title(0): 예상 제목 문자열" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const t = v.title(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(title_str, t);
}

test "url(0): 예상 URL 문자열" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const u = v.url(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(url_str, u);
}

test "docMetaEntries(0): 슬라이스 길이 1" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const metas = v.docMetaEntries(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(@as(usize, 1), metas.len);
    try std.testing.expectEqual(@as(u32, title_str.len + url_str.len), metas[0].off);
    try std.testing.expectEqual(@as(u32, meta_val.len), metas[0].len);
}

test "metaValue(0, 0): 예상 메타 값" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const mv = v.metaValue(0, 0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(meta_val, mv);
}

test "docFilter(0): 예상 비트 배열" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const f = v.docFilter(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualSlices(u8, &filter_bits, f);
}

test "metaNameAt(0): 예상 필드 이름" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    const name = v.metaNameAt(0) orelse return error.UnexpectedNull;
    try std.testing.expectEqualStrings(meta_name, name);
}

test "범위 초과 doc_id → null (docEntry, title, url, docMetaEntries, metaValue)" {
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

test "metaValue: field_idx 초과 → null" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expect(v.metaValue(0, 1) == null);
    try std.testing.expect(v.metaValue(0, 99) == null);
}

test "metaNameAt: idx 초과 → null" {
    const buf: [TOTAL]u8 align(4) = buildTinyIndex();
    const v = try IndexView.open(&buf);
    try std.testing.expect(v.metaNameAt(1) == null);
    try std.testing.expect(v.metaNameAt(99) == null);
}

test "open: 오프셋 역전 → Truncated" {
    var buf: [TOTAL]u8 align(4) = buildTinyIndex();
    // doc_table_off를 pool_off보다 크게 만들어 역전 유발
    std.mem.writeInt(u32, buf[20..24], POOL_OFF + 1, .little);
    try std.testing.expectError(error.Truncated, IndexView.open(&buf));
}
