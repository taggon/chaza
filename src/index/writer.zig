//! chaza index serialization (writer).
//!
//! Serialize IndexInput to flat binary format.
//! 2-pass: 1-pass calculates section sizes·offsets, 2-pass writes actual bytes.
//!
//! v1.4: two corpus-global BinaryFuse filters. token → key64 → pairKey(doc_id)
//! → lo filter (regular + 0x01 choseong tokens) or hi filter (0x02 prefix +
//! 0x03 title-ranking tokens, wider fingerprint). Filters section:
//! [u32 lo_len][u32 hi_len][lo blob (4B-aligned)][hi blob].
//! string_pool contains only title / url / meta values.

const std = @import("std");
const format = @import("format.zig");
const binary_fuse = @import("../pipeline/binary_fuse.zig");
const hash = @import("../pipeline/hash.zig");
const choseong = @import("../pipeline/choseong.zig");

const Header = format.Header;
const DocEntryPrefix = format.DocEntryPrefix;
const MetaEntry = format.MetaEntry;

/// Single document input.
pub const DocInput = struct {
    /// Unique token set after tokenization·stopword removal (for filter build, not serialized).
    tokens: []const []const u8,
    /// Title for result display.
    title: []const u8,
    /// URL for result navigation.
    url: []const u8,
    /// Meta values count = num_meta_fields (user-defined fields, title/url excluded).
    meta_values: []const []const u8,
};

/// Entire index input.
pub const IndexInput = struct {
    /// User metadata_fields names (title/url excluded).
    meta_field_names: []const []const u8,
    docs: []const DocInput,
    /// Choseong token addition length (0 = disabled).
    choseong_max_len: u8 = 0,
    /// Fingerprint width of the global lo filter (regular + choseong tokens).
    lo_fingerprint_bits: u5 = format.LO_FINGERPRINT_BITS,
    /// Fingerprint width of the global hi filter (0x02 prefix + 0x03 title tokens).
    hi_fingerprint_bits: u5 = format.HI_FINGERPRINT_BITS,
};

/// Does this token belong in the hi (high-precision) filter?
/// 0x02 prefix and 0x03 title-ranking tokens feed user-visible signals.
inline fn isHiToken(tok: []const u8) bool {
    return tok.len > 0 and (tok[0] == format.PREFIX_MARKER or tok[0] == format.TITLE_MARKER);
}

/// 4바이트 정렬.
inline fn align4(x: usize) usize {
    return (x + 3) & ~@as(usize, 3);
}

