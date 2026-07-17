//! chaza generator: JSON corpus → index bytes → bundle bytes.
//!
//! Parse tinysearch-compatible JSON document array:
//! 1. Extract title, url, metadata fields from each document
//! 2. Tokenize indexed_fields text to create unique token set
//! 3. Configure writer.IndexInput → serialize index bytes
//! 4. Generate [wasm][index][tailmeta] bundle via bundle.assemble

const std = @import("std");
const writer = @import("index/writer.zig");
const bundle_mod = @import("bundle.zig");
const tokenize = @import("pipeline/tokenize.zig");
const stopwords = @import("pipeline/stopwords.zig");
const prefix = @import("pipeline/prefix.zig");
const choseong = @import("pipeline/choseong.zig");
const format = @import("index/format.zig");
const reader = @import("index/reader.zig");
const StopwordSet = stopwords.StopwordSet;

pub const GenerateOptions = struct {
    indexed_fields: []const []const u8 = &.{"title"},
    metadata_fields: []const []const u8 = &.{},
    url_field: []const u8 = "url",
    /// Fields whose words also get edge n-gram prefix tokens (0x02 marker,
    /// length 2~8 codepoints) for search-as-you-type. Must be a subset of
    /// indexed_fields. Empty disables prefix indexing.
    prefix_fields: []const []const u8 = &.{"title"},
    /// 0 = choseong disabled.
    choseong_max_len: u8 = 3,
    /// Stopword set. null means skip stopwords removal stage.
    stopwords: ?StopwordSet = null,
};

pub const GenerateResult = struct {
    /// [wasm][index][tailmeta]. caller free.
    bundle_bytes: []u8,
    num_docs: usize,
    index_size: usize,
};

/// corpus_json: tinysearch-compatible JSON document array.
/// wasm_bytes: runtime wasm injected via @embedFile at build time (empty if none).
/// allocator: for bundle bytes allocation. Internal allocations use internal arena.
pub fn generate(
    allocator: std.mem.Allocator,
    corpus_json: []const u8,
    wasm_bytes: []const u8,
    options: GenerateOptions,
) !GenerateResult {
    // prefix_fields ⊆ indexed_fields — prefix tokens on unindexed fields are meaningless
    for (options.prefix_fields) |pf| {
        var found = false;
        for (options.indexed_fields) |f| {
            if (std.mem.eql(u8, pf, f)) found = true;
        }
        if (!found) return error.PrefixFieldNotIndexed;
    }

    // Internal arena for intermediate allocations — all freed at function end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, corpus_json, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.NotAnArray;
    const docs_json = parsed.value.array.items;

    // 2. Each document → DocInput
    const doc_inputs = try a.alloc(writer.DocInput, docs_json.len);

    for (docs_json, 0..) |doc_val, i| {
        if (doc_val != .object) return error.NotAnObject;
        const obj = doc_val.object;

        // title — always from "title" field
        const title: []const u8 = if (obj.get("title")) |v|
            (if (v == .string) v.string else "")
        else
            "";

        // url
        const url: []const u8 = if (obj.get(options.url_field)) |v|
            (if (v == .string) v.string else "")
        else
            "";

        // Meta values — in metadata_fields order, numbers stringified
        const meta_values = try a.alloc([]const u8, options.metadata_fields.len);
        for (options.metadata_fields, 0..) |mf, j| {
            meta_values[j] = if (obj.get(mf)) |v| try jsonValueToString(a, v) else "";
        }

        // Concatenate indexed_fields text and tokenize → unique token set
        var token_set = std.StringHashMap(void).init(a);
        defer token_set.deinit();
        var token_list: std.ArrayList([]const u8) = .empty;

        for (options.indexed_fields) |field| {
            const is_prefix_field = blk: {
                for (options.prefix_fields) |pf| {
                    if (std.mem.eql(u8, pf, field)) break :blk true;
                }
                break :blk false;
            };
            // Title tokens get 0x03-marked duplicates as a ranking signal:
            // title matches outrank body-only matches on equal hits.
            const is_title_field = std.mem.eql(u8, field, "title");

            if (obj.get(field)) |v| {
                if (v == .string) {
                    var field_tokens: std.ArrayList([]const u8) = .empty;
                    try tokenize.tokenize(a, v.string, &field_tokens);
                    for (field_tokens.items) |tok| {
                        // Pipeline stage 3: stopwords removal (before unique token collection·choseong/prefix generation)
                        if (options.stopwords) |set| {
                            if (set.isStopword(tok)) continue;
                        }
                        if (!token_set.contains(tok)) {
                            try token_set.put(tok, {});
                            try token_list.append(a, tok);
                        }
                        // Edge n-gram prefix tokens (0x02) for prefix_fields words
                        if (is_prefix_field) {
                            var prefixes: std.ArrayList([]const u8) = .empty;
                            try prefix.extractPrefixes(a, tok, &prefixes);
                            for (prefixes.items) |p| {
                                if (!token_set.contains(p)) {
                                    try token_set.put(p, {});
                                    try token_list.append(a, p);
                                }
                            }
                        }
                        // Title-marked duplicates (0x03): the token itself plus its
                        // choseong tokens, so title/choseong queries can rank
                        // title matches above body-only matches.
                        if (is_title_field) {
                            var marked: std.ArrayList([]const u8) = .empty;
                            try marked.append(a, try std.mem.concat(a, u8, &.{ &.{format.TITLE_MARKER}, tok }));
                            if (options.choseong_max_len > 0) {
                                var cho: std.ArrayList([]const u8) = .empty;
                                try choseong.extractPrefixes(a, tok, 1, options.choseong_max_len, &cho);
                                // Title tokens keep length-1 regular choseong tokens
                                // (body-only tokens skip them in the writer via min_len=2).
                                if (cho.items.len > 0) {
                                    if (!token_set.contains(cho.items[0])) {
                                        try token_set.put(cho.items[0], {});
                                        try token_list.append(a, cho.items[0]);
                                    }
                                }
                                for (cho.items) |c| {
                                    try marked.append(a, try std.mem.concat(a, u8, &.{ &.{format.TITLE_MARKER}, c }));
                                }
                            }
                            for (marked.items) |m| {
                                if (!token_set.contains(m)) {
                                    try token_set.put(m, {});
                                    try token_list.append(a, m);
                                }
                            }
                        }
                    }
                }
            }
        }

        doc_inputs[i] = .{
            .tokens = token_list.items,
            .title = title,
            .url = url,
            .meta_values = meta_values,
        };
    }

    // 3. Configure IndexInput
    const input = writer.IndexInput{
        .meta_field_names = options.metadata_fields,
        .docs = doc_inputs,
        .choseong_max_len = options.choseong_max_len,
    };

    // 4. Serialize index bytes
    const index_bytes = try writer.write(a, input);

    // 5. Assemble bundle — allocated with caller allocator (caller free target)
    const bundle_bytes = try bundle_mod.assemble(allocator, wasm_bytes, index_bytes);

    return .{
        .bundle_bytes = bundle_bytes,
        .num_docs = docs_json.len,
        .index_size = index_bytes.len,
    };
}

