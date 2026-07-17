//! chaza index binary format
//!
//! Design principles: flat, zero-parse, little-endian, 4-byte alignment.
//!
//! Memory layout:
//!   [ Header ]
//!   [ Meta field name list ]   num_meta_fields NUL-terminated UTF-8 strings
//!   [ Document metadata table ]   num_docs DocEntry (variable: 16 + 8*num_meta_fields bytes)
//!   [ String pool ]             title / url / meta value strings (NUL-delimited)
//!   [ Filter data ]           [u32 lo_len][u32 hi_len][lo blob (4B-aligned)][hi blob]
//!
//! v1.4 filter data: two corpus-global binary fuse filters keyed by
//! pairKey(doc_id, token key). lo = regular + choseong (0x01) tokens;
//! hi = prefix (0x02) + title-ranking (0x03) tokens at a wider fingerprint.
//!
//! Bundle file order: [ runtime.wasm ][ index bytes ][ TailMeta 16B ]

const std = @import("std");
const builtin = @import("builtin");

/// Bundle magic number. Serialized to file as LE gives byte order 'C','H','A','Z'.
pub const MAGIC: u32 = 0x5A414843;

/// Current index format version. Filter blobs are self-describing.
/// v3: global lo/hi filters replace per-document filters; DocEntryPrefix
/// shrinks to 16 bytes (filter_off/len removed).
pub const VERSION: u8 = 3;

/// Default fingerprint width (bits) of the global lo filter
/// (regular + choseong tokens). FP ≈ 2^-w.
pub const LO_FINGERPRINT_BITS: u5 = 9;

/// Default fingerprint width (bits) of the global hi filter
/// (prefix 0x02 + title-ranking 0x03 tokens). These feed
/// search-as-you-type results and ranking, where false positives are
/// directly user-visible — so they get a wider fingerprint.
pub const HI_FINGERPRINT_BITS: u5 = 16;

/// Prefix byte indicating choseong token.
pub const CHOSEONG_MARKER: u8 = 0x01;

/// Marker byte prepended to edge n-gram prefix tokens (prefix_fields).
pub const PREFIX_MARKER: u8 = 0x02;

/// Marker byte prepended to duplicate copies of title-field tokens (and their
/// choseong tokens). Probed at query time as a secondary ranking signal:
/// docs whose *title* matches outrank body-only matches on equal hits.
pub const TITLE_MARKER: u8 = 0x03;

pub const HEADER_SIZE: usize = @sizeOf(Header);
pub const TAIL_META_SIZE: usize = @sizeOf(TailMeta);

/// 1-layer tokenization algorithm (header's tokenizer_kind field).
pub const TokenizerKind = enum(u8) {
    default = 0,
    _,
};

/// Filter type (header's filter_kind field).
///
/// Format-level reservation for future filter kinds — only binary_fuse is
/// implemented. Bloom (the original v1.0 filter) and xor were dropped in
/// SPEC v1.2: BinaryFuse subsumes both (smaller, faster, lower FP rate),
/// so no fallback exists. Writer always emits binary_fuse; reader/runtime
/// assume it. A future kind needs its own blob layout + runtime dispatch.
pub const FilterKind = enum(u8) {
    binary_fuse = 0,
    _,
};

/// Index header (32 bytes, 4-byte aligned).
/// All offsets relative to index byte start.
pub const Header = extern struct {
    magic: u32 = MAGIC,
    version: u8 = VERSION,
    filter_kind: FilterKind = .binary_fuse,
    /// Reserved for Bloom filter k; unused (0) with BinaryFuse.
    hash_k: u8 = 0,
    tokenizer_kind: TokenizerKind = .default,
    num_docs: u32 = 0,
    num_meta_fields: u32 = 0,
    meta_names_off: u32 = 0,
    doc_table_off: u32 = 0,
    string_pool_off: u32 = 0,
    filters_off: u32 = 0,
};

/// Document metadata table entry fixed prefix (16 bytes).
/// Followed by num_meta_fields MetaEntries.
/// v3: per-document filter_off/filter_len removed — filters are global.
pub const DocEntryPrefix = extern struct {
    /// Document title (string_pool relative).
    title_off: u32 = 0,
    title_len: u32 = 0,
    /// Document URL (string_pool relative).
    url_off: u32 = 0,
    url_len: u32 = 0,
};

