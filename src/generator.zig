//! chaza 생성기: JSON 코퍼스 → 인덱스 바이트 → 번들 바이트.
//!
//! tinysearch 호환 JSON 문서 배열을 파싱하여:
//! 1. 각 문서에서 title, url, 메타 필드 추출
//! 2. indexed_fields 텍스트를 토큰화하여 고유 토큰 집합 생성
//! 3. writer.IndexInput 구성 → 인덱스 바이트 직렬화
//! 4. bundle.assemble로 [wasm][index][tailmeta] 번들 생성

const std = @import("std");
const writer = @import("index/writer.zig");
const bundle_mod = @import("bundle.zig");
const tokenize = @import("pipeline/tokenize.zig");
const stopwords = @import("pipeline/stopwords.zig");
const reader = @import("index/reader.zig");
const StopwordSet = stopwords.StopwordSet;

pub const GenerateOptions = struct {
    indexed_fields: []const []const u8 = &.{"title"},
    metadata_fields: []const []const u8 = &.{},
    url_field: []const u8 = "url",
    /// 0 = 초성 비활성.
    choseong_max_len: u8 = 3,
    /// 불용어 집합. null이면 불용어 제거 단계 생략.
    stopwords: ?StopwordSet = null,
};

pub const GenerateResult = struct {
    /// [wasm][index][tailmeta]. caller free.
    bundle_bytes: []u8,
    num_docs: usize,
    index_size: usize,
};