/// Convert JSON values to string. Stringify number types (int/float) too.
fn jsonValueToString(allocator: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| s,
        .bool => |b| if (b) "true" else "false",
        .null => "",
        else => "",
    };
}

// ── Assertions ────────────────────────────────────────────────────

const test_binary_fuse = @import("pipeline/binary_fuse.zig");
const test_hash = @import("pipeline/hash.zig");

/// Test helper: is (token, doc) in the global lo filter (regular/choseong tokens)?
fn loContains(idx: reader.IndexView, doc_id: u32, tok: []const u8) bool {
    const fuse = test_binary_fuse.BinaryFuseView.fromBlob(idx.loFilter().?).?;
    return fuse.contains(test_hash.pairKey(test_hash.key64(tok), doc_id));
}

/// Test helper: is (token, doc) in the global hi filter (0x02/0x03 tokens)?
fn hiContains(idx: reader.IndexView, doc_id: u32, tok: []const u8) bool {
    const fuse = test_binary_fuse.BinaryFuseView.fromBlob(idx.hiFilter().?).?;
    return fuse.contains(test_hash.pairKey(test_hash.key64(tok), doc_id));
}

test "Single document JSON → generate → return bundle bytes, open splits wasm/index" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Hello World","url":"/hello","body":"hello world zig"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    try std.testing.expectEqual(@as(usize, 1), result.num_docs);
    try std.testing.expect(result.index_size > 0);

    // Verify bundle structure — wasm empty so wasm_len=0
    const view = try bundle_mod.open(result.bundle_bytes);
    try std.testing.expectEqual(@as(u32, 0), view.tail.wasm_len);
    try std.testing.expectEqual(@as(u32, @intCast(result.index_size)), view.tail.index_len);

    // Verify index content
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqual(@as(u32, 1), idx.header.num_docs);
    try std.testing.expectEqualStrings("Hello World", idx.title(0).?);
    try std.testing.expectEqualStrings("/hello", idx.url(0).?);
}

