//! chaza 인덱스 바이너리 포맷 (SPEC v1.2 참조).
//!
//! 설계 원칙: 평면(flat), zero-parse, 리틀엔디안, 4바이트 정렬.
//!
//! 메모리 배치:
//!   [ Header ]
//!   [ 메타 필드 이름 목록 ]   num_meta_fields 개의 NUL 종료 UTF-8 문자열
//!   [ 문서 메타 테이블 ]       num_docs 개의 DocEntry (가변: 24 + 8*num_meta_fields 바이트)
//!   [ 문자열 풀 ]             title / url / 메타 값 문자열 (NUL 구분)
//!   [ 필터 데이터 ]           각 문서의 필터 blob ([FuseBlobHeader][fingerprints])
//!
//! 번들 파일은 [ runtime.wasm ][ index bytes ][ TailMeta 16B ] 순서.

const std = @import("std");
const builtin = @import("builtin");

/// 번들 식별용 매직넘버. 파일에 LE로 직렬화하면 바이트 순서가 'C','H','A','Z'가 됨.
pub const MAGIC: u32 = 0x5A414843;

/// 현재 인덱스 포맷 버전. v1.2에서 version 2 (필터 blob 자기서술 구조).
pub const VERSION: u8 = 2;

/// 초성 토큰임을 나타내는 접두 바이트.
pub const CHOSEONG_MARKER: u8 = 0x01;

pub const HEADER_SIZE: usize = @sizeOf(Header);
pub const TAIL_META_SIZE: usize = @sizeOf(TailMeta);

/// 1계층 토큰화 알고리즘 (헤더의 tokenizer_kind 필드).
pub const TokenizerKind = enum(u8) {
    default = 0,
    _,
};

/// 필터 종류 (헤더의 filter_kind 필드).
pub const FilterKind = enum(u8) {
    binary_fuse = 0,
    _,
};

/// 인덱스 헤더 (32바이트, 4바이트 정렬).
/// 모든 offset은 인덱스 바이트 선두 기준.
pub const Header = extern struct {
    magic: u32 = MAGIC,
    version: u8 = VERSION,
    filter_kind: FilterKind = .binary_fuse,
    /// Bloom 전용 k (BinaryFuse는 미사용, 0).
    hash_k: u8 = 0,
    tokenizer_kind: TokenizerKind = .default,
    num_docs: u32 = 0,
    num_meta_fields: u32 = 0,
    meta_names_off: u32 = 0,
    doc_table_off: u32 = 0,
    string_pool_off: u32 = 0,
    filters_off: u32 = 0,
};

/// 문서 메타 테이블 항목의 고정 접두부 (24바이트).
/// 이어서 num_meta_fields 개의 MetaEntry가 옴.
pub const DocEntryPrefix = extern struct {
    /// 이 문서 필터 blob의 오프셋 (filters 구역 기준).
    filter_off: u32 = 0,
    /// 필터 blob 전체 길이 (헤더 포함).
    filter_len: u32 = 0,
    /// 문서 제목 (string_pool 기준).
    title_off: u32 = 0,
    title_len: u32 = 0,
    /// 문서 URL (string_pool 기준).
    url_off: u32 = 0,
    url_len: u32 = 0,
};

/// DocEntry의 메타 값 위치 (문자열 풀 내).
pub const MetaEntry = extern struct {
    off: u32 = 0,
    len: u32 = 0,
};

/// 번들 꼬리 메타 (16바이트 고정, 파일 맨 끝).
pub const TailMeta = extern struct {
    magic: u32 = MAGIC,
    version: u8 = VERSION,
    _reserved: [3]u8 = [_]u8{ 0, 0, 0 },
    wasm_len: u32 = 0,
    index_len: u32 = 0,
};

/// 한 DocEntry의 총 바이트 크기. = 24 + 8 * num_meta_fields.
pub inline fn docEntrySize(num_meta_fields: u32) usize {
    return @sizeOf(DocEntryPrefix) + @as(usize, num_meta_fields) * @sizeOf(MetaEntry);
}