/// 전체 인덱스 바이트를 할당해 반환. caller가 free.
pub fn write(allocator: std.mem.Allocator, input: IndexInput) ![]u8 {
    const num_docs = input.docs.len;
    const num_meta: usize = input.meta_field_names.len;

    // choseong 토큰 전처리 (choseong_max_len > 0일 때)
    var expanded: ?[]std.ArrayList([]const u8) = null;
    defer if (expanded) |e| {
        for (e) |*toks| {
            for (toks.items) |t| allocator.free(t);
            toks.deinit(allocator);
        }
        allocator.free(e);
    };

    if (input.choseong_max_len > 0) {
        expanded = try allocator.alloc(std.ArrayList([]const u8), num_docs);
        for (input.docs, 0..) |doc, i| {
            expanded.?[i] = .empty;
            for (doc.tokens) |t| {
                const owned = try allocator.dupe(u8, t);
                try expanded.?[i].append(allocator, owned);
            }
            try choseong.addChoseongTokens(allocator, &expanded.?[i], input.choseong_max_len);
        }
    }

    // ── 1패스: 구역별 크기·오프셋 산출 ──

    var meta_names_raw: usize = 0;
    for (input.meta_field_names) |name| {
        meta_names_raw += name.len + 1; // NUL 종료
    }
    const meta_names_size = align4(meta_names_raw);
    const meta_names_off: usize = format.HEADER_SIZE;

    const doc_entry_sz = format.docEntrySize(@intCast(num_meta));
    const doc_table_size = num_docs * doc_entry_sz;
    const doc_table_off = meta_names_off + meta_names_size;

    // 문자열 풀 레이아웃 — title / url / meta 값만
    const title_offs = try allocator.alloc(u32, num_docs);
    defer allocator.free(title_offs);
    const url_offs = try allocator.alloc(u32, num_docs);
    defer allocator.free(url_offs);
    const meta_offs = try allocator.alloc(u32, num_docs * @max(num_meta, 1));
    defer allocator.free(meta_offs);

    var sp_cursor: usize = 0;
    for (input.docs, 0..) |doc, i| {
        title_offs[i] = @intCast(sp_cursor);
        sp_cursor += doc.title.len;
        url_offs[i] = @intCast(sp_cursor);
        sp_cursor += doc.url.len;
        for (doc.meta_values, 0..) |mv, j| {
            meta_offs[i * num_meta + j] = @intCast(sp_cursor);
            sp_cursor += mv.len;
        }
    }
    const string_pool_size = align4(sp_cursor);
    const string_pool_off = doc_table_off + doc_table_size;

    // 필터 구역 레이아웃 — 전역 lo/hi 키 수 집계 (pairKey는 (doc, token)마다 유일)
    var lo_count: usize = 0;
    var hi_count: usize = 0;
    for (input.docs, 0..) |doc, i| {
        const toks: []const []const u8 = if (expanded) |e| e[i].items else doc.tokens;
        for (toks) |t| {
            if (isHiToken(t)) hi_count += 1 else lo_count += 1;
        }
    }

    const lo_blob_sz = binary_fuse.blobSize(@intCast(lo_count), input.lo_fingerprint_bits);
    const hi_blob_sz = binary_fuse.blobSize(@intCast(hi_count), input.hi_fingerprint_bits);
    const filters_off = string_pool_off + string_pool_size;
    // [u32 lo_len][u32 hi_len][lo blob (4B 정렬)][hi blob]
    const lo_blob_off = filters_off + 8;
    const hi_blob_off = lo_blob_off + align4(lo_blob_sz);
    const total_size = hi_blob_off + hi_blob_sz;

    // ── 2패스: 버퍼 할당 후 기록 ──
    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);
    @memset(buf, 0);

    // 헤더
    const header: *Header = @ptrCast(@alignCast(buf.ptr));
    header.* = .{
        .num_docs = @intCast(num_docs),
        .num_meta_fields = @intCast(num_meta),
        .meta_names_off = @intCast(meta_names_off),
        .doc_table_off = @intCast(doc_table_off),
        .string_pool_off = @intCast(string_pool_off),
        .filters_off = @intCast(filters_off),
    };

    // 메타 필드 이름: NUL 종료 UTF-8
    var pos: usize = meta_names_off;
    for (input.meta_field_names) |name| {
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = 0;
        pos += 1;
    }

    // 문서 메타 테이블: DocEntryPrefix + MetaEntry들
    pos = doc_table_off;
    for (input.docs, 0..) |doc, i| {
        const prefix: *DocEntryPrefix = @ptrCast(@alignCast(buf.ptr + pos));
        prefix.* = .{
            .title_off = title_offs[i],
            .title_len = @intCast(doc.title.len),
            .url_off = url_offs[i],
            .url_len = @intCast(doc.url.len),
        };
        pos += @sizeOf(DocEntryPrefix);

        const metas = format.metaEntries(prefix, num_meta);
        for (0..num_meta) |j| {
            metas[j].off = meta_offs[i * num_meta + j];
            metas[j].len = @intCast(doc.meta_values[j].len);
        }
        pos += num_meta * @sizeOf(MetaEntry);
    }

    // 문자열 풀: title → url → meta 값
    pos = string_pool_off;
    for (input.docs) |doc| {
        @memcpy(buf[pos..][0..doc.title.len], doc.title);
        pos += doc.title.len;
        @memcpy(buf[pos..][0..doc.url.len], doc.url);
        pos += doc.url.len;
        for (doc.meta_values) |mv| {
            @memcpy(buf[pos..][0..mv.len], mv);
            pos += mv.len;
        }
    }

    // 필터 데이터: 전역 lo/hi 키 배열 구성 → 두 필터 populate → blob 기록
    const lo_keys = try allocator.alloc(u64, lo_count);
    defer allocator.free(lo_keys);
    const hi_keys = try allocator.alloc(u64, hi_count);
    defer allocator.free(hi_keys);

    var lo_i: usize = 0;
    var hi_i: usize = 0;
    for (input.docs, 0..) |doc, i| {
        const toks: []const []const u8 = if (expanded) |e| e[i].items else doc.tokens;
        const doc_id: u32 = @intCast(i);
        for (toks) |t| {
            const k = hash.pairKey(hash.key64(t), doc_id);
            if (isHiToken(t)) {
                hi_keys[hi_i] = k;
                hi_i += 1;
            } else {
                lo_keys[lo_i] = k;
                lo_i += 1;
            }
        }
    }

    std.mem.writeInt(u32, buf[filters_off..][0..4], @intCast(lo_blob_sz), .little);
    std.mem.writeInt(u32, buf[filters_off + 4 ..][0..4], @intCast(hi_blob_sz), .little);

    var lo_filter = try binary_fuse.BinaryFuse.init(allocator, @intCast(lo_count), input.lo_fingerprint_bits);
    defer lo_filter.deinit();
    try lo_filter.populate(lo_keys);
    lo_filter.writeBlob(buf[lo_blob_off..]);

    var hi_filter = try binary_fuse.BinaryFuse.init(allocator, @intCast(hi_count), input.hi_fingerprint_bits);
    defer hi_filter.deinit();
    try hi_filter.populate(hi_keys);
    hi_filter.writeBlob(buf[hi_blob_off..]);

    return buf;
}