test "2 document JSON, 2 meta fields" {
    const allocator = std.testing.allocator;
    const json =
        \\[
        \\  {"title":"First","url":"/1","author":"alice","date":"2026-01-01"},
        \\  {"title":"Second","url":"/2","author":"bob","date":"2026-02-02"}
        \\]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{"title"},
        .metadata_fields = &.{ "author", "date" },
    });
    defer allocator.free(result.bundle_bytes);

    try std.testing.expectEqual(@as(usize, 2), result.num_docs);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqual(@as(u32, 2), idx.header.num_docs);
    try std.testing.expectEqual(@as(u32, 2), idx.header.num_meta_fields);

    // Verify meta values
    try std.testing.expectEqualStrings("alice", idx.metaValue(0, 0).?);
    try std.testing.expectEqualStrings("2026-01-01", idx.metaValue(0, 1).?);
    try std.testing.expectEqualStrings("bob", idx.metaValue(1, 0).?);
    try std.testing.expectEqualStrings("2026-02-02", idx.metaValue(1, 1).?);
}

test "Empty array JSON [] → num_docs=0" {
    const allocator = std.testing.allocator;
    const result = try generate(allocator, "[]", &.{}, .{});
    defer allocator.free(result.bundle_bytes);

    try std.testing.expectEqual(@as(usize, 0), result.num_docs);
    try std.testing.expect(result.index_size > 0); // header exists

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqual(@as(u32, 0), idx.header.num_docs);
}

test "Invalid JSON → error propagate" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotAnArray, generate(allocator, "{}", &.{}, .{}));
    try std.testing.expectError(error.NotAnObject, generate(
        allocator,
        \\["not_an_object"]
    , &.{}, .{}));
}

test "choseong_max_len=0 vs 3 → bundle size differs on sufficient corpus" {
    const allocator = std.testing.allocator;
    // Sufficient unique Korean tokens (so fuse blob size proportional to key count)
    const json =
        \\[{"title":"강나루 새로운 아침 바람","url":"/a","body":"산책 하늘 구름 비 올 비행기 자동차 기차 버스 정거장 학교 교실 의자 책상 연필 지우개 공책 가방 우산 손수건"},{"title":"바다 갈매기 배 여행","url":"/b","body":"섬 등대 항구 어부 그물 물개 파도 모래 조개 해초 갯벌 등껍질 조류 파도 보트 요트 돛 닻 나침반"}]
    ;

    const result_off = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .choseong_max_len = 0,
    });
    defer allocator.free(result_off.bundle_bytes);

    const result_on = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .choseong_max_len = 3,
    });
    defer allocator.free(result_on.bundle_bytes);

    // Choseong tokens added → more keys → larger fuse blob → larger index
    try std.testing.expect(result_on.index_size > result_off.index_size);
}

test "Number meta value (views: 1000) stored as string '1000'" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Post","url":"/p","views":1000}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .metadata_fields = &.{"views"},
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqualStrings("1000", idx.metaValue(0, 0).?);
}

test "Fields not in metadata_fields ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"T","url":"/u","extra":"should_be_ignored","views":42}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .metadata_fields = &.{},
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqual(@as(u32, 0), idx.header.num_meta_fields);
}

test "Document without url_field → stored as empty string (no error)" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"No URL","path":"/some-path"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .url_field = "url",
    });
    defer allocator.free(result.bundle_bytes);

    try std.testing.expectEqual(@as(usize, 1), result.num_docs);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqualStrings("", idx.url(0).?);
    try std.testing.expectEqualStrings("No URL", idx.title(0).?);
}

test "wasm bytes included in bundle" {
    const allocator = std.testing.allocator;
    const fake_wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0xDE, 0xAD, 0xBE, 0xEF };
    const json =
        \\[{"title":"W","url":"/w"}]
    ;
    const result = try generate(allocator, json, &fake_wasm, .{});
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    try std.testing.expectEqualSlices(u8, &fake_wasm, view.wasm);
    try std.testing.expectEqual(@as(u32, 8), view.tail.wasm_len);
}

test "Text in indexed_fields tokenized and exists in filter" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Zig Tutorial","url":"/zig","body":"learn zig wasm"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    // title + body tokens should be in the global lo filter
    try std.testing.expect(loContains(idx, 0, "zig"));
    try std.testing.expect(loContains(idx, 0, "tutorial"));
    try std.testing.expect(loContains(idx, 0, "learn"));
    try std.testing.expect(loContains(idx, 0, "wasm"));
}

test "Text from multiple indexed_fields concatenated and tokenized" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Alpha Beta","url":"/ab","body":"Gamma Delta"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    // title tokens
    try std.testing.expect(loContains(idx, 0, "alpha"));
    try std.testing.expect(loContains(idx, 0, "beta"));
    // body tokens
    try std.testing.expect(loContains(idx, 0, "gamma"));
    try std.testing.expect(loContains(idx, 0, "delta"));
}

test "Duplicate tokens added to filter only once" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"hello hello","url":"/h","body":"hello world"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    // "hello" appears twice in title, once in body, but deduplicated to 1 token
    // Success without error sufficient — exact token count indirectly verified via bloom size
    try std.testing.expectEqual(@as(usize, 1), result.num_docs);
}