/// DocEntryPrefix 포인터 뒤에 이어지는 메타 엔트리들을 슬라이스로 얻음.
pub fn metaEntries(prefix: *DocEntryPrefix, num_meta_fields: usize) []MetaEntry {
    const prefix_bytes: [*]u8 = @ptrCast(prefix);
    const after: [*]u8 = prefix_bytes + @sizeOf(DocEntryPrefix);
    const meta_ptr: [*]MetaEntry = @ptrCast(@alignCast(after));
    return meta_ptr[0..num_meta_fields];
}

// ── 단정 테스트 ────────────────────────────────────────────────────

test "매직넘버가 ASCII 'CHAZ' 리틀엔디안과 일치" {
    const bytes: [4]u8 = .{ 'C', 'H', 'A', 'Z' };
    try std.testing.expectEqual(MAGIC, std.mem.readInt(u32, &bytes, .little));
}

test "Header 크기 및 오프셋 (SPEC 준수)" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Header));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Header, "magic"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Header, "version"));
    try std.testing.expectEqual(@as(usize, 5), @offsetOf(Header, "filter_kind"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(Header, "hash_k"));
    try std.testing.expectEqual(@as(usize, 7), @offsetOf(Header, "tokenizer_kind"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Header, "num_docs"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Header, "num_meta_fields"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Header, "meta_names_off"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(Header, "doc_table_off"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Header, "string_pool_off"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Header, "filters_off"));
}

test "DocEntryPrefix / MetaEntry 크기" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(DocEntryPrefix));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(MetaEntry));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DocEntryPrefix, "filter_off"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DocEntryPrefix, "filter_len"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DocEntryPrefix, "title_off"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(DocEntryPrefix, "title_len"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(DocEntryPrefix, "url_off"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(DocEntryPrefix, "url_len"));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MetaEntry, "off"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(MetaEntry, "len"));
}

test "docEntrySize 계산" {
    try std.testing.expectEqual(@as(usize, 24), docEntrySize(0));
    try std.testing.expectEqual(@as(usize, 32), docEntrySize(1));
    try std.testing.expectEqual(@as(usize, 48), docEntrySize(3));
}

test "TailMeta 크기 및 오프셋 (16바이트 고정)" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TailMeta));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(TailMeta));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TailMeta, "magic"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(TailMeta, "version"));
    try std.testing.expectEqual(@as(usize, 5), @offsetOf(TailMeta, "_reserved"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(TailMeta, "wasm_len"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(TailMeta, "index_len"));
}

test "리틀엔디안 호스트 가정 (wasm 네이티브 = 리틀엔디안)" {
    try std.testing.expectEqual(.little, builtin.cpu.arch.endian());
}

test "Header 기본값" {
    const h: Header = .{};
    try std.testing.expectEqual(MAGIC, h.magic);
    try std.testing.expectEqual(VERSION, h.version);
    try std.testing.expectEqual(FilterKind.binary_fuse, h.filter_kind);
    try std.testing.expectEqual(@as(u8, 0), h.hash_k);
    try std.testing.expectEqual(TokenizerKind.default, h.tokenizer_kind);
    try std.testing.expectEqual(@as(u32, 0), h.num_docs);
}

test "metaEntries 슬라이싱" {
    // DocEntryPrefix(24바이트) + MetaEntry 3개(24바이트) = 48바이트
    var storage: [48]u8 = .{0} ** 48;
    const prefix: *DocEntryPrefix = @ptrCast(@alignCast(&storage));

    // 접두부 채우기
    prefix.filter_off = 100;
    prefix.title_len = 42;

    // 메타 엔트리 3개 채우기
    const metas = metaEntries(prefix, 3);
    try std.testing.expectEqual(@as(usize, 3), metas.len);
    metas[0].off = 1;
    metas[0].len = 2;
    metas[2].off = 9;
    metas[2].len = 10;

    // 실제 바이트가 접두부 뒤(offset 24)에 놓였는지 확인
    // metas[0].off @ 24, metas[2].len @ 24 + 2*8 + 4 = 44
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, storage[24..28], .little));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, storage[44..48], .little));
}