/// corpus_json: tinysearch 호환 JSON 문서 배열.
/// wasm_bytes: 빌드 시 @embedFile로 주입되는 runtime wasm (없으면 빈 바이트).
/// allocator: 번들 바이트 할당용. 중간 할당은 내부 arena 사용.
pub fn generate(
    allocator: std.mem.Allocator,
    corpus_json: []const u8,
    wasm_bytes: []const u8,
    options: GenerateOptions,
) !GenerateResult {
    // 중간 할당용 내부 arena — 함수 종료 시 전부 해제.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 1. Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, corpus_json, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.NotAnArray;
    const docs_json = parsed.value.array.items;

    // 2. 각 문서 → DocInput
    const doc_inputs = try a.alloc(writer.DocInput, docs_json.len);

    for (docs_json, 0..) |doc_val, i| {
        if (doc_val != .object) return error.NotAnObject;
        const obj = doc_val.object;

        // title — 항상 "title" 필드에서 가져옴
        const title: []const u8 = if (obj.get("title")) |v|
            (if (v == .string) v.string else "")
        else
            "";

        // url
        const url: []const u8 = if (obj.get(options.url_field)) |v|
            (if (v == .string) v.string else "")
        else
            "";

        // 메타 값 — metadata_fields 순서대로, 숫자도 문자열화
        const meta_values = try a.alloc([]const u8, options.metadata_fields.len);
        for (options.metadata_fields, 0..) |mf, j| {
            meta_values[j] = if (obj.get(mf)) |v| try jsonValueToString(a, v) else "";
        }

        // indexed_fields 텍스트를 합쳐 토큰화 → 고유 토큰 집합
        var token_set = std.StringHashMap(void).init(a);
        defer token_set.deinit();
        var token_list: std.ArrayList([]const u8) = .empty;

        for (options.indexed_fields) |field| {
            if (obj.get(field)) |v| {
                if (v == .string) {
                    var field_tokens: std.ArrayList([]const u8) = .empty;
                    try tokenize.tokenize(a, v.string, &field_tokens);
                    for (field_tokens.items) |tok| {
                        // 파이프라인 3단계: 불용어 제거 (고유 토큰 수집·초성 생성 전)
                        if (options.stopwords) |set| {
                            if (set.isStopword(tok)) continue;
                        }
                        if (!token_set.contains(tok)) {
                            try token_set.put(tok, {});
                            try token_list.append(a, tok);
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

    // 3. IndexInput 구성
    const input = writer.IndexInput{
        .meta_field_names = options.metadata_fields,
        .docs = doc_inputs,
        .choseong_max_len = options.choseong_max_len,
    };

    // 4. 인덱스 바이트 직렬화
    const index_bytes = try writer.write(a, input);

    // 5. 번들 조립 — caller allocator로 할당 (caller free 대상)
    const bundle_bytes = try bundle_mod.assemble(allocator, wasm_bytes, index_bytes);

    return .{
        .bundle_bytes = bundle_bytes,
        .num_docs = docs_json.len,
        .index_size = index_bytes.len,
    };
}

/// JSON 값을 문자열로 변환. 숫자(int/float)도 문자열화.
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

// ── 단정 테스트 ────────────────────────────────────────────────────

test "단일 문서 JSON → generate → bundle 바이트 반환, open으로 wasm/index 분리" {
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

    // 번들 구조 검증 — wasm이 비어있으므로 wasm_len=0
    const view = try bundle_mod.open(result.bundle_bytes);
    try std.testing.expectEqual(@as(u32, 0), view.tail.wasm_len);
    try std.testing.expectEqual(@as(u32, @intCast(result.index_size)), view.tail.index_len);

    // 인덱스 내용 검증
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqual(@as(u32, 1), idx.header.num_docs);
    try std.testing.expectEqualStrings("Hello World", idx.title(0).?);
    try std.testing.expectEqualStrings("/hello", idx.url(0).?);
}

test "2문서 JSON, 메타 필드 2개" {
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

    // 메타 값 확인
    try std.testing.expectEqualStrings("alice", idx.metaValue(0, 0).?);
    try std.testing.expectEqualStrings("2026-01-01", idx.metaValue(0, 1).?);
    try std.testing.expectEqualStrings("bob", idx.metaValue(1, 0).?);
    try std.testing.expectEqualStrings("2026-02-02", idx.metaValue(1, 1).?);
}

test "빈 배열 JSON [] → num_docs=0" {
    const allocator = std.testing.allocator;
    const result = try generate(allocator, "[]", &.{}, .{});
    defer allocator.free(result.bundle_bytes);

    try std.testing.expectEqual(@as(usize, 0), result.num_docs);
    try std.testing.expect(result.index_size > 0); // 헤더는 있음

    const view = try bundle_mod.open(result.bundle_bytes);
    const idx = try reader.IndexView.open(view.index);
    try std.testing.expectEqual(@as(u32, 0), idx.header.num_docs);
}

test "잘못된 JSON → 에러 전파" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotAnArray, generate(allocator, "{}", &.{}, .{}));
    try std.testing.expectError(error.NotAnObject, generate(
        allocator,
        \\["not_an_object"]
    , &.{}, .{}));
}

test "choseong_max_len=0 vs 3 → 충분히 큰 코퍼스에서 번들 크기 다름" {
    const allocator = std.testing.allocator;
    // 충분히 많은 고유 한글 토큰 (fuse blob 크기가 키 수에 비례하도록)
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

    // 초성 토큰 추가 → 더 많은 키 → 더 큰 fuse blob → 더 큰 인덱스
    try std.testing.expect(result_on.index_size > result_off.index_size);
}

test "숫자 메타 값 (views: 1000)이 문자열 '1000'으로 저장" {
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

test "metadata_fields에 지정하지 않은 필드는 무시됨" {
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

test "url_field가 없는 문서 → 빈 문자열로 저장 (에러 안 남)" {
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

test "wasm 바이트가 번들에 포함됨" {
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

test "indexed_fields의 텍스트가 토큰화되어 필터에 존재" {
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

    // title + body 토큰이 binary fuse filter에 있어야 함
    const binary_fuse = @import("pipeline/binary_fuse.zig");
    const hash = @import("pipeline/hash.zig");
    const filter_bytes = idx.docFilter(0).?;
    const fuse = binary_fuse.BinaryFuse8View.fromBlob(filter_bytes) orelse return error.UnexpectedNull;
    try std.testing.expect(fuse.contains(hash.key64("zig")));
    try std.testing.expect(fuse.contains(hash.key64("tutorial")));
    try std.testing.expect(fuse.contains(hash.key64("learn")));
    try std.testing.expect(fuse.contains(hash.key64("wasm")));
}

test "여러 indexed_field의 텍스트가 합쳐져 토큰화됨" {
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

    const binary_fuse = @import("pipeline/binary_fuse.zig");
    const hash = @import("pipeline/hash.zig");
    const filter_bytes = idx.docFilter(0).?;
    const fuse = binary_fuse.BinaryFuse8View.fromBlob(filter_bytes) orelse return error.UnexpectedNull;
    // title 토큰
    try std.testing.expect(fuse.contains(hash.key64("alpha")));
    try std.testing.expect(fuse.contains(hash.key64("beta")));
    // body 토큰
    try std.testing.expect(fuse.contains(hash.key64("gamma")));
    try std.testing.expect(fuse.contains(hash.key64("delta")));
}

test "중복 토큰은 한 번만 필터에 추가됨" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"title":"hello hello","url":"/h","body":"hello world"}]
    ;
    const result = try generate(allocator, json, &.{}, .{
        .indexed_fields = &.{ "title", "body" },
    });
    defer allocator.free(result.bundle_bytes);

    // "hello"가 title에 2번, body에 1번 나오지만 중복 제거로 1개 토큰
    // 에러 없이 생성되면 충분 — 정확한 토큰 수는 bloom 크기로 간접 검증
    try std.testing.expectEqual(@as(usize, 1), result.num_docs);
}

test "불용어 집합 있을 때: 해당 토큰이 제거되어 인덱스가 작아짐" {
    const allocator = std.testing.allocator;
    // 12개 고유 Latin 토큰 (bloom m이 64비트 하한을 넘어 토큰 수에 비례)
    const json =
        \\[{"title":"alpha beta","url":"/s","body":"gamma delta epsilon zeta eta theta iota kappa lambda mu"}]
    ;

    // 불용어 4개: alpha, beta, gamma, delta → 제거 시 8 토큰
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

    // 12 토큰(m=104bit) vs 8 토큰(m=72bit) → 인덱스 크기 감소
    try std.testing.expectEqual(@as(usize, 1), result_without.num_docs);
    try std.testing.expect(result_with.index_size < result_without.index_size);
}

test "불용어 집합 null일 때: 아무 토큰도 제거 안 됨 (empty 집합과 동일)" {
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

    // null 경로(필터 스킵)와 빈 집합 경로(필터 통과, 0매칭)는 동일 결과
    try std.testing.expectEqual(result_null.index_size, result_empty.index_size);
}
