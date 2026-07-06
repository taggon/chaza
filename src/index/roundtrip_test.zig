//! writer → reader 왕복 통합 테스트.
//! writer.zig와 reader.zig가 병렬로 refactor되어 호환성을 직접 검증.

const std = @import("std");
const writer = @import("writer.zig");
const reader = @import("reader.zig");

test "왕복: 단일 문서 title/url/meta 접근" {
    const allocator = std.testing.allocator;
    const docs = [_]writer.DocInput{
        .{
            .tokens = &.{ "hello", "world" },
            .title = "Hello World",
            .url = "https://example.com/hello",
            .meta_values = &.{"2026-01-01"},
        },
    };
    const input = writer.IndexInput{
        .meta_field_names = &.{"date"},
        .docs = &docs,
    };
    const bytes = try writer.write(allocator, input);
    defer allocator.free(bytes);

    const view = try reader.IndexView.open(bytes);

    // 헤더
    try std.testing.expectEqual(@as(u32, 1), view.header.num_docs);
    try std.testing.expectEqual(@as(u32, 1), view.header.num_meta_fields);

    // title / url
    try std.testing.expectEqualStrings("Hello World", view.title(0).?);
    try std.testing.expectEqualStrings("https://example.com/hello", view.url(0).?);

    // meta
    try std.testing.expectEqualStrings("2026-01-01", view.metaValue(0, 0).?);
    try std.testing.expectEqualStrings("date", view.metaNameAt(0).?);

    // filter 존재 (내용은 stand-alone 테스트에서)
    const filter = view.docFilter(0).?;
    try std.testing.expect(filter.len > 0);
}

test "왕복: 다중 문서, 다중 메타" {
    const allocator = std.testing.allocator;
    const docs = [_]writer.DocInput{
        .{
            .tokens = &.{ "apple", "banana" },
            .title = "과일 이야기",
            .url = "https://blog.example.com/fruit",
            .meta_values = &.{ "2026-01-01", "food" },
        },
        .{
            .tokens = &.{ "zig", "wasm" },
            .title = "Zig와 WASM",
            .url = "https://blog.example.com/zig",
            .meta_values = &.{ "2026-02-01", "tech" },
        },
    };
    const input = writer.IndexInput{
        .meta_field_names = &.{ "date", "tag" },
        .docs = &docs,
    };
    const bytes = try writer.write(allocator, input);
    defer allocator.free(bytes);

    const view = try reader.IndexView.open(bytes);
    try std.testing.expectEqual(@as(u32, 2), view.header.num_docs);
    try std.testing.expectEqual(@as(u32, 2), view.header.num_meta_fields);

    // doc 0
    try std.testing.expectEqualStrings("과일 이야기", view.title(0).?);
    try std.testing.expectEqualStrings("https://blog.example.com/fruit", view.url(0).?);
    try std.testing.expectEqualStrings("2026-01-01", view.metaValue(0, 0).?);
    try std.testing.expectEqualStrings("food", view.metaValue(0, 1).?);

    // doc 1
    try std.testing.expectEqualStrings("Zig와 WASM", view.title(1).?);
    try std.testing.expectEqualStrings("https://blog.example.com/zig", view.url(1).?);
    try std.testing.expectEqualStrings("2026-02-01", view.metaValue(1, 0).?);
    try std.testing.expectEqualStrings("tech", view.metaValue(1, 1).?);

    // meta 이름
    try std.testing.expectEqualStrings("date", view.metaNameAt(0).?);
    try std.testing.expectEqualStrings("tag", view.metaNameAt(1).?);
}

test "왕복: binary fuse filter에 토큰이 기록됨" {
    const allocator = std.testing.allocator;
    const tokens = [_][]const u8{ "alpha", "beta", "gamma" };
    const docs = [_]writer.DocInput{
        .{
            .tokens = &tokens,
            .title = "Tokens",
            .url = "/t",
            .meta_values = &.{},
        },
    };
    const input = writer.IndexInput{
        .meta_field_names = &.{},
        .docs = &docs,
    };
    const bytes = try writer.write(allocator, input);
    defer allocator.free(bytes);

    const view = try reader.IndexView.open(bytes);
    const filter_bytes = view.docFilter(0).?;

    // binary fuse filter 뷰로 역직렬화해 contains 확인
    const binary_fuse = @import("../pipeline/binary_fuse.zig");
    const hash = @import("../pipeline/hash.zig");
    const fuse = binary_fuse.BinaryFuse8View.fromBlob(filter_bytes) orelse return error.UnexpectedNull;

    for (tokens) |tok| {
        try std.testing.expect(fuse.contains(hash.key64(tok)));
    }
}

test "왕복: 빈 문서(tokens=[])도 정상" {
    const allocator = std.testing.allocator;
    const docs = [_]writer.DocInput{
        .{
            .tokens = &.{},
            .title = "Empty",
            .url = "/e",
            .meta_values = &.{"none"},
        },
    };
    const input = writer.IndexInput{
        .meta_field_names = &.{"note"},
        .docs = &docs,
    };
    const bytes = try writer.write(allocator, input);
    defer allocator.free(bytes);

    const view = try reader.IndexView.open(bytes);
    try std.testing.expectEqualStrings("Empty", view.title(0).?);
    try std.testing.expectEqualStrings("/e", view.url(0).?);
    try std.testing.expectEqualStrings("none", view.metaValue(0, 0).?);

    // filter blob은 최소 40바이트 (28헤더 + 12지문)
    const filter = view.docFilter(0).?;
    try std.testing.expectEqual(@as(usize, 40), filter.len);
}

test "왕복: 범위 초과 doc_id → null" {
    const allocator = std.testing.allocator;
    const docs = [_]writer.DocInput{
        .{ .tokens = &.{"x"}, .title = "X", .url = "/x", .meta_values = &.{} },
    };
    const input = writer.IndexInput{
        .meta_field_names = &.{},
        .docs = &docs,
    };
    const bytes = try writer.write(allocator, input);
    defer allocator.free(bytes);

    const view = try reader.IndexView.open(bytes);
    try std.testing.expect(view.title(1) == null);
    try std.testing.expect(view.url(1) == null);
    try std.testing.expect(view.docFilter(1) == null);
    try std.testing.expect(view.docMetaEntries(1) == null);
}
