//! chaza 런타임: WASM export API — in-memory 검색.
//!
//! 전역 IndexView에 등록된 인덱스 바이트를 대상으로:
//! 쿼리 토큰화 → 각 문서 BinaryFuse8 filter AND 조회 → 정렬 → 결과 인코딩.
//! 결과는 [u32 count LE][u32 doc_id × count LE] 포맷의 전역 버퍼에 기록.

const std = @import("std");
const reader = @import("index/reader.zig");
const writer = @import("index/writer.zig");
const binary_fuse = @import("pipeline/binary_fuse.zig");
const hash = @import("pipeline/hash.zig");
const tokenize = @import("pipeline/tokenize.zig");
const choseong = @import("pipeline/choseong.zig");

// ── 전역 상태 ──

var g_index: ?reader.IndexView = null;
var g_result_buffer: std.ArrayList(u8) = .empty;
const g_allocator: std.mem.Allocator = std.heap.page_allocator;

/// alloc 실패 시 정적 빈 결과 (count=0 LE).
const empty_result: [4]u8 = .{ 0, 0, 0, 0 };

// ── export API ──
//
// callconv(.c) — wasm32에서는 wasm 호환 C calling convention. @export로 심볼 노출.

/// JS 메모리 할당 요청. n바이트를 page_allocator로 확보해 포인터 반환.
pub fn alloc(n: usize) callconv(.c) [*]u8 {
    const buf = g_allocator.alloc(u8, n) catch @panic("chaza: alloc failed");
    return buf.ptr;
}

/// 인덱스 바이트 등록. set_index 이후 메모리 grow 금지 (포인터 무효화).
pub fn set_index(ptr: [*]const u8, len: usize) callconv(.c) void {
    const bytes = ptr[0..len];
    g_index = reader.IndexView.open(bytes) catch {
        g_index = null;
        return;
    };
}

/// 검색 실행. 결과 버퍼 포인터([u32 count LE][u32 doc_id × count LE]) 반환.
pub fn search(
    query_ptr: [*]const u8,
    query_len: usize,
    max_results: u32,
    sort_field_idx: i32,
    sort_desc: bool,
) callconv(.c) [*]const u8 {
    const view = g_index orelse return writeEmptyResult();

    // arena: 토큰화 메모리는 search 종료 시 전부 해제
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    // 쿼리 토큰화
    var tokens: std.ArrayList([]const u8) = .empty;
    tokenize.tokenize(arena_alloc, query_ptr[0..query_len], &tokens) catch return writeEmptyResult();

    // 초성 쿼리 처리: 초성 자모로만 이루어진 토큰에 마커 추가
    choseong.markChoseongQueries(arena_alloc, &tokens) catch return writeEmptyResult();

    // 빈 쿼리 → 결과 없음
    if (tokens.items.len == 0) return writeEmptyResult();

    // hit 문서 수집 (AND)
    var hits: std.ArrayList(u32) = .empty;
    defer hits.deinit(g_allocator);

    var doc_id: u32 = 0;
    while (doc_id < view.header.num_docs) : (doc_id += 1) {
        if (docMatchesAllTokens(view, doc_id, tokens.items)) {
            hits.append(g_allocator, doc_id) catch return writeEmptyResult();
        }
    }

    // 정렬
    if (sort_field_idx >= 0) {
        const ctx: SortCtx = .{
            .view = view,
            .field_idx = @intCast(sort_field_idx),
            .desc = sort_desc,
        };
        std.sort.block(u32, hits.items, ctx, sortLessThan);
    }

    // 자르기
    const effective_max: usize = if (max_results == 0) 20 else @intCast(max_results);
    const count: usize = @min(hits.items.len, effective_max);

    // 결과 인코딩: [u32 count LE][u32 doc_id × count LE]
    g_result_buffer.clearRetainingCapacity();
    appendU32LE(&g_result_buffer, @intCast(count)) catch return @ptrCast(&empty_result);
    for (0..count) |i| {
        appendU32LE(&g_result_buffer, hits.items[i]) catch return @ptrCast(&empty_result);
    }

    return g_result_buffer.items.ptr;
}

// ── 내부 함수 ──