// ── 단정 테스트 ────────────────────────────────────────────────────

test "단일 문서, 메타 1개: 바이트 길이·헤더 검증 (title/url 명시적 기록)" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"hi"}, .title = "Hello", .url = "/x", .meta_values = &.{"news"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));

    // 예상 크기:
    // header=32, meta_names="category\0"=9→align4=12,
    // doc_table=1*(24+8)=32, string_pool="Hello"(5)+"/x"(2)+"news"(4)=11→align4=12,
    // filters=blobSize(1)=44 (32헤더+12지문)
    // total = 32+12+32+12+44 = 132
    try std.testing.expectEqual(@as(usize, 32), header.meta_names_off);
    try std.testing.expectEqual(@as(u32, 44), header.doc_table_off);
    try std.testing.expectEqual(@as(u32, 68), header.string_pool_off);
    try std.testing.expectEqual(@as(u32, 80), header.filters_off);
    try std.testing.expectEqual(@as(u32, 1), header.num_docs);
    try std.testing.expectEqual(@as(u32, 1), header.num_meta_fields);
}

test "3문서, 메타 2개: offset 일관성" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"hello"}, .title = "Page One", .url = "/p1", .meta_values = &.{ "v1a", "v1b" } },
        .{ .tokens = &.{"world"}, .title = "Page Two", .url = "/p2", .meta_values = &.{ "v2a", "v2b" } },
        .{ .tokens = &.{ "foo", "bar" }, .title = "Page Three", .url = "/p3", .meta_values = &.{ "v3a", "v3b" } },
    };
    const input = IndexInput{
        .meta_field_names = &.{ "author", "date" },
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));

    try std.testing.expectEqual(@as(u32, 3), header.num_docs);
    try std.testing.expectEqual(@as(u32, 2), header.num_meta_fields);

    // offset 증가 순서 보장
    try std.testing.expect(header.meta_names_off < header.doc_table_off);
    try std.testing.expect(header.doc_table_off < header.string_pool_off);
    try std.testing.expect(header.string_pool_off <= header.filters_off);
    try std.testing.expectEqual(@as(usize, result.len), @as(usize, header.filters_off) +
        @as(usize, @intCast(result.len - header.filters_off)));
}

