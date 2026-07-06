//! chaza 번들 조립/파싱 — [wasm][index][TailMeta 16B] 형식.
//!
//! 생성기는 assemble()로 세 영역을 하나로 붙여 .bundle 파일을 만들고,
//! 로더(JS)는 파일 끝 16바이트(TailMeta)를 먼저 읽어 wasm_len / index_len을 얻은 뒤
//! 각 영역 슬라이스를 추출한다. open()은 그 로직의 Zig 구현 (테스트·검증용).

const std = @import("std");
const format = @import("index/format.zig");
const TailMeta = format.TailMeta;

/// 번들 바이트를 할당해 반환. caller가 free.
/// layout: [wasm_bytes][index_bytes][pad to 4B][TailMeta 16B LE]
/// tail_off는 TailMeta의 4바이트 정렬 요구를 만족해야 함.
pub fn assemble(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    index_bytes: []const u8,
) ![]u8 {
    const index_end = wasm_bytes.len + index_bytes.len;
    // TailMeta(u32 포함) → 4바이트 정렬 필요. index_end를 4의 배수로 올림.
    const aligned_tail_off = (index_end + 3) & ~@as(usize, 3);
    const pad_len = aligned_tail_off - index_end;
    const total = aligned_tail_off + format.TAIL_META_SIZE;
    const buf = try allocator.alloc(u8, total);
    @memset(buf, 0); // 패딩 영역 0으로.

    // wasm 영역 복사
    @memcpy(buf[0..wasm_bytes.len], wasm_bytes);
    // index 영역 복사
    @memcpy(buf[wasm_bytes.len..][0..index_bytes.len], index_bytes);

    // TailMeta 기록 (필드별 리틀엔디안 기록 — alignCast 불필요)
    const t = aligned_tail_off;
    std.mem.writeInt(u32, buf[t..][0..4], format.MAGIC, .little);
    buf[t + 4] = format.VERSION;
    buf[t + 5] = 0;
    buf[t + 6] = 0;
    buf[t + 7] = 0;
    std.mem.writeInt(u32, buf[t + 8..][0..4], @intCast(wasm_bytes.len), .little);
    std.mem.writeInt(u32, buf[t + 12..][0..4], @intCast(index_bytes.len), .little);
    _ = pad_len; // 패딩은 buf의 memset(0)으로 채워짐.
    return buf;
}

/// open 결과: 각 섹션 슬라이스 + TailMeta 값 (모두 입력 bytes 내부 참조).
pub const BundleView = struct {
    wasm: []const u8,
    index: []const u8,
    tail: TailMeta,
};

pub const OpenError = error{
    Truncated,
    InvalidMagic,
    InvalidVersion,
    LengthMismatch,
};

/// 번들 바이트에서 각 섹션 슬라이스 추출. 할당 없음 (빌려쓰기).
pub fn open(bytes: []const u8) OpenError!BundleView {
    if (bytes.len < format.TAIL_META_SIZE) return error.Truncated;

    const tail_off = bytes.len - format.TAIL_META_SIZE;

    // 필드별 리틀엔디안 읽기 (alignCast 불필요)
    const magic = std.mem.readInt(u32, bytes[tail_off..][0..4], .little);
    const version = bytes[tail_off + 4];
    const wasm_len: usize = std.mem.readInt(u32, bytes[tail_off + 8..][0..4], .little);
    const index_len: usize = std.mem.readInt(u32, bytes[tail_off + 12..][0..4], .little);

    if (magic != format.MAGIC) return error.InvalidMagic;
    if (version != format.VERSION) return error.InvalidVersion;

    const data_end = wasm_len + index_len;
    if (tail_off < data_end) return error.LengthMismatch;
    const max_pad: usize = 3;
    if (tail_off > data_end + max_pad) return error.LengthMismatch;

    return .{
        .wasm = bytes[0..wasm_len],
        .index = bytes[wasm_len..data_end],
        .tail = .{
            .magic = magic,
            .version = version,
            ._reserved = .{ 0, 0, 0 },
            .wasm_len = @intCast(wasm_len),
            .index_len = @intCast(index_len),
        },
    };
}

// ── 단정 테스트 ────────────────────────────────────────────────────