/// 문서의 BinaryFuse8 filter에 모든 토큰이 hit인지 확인 (AND).
fn docMatchesAllTokens(
    view: reader.IndexView,
    doc_id: u32,
    tokens: []const []const u8,
) bool {
    const filter_bytes = view.docFilter(doc_id) orelse return false;
    if (filter_bytes.len == 0) return false;
    const fuse = binary_fuse.BinaryFuse8View.fromBlob(filter_bytes) orelse return false;
    for (tokens) |tok| {
        if (!fuse.contains(hash.key64(tok))) return false;
    }
    return true;
}

/// 결과 버퍼에 u32 리틀엔디안 추가.
fn appendU32LE(buf: *std.ArrayList(u8), val: u32) !void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, val, .little);
    try buf.appendSlice(g_allocator, &tmp);
}

/// 빈 결과(count=0)를 g_result_buffer에 기록하고 포인터 반환.
fn writeEmptyResult() [*]const u8 {
    g_result_buffer.clearRetainingCapacity();
    appendU32LE(&g_result_buffer, 0) catch return @ptrCast(&empty_result);
    return g_result_buffer.items.ptr;
}

/// 정렬 컨텍스트.
const SortCtx = struct {
    view: reader.IndexView,
    field_idx: usize,
    desc: bool,
};

/// 정렬 비교: 메타 값 문자열 사전순. null(값 없음)은 맨 뒤.
fn sortLessThan(ctx: SortCtx, a: u32, b: u32) bool {
    const a_val = ctx.view.metaValue(a, ctx.field_idx);
    const b_val = ctx.view.metaValue(b, ctx.field_idx);

    // null은 asc/desc 관계없이 맨 뒤
    if (a_val == null and b_val == null) return false;
    if (a_val == null) return false;
    if (b_val == null) return true;

    const cmp = std.mem.order(u8, a_val.?, b_val.?);
    return if (ctx.desc) cmp == .gt else cmp == .lt;
}

// ── 단정 테스트 ────────────────────────────────────────────────────

const DocInput = writer.DocInput;
const IndexInput = writer.IndexInput;

/// 테스트용 4문서 코퍼스 빌드. caller가 free.
fn buildCorpus(allocator: std.mem.Allocator) ![]u8 {
    const docs = [_]DocInput{
        .{ .tokens = &.{ "hello", "world" }, .title = "Hello World", .url = "/hello", .meta_values = &.{"2026-03-15"} },
        .{ .tokens = &.{ "hello", "zig" }, .title = "Hello Zig", .url = "/zig", .meta_values = &.{"2026-01-10"} },
        .{ .tokens = &.{ "hello", "wasm" }, .title = "Hello WASM", .url = "/wasm", .meta_values = &.{"2026-02-20"} },
        .{ .tokens = &.{ "안녕", "hello" }, .title = "안녕 Hello", .url = "/kor", .meta_values = &.{"2026-04-05"} },
    };
    const input = IndexInput{
        .meta_field_names = &.{"date"},
        .docs = &docs,
        .choseong_max_len = 3,
    };
    return writer.write(allocator, input);
}

/// 결과 버퍼에서 count 읽기.
fn resultCount(ptr: [*]const u8) u32 {
    return std.mem.readInt(u32, ptr[0..4], .little);
}

/// 결과 버퍼에서 i번째 doc_id 읽기.
fn resultDocId(ptr: [*]const u8, i: usize) u32 {
    return std.mem.readInt(u32, ptr[4 + i * 4 ..][0..4], .little);
}

/// 테스트 클린업: g_index 해제 + 결과 버퍼 비움.
pub fn testCleanup() void {
    g_index = null;
    g_result_buffer.clearRetainingCapacity();
}

test "단일 토큰 'hello' → 4문서 hit (입력 순)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 3));
}

test "존재하지 않는 토큰 → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "zzznonexistentzzz";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "다중 토큰 AND: 'hello zig' → doc 1만 hit" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zig";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 0));
}

test "다중 토큰 AND: 'hello nonexistent' → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello zzznonexistentzzz";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "max_results=1 → 1개만 반환" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 1, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
}

test "max_results=0 → 기본 20 (전체 반환)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, -1, false);

    // 4문서 코퍼스 → 전체 4개 (기본 20 > 4)
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
}