/// Meta value position within DocEntry (within string pool).
pub const MetaEntry = extern struct {
    off: u32 = 0,
    len: u32 = 0,
};

/// Bundle tail metadata (16 bytes fixed, file end).
pub const TailMeta = extern struct {
    magic: u32 = MAGIC,
    version: u8 = VERSION,
    _reserved: [3]u8 = [_]u8{ 0, 0, 0 },
    wasm_len: u32 = 0,
    index_len: u32 = 0,
};

/// Total byte size of one DocEntry. = 16 + 8 * num_meta_fields.
pub inline fn docEntrySize(num_meta_fields: u32) usize {
    return @sizeOf(DocEntryPrefix) + @as(usize, num_meta_fields) * @sizeOf(MetaEntry);
}

/// Returns the MetaEntry array that follows the DocEntryPrefix as a slice.
pub fn metaEntries(prefix: *DocEntryPrefix, num_meta_fields: usize) []MetaEntry {
    const prefix_bytes: [*]u8 = @ptrCast(prefix);
    const after: [*]u8 = prefix_bytes + @sizeOf(DocEntryPrefix);
    const meta_ptr: [*]MetaEntry = @ptrCast(@alignCast(after));
    return meta_ptr[0..num_meta_fields];
}

// ── Assertion tests ────────────────────────────────────────────────────

test "magic number matches ASCII 'CHAZ' little-endian" {
    const bytes: [4]u8 = .{ 'C', 'H', 'A', 'Z' };
    try std.testing.expectEqual(MAGIC, std.mem.readInt(u32, &bytes, .little));
}

test "Header size and offsets (SPEC compliant)" {
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

test "DocEntryPrefix / MetaEntry sizes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(DocEntryPrefix));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(MetaEntry));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DocEntryPrefix, "title_off"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DocEntryPrefix, "title_len"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DocEntryPrefix, "url_off"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(DocEntryPrefix, "url_len"));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MetaEntry, "off"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(MetaEntry, "len"));
}

test "docEntrySize calculation" {
    try std.testing.expectEqual(@as(usize, 16), docEntrySize(0));
    try std.testing.expectEqual(@as(usize, 24), docEntrySize(1));
    try std.testing.expectEqual(@as(usize, 40), docEntrySize(3));
}

test "TailMeta size and offsets (16 bytes fixed)" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TailMeta));
    try std.testing.expectEqual(@as(usize, 4), @alignOf(TailMeta));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TailMeta, "magic"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(TailMeta, "version"));
    try std.testing.expectEqual(@as(usize, 5), @offsetOf(TailMeta, "_reserved"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(TailMeta, "wasm_len"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(TailMeta, "index_len"));
}

test "little-endian host assumed (wasm native = little-endian)" {
    try std.testing.expectEqual(.little, builtin.cpu.arch.endian());
}

test "Header defaults" {
    const h: Header = .{};
    try std.testing.expectEqual(MAGIC, h.magic);
    try std.testing.expectEqual(VERSION, h.version);
    try std.testing.expectEqual(FilterKind.binary_fuse, h.filter_kind);
    try std.testing.expectEqual(@as(u8, 0), h.hash_k);
    try std.testing.expectEqual(TokenizerKind.default, h.tokenizer_kind);
    try std.testing.expectEqual(@as(u32, 0), h.num_docs);
}

test "metaEntries slicing" {
    // DocEntryPrefix (16 bytes) + 3 MetaEntry (24 bytes) = 40 bytes
    var storage: [40]u8 = .{0} ** 40;
    const prefix: *DocEntryPrefix = @ptrCast(@alignCast(&storage));

    // Fill prefix
    prefix.title_off = 100;
    prefix.title_len = 42;

    // Fill 3 meta entries
    const metas = metaEntries(prefix, 3);
    try std.testing.expectEqual(@as(usize, 3), metas.len);
    metas[0].off = 1;
    metas[0].len = 2;
    metas[2].off = 9;
    metas[2].len = 10;

    // Verify actual bytes placed after prefix (offset 16)
    // metas[0].off @ 16, metas[2].len @ 16 + 2*8 + 4 = 36
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, storage[16..20], .little));
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, storage[36..40], .little));
}