test "assemble: 단순 케이스 — wasm 4B, index 8B → 총 28B" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    try std.testing.expectEqual(@as(usize, 28), bundle.len);
}

test "assemble: TailMeta magic/version/길이 필드 byte 단위 검증" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    // tail_off = 4 + 8 = 12
    const t = bundle.len - format.TAIL_META_SIZE; // 12

    // magic LE = 'C','H','A','Z'
    try std.testing.expectEqual(@as(u8, 'C'), bundle[t + 0]);
    try std.testing.expectEqual(@as(u8, 'H'), bundle[t + 1]);
    try std.testing.expectEqual(@as(u8, 'A'), bundle[t + 2]);
    try std.testing.expectEqual(@as(u8, 'Z'), bundle[t + 3]);

    // version = 2
    try std.testing.expectEqual(@as(u8, 2), bundle[t + 4]);

    // _reserved = {0,0,0}
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 5]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 6]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 7]);

    // wasm_len = 4 (LE u32)
    try std.testing.expectEqual(@as(u8, 4), bundle[t + 8]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 9]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 10]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 11]);

    // index_len = 8 (LE u32)
    try std.testing.expectEqual(@as(u8, 8), bundle[t + 12]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 13]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 14]);
    try std.testing.expectEqual(@as(u8, 0), bundle[t + 15]);
}

test "assemble: wasm과 index가 순서대로 복사됨" {
    const wasm = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const index = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    try std.testing.expectEqualSlices(u8, &wasm, bundle[0..4]);
    try std.testing.expectEqualSlices(u8, &index, bundle[4..12]);
}

test "open: 정상 — wasm/index 슬라이스가 assemble 입력과 동일" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    const view = try open(bundle);
    try std.testing.expectEqualSlices(u8, &wasm, view.wasm);
    try std.testing.expectEqualSlices(u8, &index, view.index);
    try std.testing.expectEqual(@as(u32, 4), view.tail.wasm_len);
    try std.testing.expectEqual(@as(u32, 8), view.tail.index_len);
}

test "open: Truncated (bytes < 16)" {
    const tiny = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    try std.testing.expectError(error.Truncated, open(&tiny));
}

test "open: InvalidMagic (magic 변조)" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    var corrupted = try std.testing.allocator.dupe(u8, bundle);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 16] = 0x00; // magic 첫 바이트 변조

    try std.testing.expectError(error.InvalidMagic, open(corrupted));
}

test "open: InvalidVersion (version 변조)" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    var corrupted = try std.testing.allocator.dupe(u8, bundle);
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 12] = 99; // version 변조

    try std.testing.expectError(error.InvalidVersion, open(corrupted));
}

test "open: LengthMismatch (wasm_len 합이 실제와 안 맞음)" {
    const wasm = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const bundle = try assemble(std.testing.allocator, &wasm, &index);
    defer std.testing.allocator.free(bundle);

    var corrupted = try std.testing.allocator.dupe(u8, bundle);
    defer std.testing.allocator.free(corrupted);
    // wasm_len 4 → 100: tail_off=12 이지만 100+8=108 ≠ 12
    corrupted[corrupted.len - 8] = 100;

    try std.testing.expectError(error.LengthMismatch, open(corrupted));
}

test "assemble + open 왕복: 큰 wasm(1KB), 큰 index(2KB)" {
    const wasm = try std.testing.allocator.alloc(u8, 1024);
    defer std.testing.allocator.free(wasm);
    const index = try std.testing.allocator.alloc(u8, 2048);
    defer std.testing.allocator.free(index);

    for (wasm, 0..) |*b, i| b.* = @intCast(i % 256);
    for (index, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 256);

    const bundle = try assemble(std.testing.allocator, wasm, index);
    defer std.testing.allocator.free(bundle);

    try std.testing.expectEqual(@as(usize, 1024 + 2048 + 16), bundle.len);

    const view = try open(bundle);
    try std.testing.expectEqualSlices(u8, wasm, view.wasm);
    try std.testing.expectEqualSlices(u8, index, view.index);
    try std.testing.expectEqual(@as(u32, 1024), view.tail.wasm_len);
    try std.testing.expectEqual(@as(u32, 2048), view.tail.index_len);
}