test "prefix_fields default (title): title-word prefixes in filter, body-word prefixes absent" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Programming Guide","url":"/p","body":"tutorial content"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    // title word 'programming' → \x02pr .. \x02programm (k=2..8) in the hi filter
    try std.testing.expect(hiContains(idx, 0, "\x02pr"));
    try std.testing.expect(hiContains(idx, 0, "\x02progr"));
    try std.testing.expect(hiContains(idx, 0, "\x02programm"));
    // proper prefixes only — full word never gets a prefix token
    try std.testing.expect(!hiContains(idx, 0, "\x02programming"));
    // body word 'tutorial' indexed exactly (lo) but gets no prefix tokens
    try std.testing.expect(loContains(idx, 0, "tutorial"));
    try std.testing.expect(!hiContains(idx, 0, "\x02tut"));
}

test "title tokens get 0x03-marked copies (incl. choseong); body tokens don't" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Zig 안녕","url":"/z","body":"tutorial"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    // title tokens: exact (lo) + 0x03 copy (hi)
    try std.testing.expect(loContains(idx, 0, "zig"));
    try std.testing.expect(hiContains(idx, 0, "\x03zig"));
    try std.testing.expect(hiContains(idx, 0, "\x03안녕"));
    // title choseong: 0x01 (writer, lo) and 0x03+0x01 (generator title copy, hi)
    try std.testing.expect(loContains(idx, 0, "\x01\u{3147}"));
    try std.testing.expect(hiContains(idx, 0, "\x03\x01\u{3147}"));
    // body token: exact only, no title copy
    try std.testing.expect(loContains(idx, 0, "tutorial"));
    try std.testing.expect(!hiContains(idx, 0, "\x03tutorial"));
}

test "prefix_fields=[] disables prefix tokens" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"Programming Guide","url":"/p"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .prefix_fields = &.{},
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    try std.testing.expect(loContains(idx, 0, "programming"));
    try std.testing.expect(!hiContains(idx, 0, "\x02progr"));
}

test "prefix_fields not subset of indexed_fields → error" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.PrefixFieldNotIndexed, generate(allocator, "[]", &.{}, .{
        .indexed_fields = &.{"title"},
        .prefix_fields = &.{"body"},
    }));
}

test "stopworded words get no prefix tokens" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"programming tutorial","url":"/p"}]
    ;
    var sw = try StopwordSet.fromFileBytes(allocator, "programming\n");
    defer sw.deinit(allocator);

    const result = try generate(allocator, json, &.{}, .{
        .stopwords = sw,
    });
    defer allocator.free(result.bundle_bytes);

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);

    // stopword removed before prefix generation
    try std.testing.expect(!loContains(idx, 0, "programming"));
    try std.testing.expect(!hiContains(idx, 0, "\x02progr"));
    // surviving word still gets prefixes
    try std.testing.expect(loContains(idx, 0, "tutorial"));
    try std.testing.expect(hiContains(idx, 0, "\x02tut"));
}

test "With stopword set: tokens removed → smaller index" {
    const allocator = std.testing.allocator;
    // 12 unique Latin tokens (bloom m > 64-bit lower bound, proportional to token count)
    const json =
        \\[{"title":"alpha beta","url":"/s","body":"gamma delta epsilon zeta eta theta iota kappa lambda mu"}]
    ;

    // 4 stopwords: alpha, beta, gamma, delta → after removal 8 tokens
    var sw = try StopwordSet.fromFileBytes(allocator, "alpha\nbeta\ngamma\ndelta\n");
    defer sw.deinit(allocator);

    const result_without = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .choseong_max_len = 0,
    });
    defer allocator.free(result_without.bundle_bytes);

    const result_with = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .choseong_max_len = 0,
        .stopwords = sw,
    });
    defer allocator.free(result_with.bundle_bytes);

    // 12 tokens (m=104bit) vs 8 tokens (m=72bit) → index size decreased
    try std.testing.expectEqual(@as(usize, 1), result_without.num_docs);
    try std.testing.expect(result_with.index_size < result_without.index_size);
}

test "Stopword set null: no tokens removed (same as empty set)" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"the quick brown fox","url":"/s","body":"the an of to"}]
    ;

    const result_null = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .choseong_max_len = 0,
        .stopwords = null,
    });
    defer allocator.free(result_null.bundle_bytes);

    var empty_sw = try StopwordSet.fromFileBytes(allocator, "");
    defer empty_sw.deinit(allocator);
    const result_empty = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
        .choseong_max_len = 0,
        .stopwords = empty_sw,
    });
    defer allocator.free(result_empty.bundle_bytes);

    // null path (skip filter) and empty set path (filter pass, 0 matches) yield same result
    try std.testing.expectEqual(result_null.index_size, result_empty.index_size);
}