test "sort_field_idx=-1 → 입력 순 (정렬 안 함)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 3));
}

test "sort_field_idx=0 asc → 날짜 오름차순" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, 0, false); // asc

    // 2026-01-10(1), 2026-02-20(2), 2026-03-15(0), 2026-04-05(3)
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 3));
}

test "sort_field_idx=0 desc → 날짜 내림차순" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, 0, true); // desc

    // 2026-04-05(3), 2026-03-15(0), 2026-02-20(2), 2026-01-10(1)
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 3));
}

test "결과 버퍼 포맷: 첫 4바이트 LE u32 count + doc_ids" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "world";
    const result = search(q.ptr, q.len, 0, -1, false);

    // "world"는 doc 0에만 있음
    const count = std.mem.readInt(u32, result[0..4], .little);
    try std.testing.expectEqual(@as(u32, 1), count);

    const id = std.mem.readInt(u32, result[4..8], .little);
    try std.testing.expectEqual(@as(u32, 0), id);
}

test "한글 토큰 '안녕' 검색" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "안녕";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "초성 쿼리 'ㅇ' → 안녕 문서(doc 3) hit" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㅇ";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "초성 쿼리 'ㅇㄴ' → 안녕 문서(doc 3) hit (2글자 접두 매칭)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㅇㄴ";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "초성 쿼리 'ㄱ' → miss (안녕은 ㅇ으로 시작, ㄱ 아님)" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "ㄱ";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "초성 쿼리가 일반 한글과 매칭 안 됨: 'ㅇ' ≠ '안녕' 토큰" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    // 'ㅇ' 초성 쿼리는 0x01ㅇ 마커 토큰으로 변환됨 → '안녕' 원본 토큰과 다름
    // 하지만 choseong 토큰 0x01ㅇ가 필터에 있으므로 doc 3 hit
    const q = "ㅇ";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 1), resultCount(result));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 0));
}

test "영어 쿼리 'hello'는 choseong 영향 없음" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
}

test "정렬: metaValue null인 문서는 맨 뒤" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);

    // doc 0의 MetaEntry.off를 손상시켜 metaValue(0, 0) → null 유도
    const header: *const reader.Header = @ptrCast(@alignCast(bytes.ptr));
    const meta0_byte_off = @as(usize, header.doc_table_off) + @sizeOf(reader.DocEntryPrefix);
    std.mem.writeInt(u32, bytes[meta0_byte_off..][0..4], 0xFFFFFFFF, .little);

    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, 0, false); // sort by date asc

    // doc 0는 null → 맨 뒤. 나머지는 날짜순: 1(01-10), 2(02-20), 3(04-05)
    try std.testing.expectEqual(@as(u32, 4), resultCount(result));
    try std.testing.expectEqual(@as(u32, 1), resultDocId(result, 0));
    try std.testing.expectEqual(@as(u32, 2), resultDocId(result, 1));
    try std.testing.expectEqual(@as(u32, 3), resultDocId(result, 2));
    try std.testing.expectEqual(@as(u32, 0), resultDocId(result, 3)); // null → 맨 뒤
}

test "g_index 미설정 시 search → count=0" {
    g_index = null;
    defer testCleanup();

    const q = "hello";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "빈 쿼리 → count=0" {
    const allocator = std.testing.allocator;
    const bytes = try buildCorpus(allocator);
    defer allocator.free(bytes);
    set_index(bytes.ptr, bytes.len);
    defer testCleanup();

    const q = "";
    const result = search(q.ptr, q.len, 0, -1, false);

    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

test "set_index: 잘못된 매직 → g_index=null, search → count=0" {
    var bad_bytes: [64]u8 = .{0} ** 64;
    set_index(&bad_bytes, bad_bytes.len);
    defer testCleanup();

    try std.testing.expect(g_index == null);

    const q = "test";
    const result = search(q.ptr, q.len, 0, -1, false);
    try std.testing.expectEqual(@as(u32, 0), resultCount(result));
}

// ── wasm export 강제 (lazy compilation 회피) ──
comptime {
    @export(&alloc, .{ .name = "alloc" });
    @export(&set_index, .{ .name = "set_index" });
    @export(&search, .{ .name = "search" });
}