test "meta_field_names이 NUL 종료로 기록됨" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{}, .title = "T", .url = "u1", .meta_values = &.{ "m1", "m2" } },
    };
    const input = IndexInput{
        .meta_field_names = &.{ "author", "date" },
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const off = @as(usize, header.meta_names_off);

    // "author\0date\0"
    try std.testing.expectEqual(@as(u8, 'a'), result[off]); // a
    try std.testing.expectEqual(@as(u8, 'o'), result[off + 4]); // auth[o]r
    try std.testing.expectEqual(@as(u8, 'r'), result[off + 5]);
    try std.testing.expectEqual(@as(u8, 0), result[off + 6]); // NUL 종료
    try std.testing.expectEqual(@as(u8, 'd'), result[off + 7]); // [d]ate
    try std.testing.expectEqual(@as(u8, 'e'), result[off + 10]); // dat[e]
    try std.testing.expectEqual(@as(u8, 0), result[off + 11]); // NUL 종료
}

test "title이 string_pool에 정확히 기록됨" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"kw"}, .title = "My Title", .url = "/page", .meta_values = &.{"cat"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const doc_entry: *const DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));

    const title_start = @as(usize, header.string_pool_off) + @as(usize, doc_entry.title_off);
    const title_end = title_start + @as(usize, doc_entry.title_len);

    try std.testing.expectEqual(@as(u32, 8), doc_entry.title_len);
    try std.testing.expectEqualStrings("My Title", result[title_start..title_end]);
}

test "url이 string_pool에 정확히 기록됨" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"kw"}, .title = "T", .url = "https://example.com/path", .meta_values = &.{"cat"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const doc_entry: *const DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));

    const url_start = @as(usize, header.string_pool_off) + @as(usize, doc_entry.url_off);
    const url_end = url_start + @as(usize, doc_entry.url_len);

    try std.testing.expectEqual(@as(u32, 24), doc_entry.url_len);
    try std.testing.expectEqualStrings("https://example.com/path", result[url_start..url_end]);
}

test "DocEntryPrefix의 title/url offset이 정확한 위치를 가리킴" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"a"}, .title = "TITLE", .url = "URL", .meta_values = &.{"META"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"cat"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const de: *const DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));

    // string_pool: "TITLE"(5) → "URL"(3) → "META"(4)
    // title_off=0, url_off=5, meta_off=9
    try std.testing.expectEqual(@as(u32, 0), de.title_off);
    try std.testing.expectEqual(@as(u32, 5), de.title_len);
    try std.testing.expectEqual(@as(u32, 5), de.url_off);
    try std.testing.expectEqual(@as(u32, 3), de.url_len);

    // 실제 데이터 교차 검증
    const sp = @as(usize, header.string_pool_off);
    try std.testing.expectEqualStrings("TITLE", result[sp + 0 ..][0..5]);
    try std.testing.expectEqualStrings("URL", result[sp + 5 ..][0..3]);
}

test "MetaEntry의 off/len이 정확한 위치를 가리킴" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"a"}, .title = "T", .url = "U", .meta_values = &.{ "first", "second" } },
    };
    const input = IndexInput{
        .meta_field_names = &.{ "author", "date" },
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const de_ptr: *DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));
    const metas = format.metaEntries(de_ptr, 2);

    // string_pool: "T"(1) + "U"(1) + "first"(5) + "second"(6)
    // meta0 off=2 len=5, meta1 off=7 len=6
    try std.testing.expectEqual(@as(u32, 2), metas[0].off);
    try std.testing.expectEqual(@as(u32, 5), metas[0].len);
    try std.testing.expectEqual(@as(u32, 7), metas[1].off);
    try std.testing.expectEqual(@as(u32, 6), metas[1].len);

    const sp = @as(usize, header.string_pool_off);
    try std.testing.expectEqualStrings("first", result[sp + 2 ..][0..5]);
    try std.testing.expectEqualStrings("second", result[sp + 7 ..][0..6]);
}

test "빈 문서(tokens=[]): filter는 최소 blob (blobSize(0, 폭))" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{}, .title = "Empty", .url = "/empty", .meta_values = &.{"none"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const de: *const DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));

    // 전역 필터 최소 blob: 32 헤더 + packedLen(12, 폭)
    const fo = @as(usize, header.filters_off);
    const lo_min: u32 = @intCast(binary_fuse.blobSize(0, format.LO_FINGERPRINT_BITS));
    const hi_min: u32 = @intCast(binary_fuse.blobSize(0, format.HI_FINGERPRINT_BITS));
    try std.testing.expectEqual(lo_min, std.mem.readInt(u32, result[fo..][0..4], .little));
    try std.testing.expectEqual(hi_min, std.mem.readInt(u32, result[fo + 4 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 5), de.title_len);
    try std.testing.expectEqual(@as(u32, 6), de.url_len);
}

test "filter_kind=binary_fuse, hash_k=0" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{ "hello", "world" }, .title = "HW", .url = "/hw", .meta_values = &.{"cat"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    try std.testing.expectEqual(format.FilterKind.binary_fuse, header.filter_kind);
    try std.testing.expectEqual(@as(u8, 0), header.hash_k);
}

test "binary fuse filter round-trip: 기록된 토큰이 필터에 존재" {
    const allocator = std.testing.allocator;
    const tokens = [_][]const u8{ "apple", "banana", "cherry" };
    const docs = [_]DocInput{
        .{ .tokens = &tokens, .title = "Fruits", .url = "/fruit", .meta_values = &.{"food"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));

    // 전역 lo blob을 읽어 BinaryFuseView로 역직렬화 후 (토큰, doc 0) contains 확인
    const fo = @as(usize, header.filters_off);
    const lo_len = std.mem.readInt(u32, result[fo..][0..4], .little);
    const filter_bytes = result[fo + 8 ..][0..lo_len];

    const view = binary_fuse.BinaryFuseView.fromBlob(filter_bytes) orelse return error.UnexpectedNull;

    for (tokens) |tok| {
        try std.testing.expect(view.contains(hash.pairKey(hash.key64(tok), 0)));
    }
}

test "모든 offset이 4바이트 정렬" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{ "alpha", "beta" }, .title = "AB", .url = "/a", .meta_values = &.{ "v1", "v2" } },
        .{ .tokens = &.{"gamma"}, .title = "G", .url = "/g", .meta_values = &.{ "v3", "v4" } },
        .{ .tokens = &.{}, .title = "Empty Doc Title", .url = "/e", .meta_values = &.{ "v5", "v6" } },
    };
    const input = IndexInput{
        .meta_field_names = &.{ "author", "date" },
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));

    try std.testing.expect(header.meta_names_off % 4 == 0);
    try std.testing.expect(header.doc_table_off % 4 == 0);
    try std.testing.expect(header.string_pool_off % 4 == 0);
    try std.testing.expect(header.filters_off % 4 == 0);

    // 전역 lo/hi blob도 4바이트 정렬 (lo는 lens 8B 뒤, hi는 align4(8+lo_len))
    const fo = @as(usize, header.filters_off);
    const lo_len: usize = std.mem.readInt(u32, result[fo..][0..4], .little);
    const hi_off = (8 + lo_len + 3) & ~@as(usize, 3);
    try std.testing.expect((fo + 8) % 4 == 0);
    try std.testing.expect((fo + hi_off) % 4 == 0);
}

test "0문서: 최소 인덱스 (헤더 + 메타 이름만)" {
    const allocator = std.testing.allocator;
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &.{},
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    try std.testing.expectEqual(@as(u32, 0), header.num_docs);
    // 헤더(32) + "category\0"(9)→align4(12) + 필터 구역 (8 + align4(lo) + hi)
    const lo_min = binary_fuse.blobSize(0, format.LO_FINGERPRINT_BITS);
    const hi_min = binary_fuse.blobSize(0, format.HI_FINGERPRINT_BITS);
    const expected_len = 44 + 8 + ((lo_min + 3) & ~@as(usize, 3)) + hi_min;
    try std.testing.expectEqual(expected_len, result.len);
    try std.testing.expectEqual(@as(u8, 0), header.hash_k);
}

test "한글 title/url/meta 직렬화 및 binary fuse filter 확인" {
    const allocator = std.testing.allocator;
    const tokens = [_][]const u8{ "안녕", "초성", "검색" };
    const docs = [_]DocInput{
        .{ .tokens = &tokens, .title = "한글 제목", .url = "/한글경로", .meta_values = &.{"한글값"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"category"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const de_ptr: *DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));

    const sp = @as(usize, header.string_pool_off);

    const title_start = sp + @as(usize, de_ptr.title_off);
    try std.testing.expectEqualStrings("한글 제목", result[title_start..][0..de_ptr.title_len]);

    const url_start = sp + @as(usize, de_ptr.url_off);
    try std.testing.expectEqualStrings("/한글경로", result[url_start..][0..de_ptr.url_len]);

    const metas = format.metaEntries(de_ptr, 1);
    const meta_start = sp + @as(usize, metas[0].off);
    try std.testing.expectEqualStrings("한글값", result[meta_start..][0..metas[0].len]);

    // binary fuse filter 확인 — tokens는 string_pool에 없지만 전역 lo 필터에는 존재
    const fo = @as(usize, header.filters_off);
    const lo_len = std.mem.readInt(u32, result[fo..][0..4], .little);
    const view = binary_fuse.BinaryFuseView.fromBlob(result[fo + 8 ..][0..lo_len]) orelse return error.UnexpectedNull;
    try std.testing.expect(view.contains(hash.pairKey(hash.key64("안녕"), 0)));
    try std.testing.expect(view.contains(hash.pairKey(hash.key64("초성"), 0)));
    try std.testing.expect(view.contains(hash.pairKey(hash.key64("검색"), 0)));
}

test "메타 필드 0개: title/url만 string_pool에 기록" {
    const allocator = std.testing.allocator;
    const docs = [_]DocInput{
        .{ .tokens = &.{"kw"}, .title = "Only Title", .url = "/only", .meta_values = &.{} },
    };
    const input = IndexInput{
        .meta_field_names = &.{},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    try std.testing.expectEqual(@as(u32, 0), header.num_meta_fields);

    const de: *const DocEntryPrefix = @ptrCast(@alignCast(result.ptr + @as(usize, header.doc_table_off)));
    const sp = @as(usize, header.string_pool_off);

    // title → url만 있음 (메타 없음)
    try std.testing.expectEqualStrings("Only Title", result[sp + de.title_off ..][0..de.title_len]);
    try std.testing.expectEqualStrings("/only", result[sp + de.url_off ..][0..de.url_len]);

    // DocEntryPrefix 뒤에 MetaEntry 없음: docEntrySize(0)=16
    try std.testing.expectEqual(@as(usize, 16), format.docEntrySize(0));
}

test "tokens는 string_pool에 직렬화되지 않음" {
    const allocator = std.testing.allocator;
    const tokens = [_][]const u8{ "unique_token_xyz", "another_unique" };
    const docs = [_]DocInput{
        .{ .tokens = &tokens, .title = "T", .url = "U", .meta_values = &.{"M"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"cat"},
        .docs = &docs,
    };
    const result = try write(allocator, input);
    defer allocator.free(result);

    const header: *const Header = @ptrCast(@alignCast(result.ptr));
    const sp_start = @as(usize, header.string_pool_off);
    const sp_end = @as(usize, header.filters_off);
    const string_pool = result[sp_start..sp_end];

    // string_pool에 토큰 문자열이 포함되어 있지 않은지 확인
    try std.testing.expect(std.mem.indexOf(u8, string_pool, "unique_token_xyz") == null);
    try std.testing.expect(std.mem.indexOf(u8, string_pool, "another_unique") == null);

    // 하지만 title/url/meta는 포함되어 있음
    try std.testing.expect(std.mem.indexOf(u8, string_pool, "T") != null);
    try std.testing.expect(std.mem.indexOf(u8, string_pool, "U") != null);
    try std.testing.expect(std.mem.indexOf(u8, string_pool, "M") != null);
}
