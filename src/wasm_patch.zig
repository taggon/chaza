//! chaza wasm patcher — embeds index bytes directly into the runtime wasm
//! binary as active data segments.
//!
//! embed() rewrites the module:
//!   1. Memory section: min pages extended so the index region [old_end,
//!      old_end + index_len) is inside initial memory (index sits at the old
//!      memory end, page-aligned).
//!   2. Data section: two active segments added —
//!        a) metadata segment: 8 bytes (ptr LE, len LE) written to the
//!           runtime's g_embedded_index slot, whose address the patcher
//!           discovers by scanning for the sentinel pattern (0xFEEDFACE × 2)
//!           in the existing data section.
//!        b) index segment: the index bytes at the old memory end.
//!   3. Data count section (if present): count incremented by 2.
//!
//! No globals or exports are injected. The runtime initializes
//! g_embedded_index to {SENTINEL, SENTINEL}; the patcher's metadata segment
//! overwrites it with the real (ptr, len) at instantiation time.
//!
//! extractIndex() is the read-side counterpart (tests·verification): it
//! locates the sentinel, reads the non-sentinel metadata segment at the
//! same address, and returns an aligned copy of the index segment.
//!
//! Scope: this is a chaza-runtime-profile patcher, not a general wasm
//! rewriter. Inputs outside the profile are rejected up front rather than
//! silently mis-patched:
//!   - imported memory / tag imports / typed (GC) references →
//!     error.UnsupportedWasmFeature / UnsupportedMemory
//!   - already-patched modules (non-sentinel segment at slot address) →
//!     error.AlreadyPatched
//!   - sentinel absent or appears at multiple addresses →
//!     error.MetaSlotNotFound / MultipleMetaSlots

const std = @import("std");

const META_SENTINEL: u32 = 0xFEEDFACE;

/// 8-byte LE sentinel pattern: two identical 0xFEEDFACE u32s.
const sentinel_pattern: [8]u8 = blk: {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], META_SENTINEL, .little);
    std.mem.writeInt(u32, buf[4..8], META_SENTINEL, .little);
    break :blk buf;
};

const WASM_PAGE_SIZE: usize = 65536;
const WASM_MAGIC = [4]u8{ 0x00, 0x61, 0x73, 0x6D };
const WASM_VERSION = [4]u8{ 0x01, 0x00, 0x00, 0x00 };

// Section ids
const SEC_CUSTOM: u8 = 0;
const SEC_TYPE: u8 = 1;
const SEC_IMPORT: u8 = 2;
const SEC_FUNC: u8 = 3;
const SEC_TABLE: u8 = 4;
const SEC_MEMORY: u8 = 5;
const SEC_GLOBAL: u8 = 6;
const SEC_EXPORT: u8 = 7;
const SEC_START: u8 = 8;
const SEC_ELEM: u8 = 9;
const SEC_CODE: u8 = 10;
const SEC_DATA: u8 = 11;
const SEC_DATACOUNT: u8 = 12;
const SEC_TAG: u8 = 13;

// Export kinds
const KIND_MEM: u8 = 0x02;

// Opcodes / types used in const expressions
const OP_I32_CONST: u8 = 0x41;
const OP_I64_CONST: u8 = 0x42;
const OP_F32_CONST: u8 = 0x43;
const OP_F64_CONST: u8 = 0x44;
const OP_GLOBAL_GET: u8 = 0x23;
const OP_END: u8 = 0x0B;

/// Minimal valid module for tests: memory (min 1 page) + "memory" export +
/// a sentinel data segment at address 0 (the metadata slot the patcher
/// discovers and overwrites).
pub const test_minimal_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // header
    // memory section: 1 memory, flags 0, min 1
    0x05, 0x03, 0x01, 0x00, 0x01,
    // export section: "memory" mem 0
    0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
    // data section: 1 segment at addr 0, 8 bytes sentinel (0xFEEDFACE × 2 LE)
    0x0B, 0x0E, 0x01,
    0x00, // flags: active, memory 0
    0x41, 0x00, 0x0B, // i32.const 0, end
    0x08, // 8 bytes
    0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
};

pub const PatchError = error{
    InvalidWasm,
    NoMemorySection,
    UnsupportedMemory,
    UnsupportedWasmFeature,
    UnsupportedConstExpr,
    IndexTooLarge,
    AlreadyPatched,
    MetaSlotNotFound,
    MultipleMetaSlots,
    SegmentNotFound,
    OutOfMemory,
};

// ── LEB128 helpers ──

fn readLebU32(bytes: []const u8, off: *usize) PatchError!u32 {
    var result: u32 = 0;
    var shift: u6 = 0;
    while (true) {
        if (off.* >= bytes.len) return error.InvalidWasm;
        const b = bytes[off.*];
        off.* += 1;
        // u32 LEB128 is at most 5 bytes; in the 5th byte only the low 4 bits
        // carry value and continuation is forbidden.
        if (shift == 28 and b & 0xF0 != 0) return error.InvalidWasm;
        result |= @as(u32, b & 0x7F) << @intCast(shift);
        if (b & 0x80 == 0) return result;
        shift += 7;
    }
}

fn readSlebI32(bytes: []const u8, off: *usize) PatchError!i32 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (off.* >= bytes.len) return error.InvalidWasm;
        const b = bytes[off.*];
        off.* += 1;
        if (shift == 28) {
            // 5th (final) byte: continuation forbidden; payload bits above
            // bit 31 must be a proper sign extension of bit 31.
            if (b & 0x80 != 0) return error.InvalidWasm;
            const top = b & 0x78;
            if (top != 0 and top != 0x78) return error.InvalidWasm;
        }
        result |= @as(i64, b & 0x7F) << @intCast(shift);
        shift += 7;
        if (b & 0x80 == 0) {
            if (shift < 64 and b & 0x40 != 0) result |= @as(i64, -1) << @intCast(shift);
            return std.math.cast(i32, result) orelse error.InvalidWasm;
        }
    }
}

fn writeLebU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v0: u32) !void {
    var v = v0;
    while (true) {
        const b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            try list.append(allocator, b);
            return;
        }
        try list.append(allocator, b | 0x80);
    }
}

fn writeSlebI32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, v0: i32) !void {
    var v = v0;
    while (true) {
        const b: u8 = @intCast(v & 0x7F);
        v >>= 7; // arithmetic shift
        const done = (v == 0 and b & 0x40 == 0) or (v == -1 and b & 0x40 != 0);
        try list.append(allocator, if (done) b else b | 0x80);
        if (done) return;
    }
}

// ── Module parsing ──

const Section = struct {
    id: u8,
    payload: []const u8,
};

/// Binary order rank of non-custom sections. Section id is NOT the binary
/// order: datacount (12) sits between element and code, tag (13) between
/// memory and global. null = unknown non-custom section.
fn sectionRank(id: u8) ?u8 {
    return switch (id) {
        SEC_TYPE => 1,
        SEC_IMPORT => 2,
        SEC_FUNC => 3,
        SEC_TABLE => 4,
        SEC_MEMORY => 5,
        SEC_TAG => 6,
        SEC_GLOBAL => 7,
        SEC_EXPORT => 8,
        SEC_START => 9,
        SEC_ELEM => 10,
        SEC_DATACOUNT => 11,
        SEC_CODE => 12,
        SEC_DATA => 13,
        else => null,
    };
}

/// Split module bytes into raw sections. Validates the header, that every
/// non-custom section id is known, appears at most once, and that sections
/// are in spec binary order (custom sections may appear anywhere).
fn parseSections(allocator: std.mem.Allocator, bytes: []const u8) PatchError!std.ArrayList(Section) {
    if (bytes.len < 8) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[0..4], &WASM_MAGIC)) return error.InvalidWasm;
    if (!std.mem.eql(u8, bytes[4..8], &WASM_VERSION)) return error.InvalidWasm;

    var sections: std.ArrayList(Section) = .empty;
    errdefer sections.deinit(allocator);

    var seen = [_]bool{false} ** 14;
    var last_rank: u8 = 0;

    var off: usize = 8;
    while (off < bytes.len) {
        const id = bytes[off];
        off += 1;
        const size = try readLebU32(bytes, &off);
        if (size > bytes.len - off) return error.InvalidWasm;
        if (id != SEC_CUSTOM) {
            const r = sectionRank(id) orelse return error.InvalidWasm;
            if (seen[id]) return error.InvalidWasm;
            seen[id] = true;
            if (r <= last_rank) return error.InvalidWasm;
            last_rank = r;
        }
        try sections.append(allocator, .{ .id = id, .payload = bytes[off..][0..size] });
        off += size;
    }
    return sections;
}

const MemLimits = struct {
    has_max: bool,
    min: u32,
    max: u32,
};

/// Parse memory section payload — single memory32, no shared flag.
fn parseMemorySection(payload: []const u8) PatchError!MemLimits {
    var off: usize = 0;
    const count = try readLebU32(payload, &off);
    if (count != 1) return error.UnsupportedMemory;
    if (off >= payload.len) return error.InvalidWasm;
    const flags = payload[off];
    off += 1;
    if (flags > 1) return error.UnsupportedMemory; // shared (0x02+) / memory64 (0x04+)
    const min = try readLebU32(payload, &off);
    const max = if (flags == 1) try readLebU32(payload, &off) else 0;
    if (off != payload.len) return error.InvalidWasm;
    return .{ .has_max = flags == 1, .min = min, .max = max };
}

/// Consume one value type byte. Single-byte types only (numeric, v128,
/// funcref, externref) — typed references (GC proposal) are multi-byte and
/// outside the chaza runtime profile.
fn checkValType(payload: []const u8, off: *usize) PatchError!u8 {
    if (off.* >= payload.len) return error.InvalidWasm;
    const t = payload[off.*];
    off.* += 1;
    return switch (t) {
        0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F => t,
        0x63, 0x64 => error.UnsupportedWasmFeature, // (ref null? heaptype)
        else => error.InvalidWasm,
    };
}

const ImportCounts = struct {
    globals: u32 = 0,
    memories: u32 = 0,
    funcs: u32 = 0,
};

/// Count imported globals/memories/funcs (they precede defined entries in
/// their index spaces). Rejects tag imports and typed-reference tables (out
/// of profile).
fn parseImports(payload: []const u8) PatchError!ImportCounts {
    var off: usize = 0;
    var counts: ImportCounts = .{};
    const count = try readLebU32(payload, &off);
    for (0..count) |_| {
        // module name, field name
        for (0..2) |_| {
            const len = try readLebU32(payload, &off);
            if (len > payload.len - off) return error.InvalidWasm;
            off += len;
        }
        if (off >= payload.len) return error.InvalidWasm;
        const kind = payload[off];
        off += 1;
        switch (kind) {
            0x00 => {
                _ = try readLebU32(payload, &off); // func: typeidx
                counts.funcs += 1;
            },
            0x01 => { // table: reftype + limits
                const rt = try checkValType(payload, &off);
                if (rt != 0x70 and rt != 0x6F) return error.InvalidWasm;
                try skipLimits(payload, &off);
            },
            0x02 => { // memory: limits
                try skipLimits(payload, &off);
                counts.memories += 1;
            },
            0x03 => { // global: valtype + mut
                _ = try checkValType(payload, &off);
                if (off >= payload.len) return error.InvalidWasm;
                if (payload[off] > 1) return error.InvalidWasm;
                off += 1;
                counts.globals += 1;
            },
            0x04 => return error.UnsupportedWasmFeature, // tag (exception handling)
            else => return error.InvalidWasm,
        }
    }
    if (off != payload.len) return error.InvalidWasm;
    return counts;
}

fn skipLimits(payload: []const u8, off: *usize) PatchError!void {
    if (off.* >= payload.len) return error.InvalidWasm;
    const flags = payload[off.*];
    off.* += 1;
    _ = try readLebU32(payload, off);
    if (flags & 1 != 0) _ = try readLebU32(payload, off);
}

/// Consume one single-instruction constant expression (global init / data
/// segment offset): one of i32/i64/f32/f64.const or global.get, then end.
/// Returns the value for i32.const, null otherwise. Extended (multi-
/// instruction) const expressions are out of profile.
fn readSimpleConstExpr(payload: []const u8, off: *usize) PatchError!?i32 {
    if (off.* >= payload.len) return error.InvalidWasm;
    const op = payload[off.*];
    off.* += 1;
    var value: ?i32 = null;
    switch (op) {
        OP_I32_CONST => value = try readSlebI32(payload, off),
        OP_I64_CONST => {
            // skip sleb64 (up to 10 bytes)
            var n: usize = 0;
            while (true) {
                if (off.* >= payload.len or n >= 10) return error.InvalidWasm;
                const b = payload[off.*];
                off.* += 1;
                n += 1;
                if (b & 0x80 == 0) break;
            }
        },
        OP_F32_CONST => {
            if (4 > payload.len - off.*) return error.InvalidWasm;
            off.* += 4;
        },
        OP_F64_CONST => {
            if (8 > payload.len - off.*) return error.InvalidWasm;
            off.* += 8;
        },
        OP_GLOBAL_GET => _ = try readLebU32(payload, off),
        else => return error.UnsupportedConstExpr,
    }
    if (off.* >= payload.len or payload[off.*] != OP_END) return error.UnsupportedConstExpr;
    off.* += 1;
    return value;
}

// ── Sentinel scanner ──

/// Scan data segments for the 8-byte sentinel pattern. Returns the memory
/// address of the metadata slot. Errors if the pattern is absent or appears
/// at multiple addresses.
fn discoverMetaSlotAddr(sections: []const Section) PatchError!u32 {
    var found: ?u32 = null;
    for (sections) |s| {
        if (s.id != SEC_DATA) continue;
        var off: usize = 0;
        const count = try readLebU32(s.payload, &off);
        for (0..count) |_| {
            const flags = try readLebU32(s.payload, &off);
            var memidx: u32 = 0;
            var seg_offset: ?i32 = null;
            switch (flags) {
                0 => seg_offset = try readSimpleConstExpr(s.payload, &off),
                1 => {}, // passive
                2 => {
                    memidx = try readLebU32(s.payload, &off);
                    seg_offset = try readSimpleConstExpr(s.payload, &off);
                },
                else => return error.InvalidWasm,
            }
            const size = try readLebU32(s.payload, &off);
            if (size > s.payload.len - off) return error.InvalidWasm;
            const data = s.payload[off..][0..size];
            off += size;

            if (memidx != 0 or seg_offset == null) continue;
            if (seg_offset.? < 0) continue;
            const base: u32 = @intCast(seg_offset.?);

            var i: usize = 0;
            while (i + 8 <= data.len) : (i += 1) {
                if (std.mem.eql(u8, data[i..][0..8], &sentinel_pattern)) {
                    const addr = base + @as(u32, @intCast(i));
                    if (found) |prev| {
                        if (prev != addr) return error.MultipleMetaSlots;
                    } else {
                        found = addr;
                    }
                }
            }
        }
    }
    return found orelse error.MetaSlotNotFound;
}

// ── embed ──

/// Return a new wasm module with index_bytes embedded (see module doc).
/// caller free.
pub fn embed(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    index_bytes: []const u8,
) PatchError![]u8 {
    var sections = try parseSections(allocator, wasm_bytes);
    defer sections.deinit(allocator);

    // Locate memory limits and import counts
    var mem: ?MemLimits = null;
    var imports: ImportCounts = .{};
    for (sections.items) |s| {
        switch (s.id) {
            SEC_MEMORY => mem = try parseMemorySection(s.payload),
            SEC_IMPORT => imports = try parseImports(s.payload),
            else => {},
        }
    }
    // The new data segment targets memory 0; with an imported memory that
    // would be a different memory than the one whose limits we extend.
    if (imports.memories != 0) return error.UnsupportedMemory;
    const limits = mem orelse return error.NoMemorySection;

    // Discover the metadata slot address from chaza_index_meta
    const meta_slot_addr = try discoverMetaSlotAddr(sections.items);

    // Index region: starts at the old memory end (page-aligned)
    const index_ptr_u: u64 = @as(u64, limits.min) * WASM_PAGE_SIZE;
    const extra_pages: u64 = (@as(u64, index_bytes.len) + WASM_PAGE_SIZE - 1) / WASM_PAGE_SIZE;
    const new_min: u64 = limits.min + extra_pages;
    if (index_ptr_u + index_bytes.len > std.math.maxInt(i32)) return error.IndexTooLarge;
    if (new_min > std.math.maxInt(u32)) return error.IndexTooLarge;
    const index_ptr: i32 = @intCast(index_ptr_u);
    const index_len: i32 = @intCast(index_bytes.len);

    // Metadata payload: [index_ptr LE u32][index_len LE u32] = 8 bytes
    var meta_data: [8]u8 = undefined;
    std.mem.writeInt(u32, meta_data[0..4], @intCast(index_ptr), .little);
    std.mem.writeInt(u32, meta_data[4..8], @intCast(index_len), .little);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &WASM_MAGIC);
    try out.appendSlice(allocator, &WASM_VERSION);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);

    var data_done = false;

    for (sections.items) |s| {
        switch (s.id) {
            SEC_MEMORY => {
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, 1);
                try scratch.append(allocator, if (limits.has_max) 1 else 0);
                try writeLebU32(&scratch, allocator, @intCast(new_min));
                if (limits.has_max) {
                    try writeLebU32(&scratch, allocator, @intCast(@max(@as(u64, limits.max), new_min)));
                }
                try emitSection(allocator, &out, SEC_MEMORY, scratch.items);
            },
            SEC_DATACOUNT => {
                var off: usize = 0;
                const count = try readLebU32(s.payload, &off);
                if (off != s.payload.len) return error.InvalidWasm;
                const new_count = std.math.add(u32, count, 2) catch return error.InvalidWasm;
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, new_count);
                try emitSection(allocator, &out, SEC_DATACOUNT, scratch.items);
            },
            SEC_DATA => {
                var off: usize = 0;
                const count = try readLebU32(s.payload, &off);
                // Reject already-patched modules: a segment already targeting
                // the metadata slot address means embed() ran before.
                try checkAlreadyPatched(s.payload, off, count, meta_slot_addr);
                const new_count = std.math.add(u32, count, 2) catch return error.InvalidWasm;
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, new_count);
                try scratch.appendSlice(allocator, s.payload[off..]);
                // metadata segment (8 bytes at the metadata slot address)
                try appendActiveSegment(&scratch, allocator, @intCast(meta_slot_addr), &meta_data);
                // index segment (index bytes at the old memory end)
                try appendActiveSegment(&scratch, allocator, index_ptr, index_bytes);
                try emitSection(allocator, &out, SEC_DATA, scratch.items);
                data_done = true;
            },
            else => try emitSection(allocator, &out, s.id, s.payload),
        }
    }

    // No data section in the original module → create one from scratch
    if (!data_done) {
        scratch.clearRetainingCapacity();
        try writeLebU32(&scratch, allocator, 2);
        try appendActiveSegment(&scratch, allocator, @intCast(meta_slot_addr), &meta_data);
        try appendActiveSegment(&scratch, allocator, index_ptr, index_bytes);
        try emitSection(allocator, &out, SEC_DATA, scratch.items);
    }

    return out.toOwnedSlice(allocator);
}

/// Scan existing data segments for a non-sentinel 8-byte segment at the
/// metadata slot address → already patched.
fn checkAlreadyPatched(
    data_payload: []const u8,
    initial_off: usize,
    count: u32,
    meta_slot_addr: u32,
) PatchError!void {
    var off = initial_off;
    _ = count;
    while (off < data_payload.len) {
        const flags = try readLebU32(data_payload, &off);
        var memidx: u32 = 0;
        var seg_offset: ?i32 = null;
        switch (flags) {
            0 => seg_offset = try readSimpleConstExpr(data_payload, &off),
            1 => {}, // passive
            2 => {
                memidx = try readLebU32(data_payload, &off);
                seg_offset = try readSimpleConstExpr(data_payload, &off);
            },
            else => return error.InvalidWasm,
        }
        const size = try readLebU32(data_payload, &off);
        if (size > data_payload.len - off) return error.InvalidWasm;
        const bytes = data_payload[off..][0..size];
        off += size;
        if (memidx == 0 and size == 8) {
            if (seg_offset) |so| if (so >= 0 and @as(u32, @intCast(so)) == meta_slot_addr) {
                if (!std.mem.eql(u8, bytes, &sentinel_pattern)) return error.AlreadyPatched;
            };
        }
    }
}

fn emitSection(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: u8, payload: []const u8) !void {
    try out.append(allocator, id);
    try writeLebU32(out, allocator, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
}

/// Active data segment (memory 0) at the given offset.
fn appendActiveSegment(list: *std.ArrayList(u8), allocator: std.mem.Allocator, offset: i32, data: []const u8) !void {
    try list.append(allocator, 0x00); // flags: active, memory 0
    try list.append(allocator, OP_I32_CONST);
    try writeSlebI32(list, allocator, offset);
    try list.append(allocator, OP_END);
    try writeLebU32(list, allocator, @intCast(data.len));
    try list.appendSlice(allocator, data);
}

// ── extract ──

pub const IndexLocation = struct {
    ptr: u32,
    len: u32,
};

/// Read the metadata segment from the data section and return the embedded
/// index (ptr, len). The metadata slot address is discovered by scanning
/// for the sentinel pattern; the real values come from the non-sentinel
/// segment at the same address.
pub fn indexLocation(wasm_bytes: []const u8) PatchError!IndexLocation {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sections = try parseSections(a, wasm_bytes);
    defer sections.deinit(a);

    const meta_slot_addr = try discoverMetaSlotAddr(sections.items);

    for (sections.items) |s| {
        if (s.id != SEC_DATA) continue;
        var off: usize = 0;
        const count = try readLebU32(s.payload, &off);
        for (0..count) |_| {
            const flags = try readLebU32(s.payload, &off);
            var memidx: u32 = 0;
            var seg_offset: ?i32 = null;
            switch (flags) {
                0 => seg_offset = try readSimpleConstExpr(s.payload, &off),
                1 => {}, // passive
                2 => {
                    memidx = try readLebU32(s.payload, &off);
                    seg_offset = try readSimpleConstExpr(s.payload, &off);
                },
                else => return error.InvalidWasm,
            }
            const size = try readLebU32(s.payload, &off);
            if (size > s.payload.len - off) return error.InvalidWasm;
            const bytes = s.payload[off..][0..size];
            off += size;
            // The metadata segment: 8 bytes at the slot address, NOT the sentinel
            if (memidx == 0 and size == 8) {
                if (seg_offset) |so| if (so >= 0 and @as(u32, @intCast(so)) == meta_slot_addr) {
                    if (!std.mem.eql(u8, bytes, &sentinel_pattern)) {
                        const ptr = std.mem.readInt(u32, bytes[0..4], .little);
                        const len = std.mem.readInt(u32, bytes[4..8], .little);
                        return .{ .ptr = ptr, .len = len };
                    }
                };
            }
        }
    }
    return error.SegmentNotFound;
}

/// Return a copy of the embedded index bytes, 4-byte aligned so it can be
/// handed straight to reader.IndexView.open. caller free.
pub fn extractIndex(allocator: std.mem.Allocator, wasm_bytes: []const u8) PatchError![]align(4) u8 {
    const loc = try indexLocation(wasm_bytes);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sections = try parseSections(a, wasm_bytes);
    defer sections.deinit(a);

    for (sections.items) |s| {
        if (s.id != SEC_DATA) continue;
        var off: usize = 0;
        const count = try readLebU32(s.payload, &off);
        for (0..count) |_| {
            const flags = try readLebU32(s.payload, &off);
            var memidx: u32 = 0;
            var seg_offset: ?i32 = null;
            switch (flags) {
                0 => seg_offset = try readSimpleConstExpr(s.payload, &off),
                1 => {}, // passive
                2 => {
                    memidx = try readLebU32(s.payload, &off);
                    seg_offset = try readSimpleConstExpr(s.payload, &off);
                },
                else => return error.InvalidWasm,
            }
            const size = try readLebU32(s.payload, &off);
            if (size > s.payload.len - off) return error.InvalidWasm;
            const bytes = s.payload[off..][0..size];
            off += size;
            if (memidx != 0) continue; // chaza segment always targets memory 0
            if (seg_offset) |so| {
                if (so >= 0 and @as(u32, @intCast(so)) == loc.ptr and size == loc.len) {
                    const out = try allocator.alignedAlloc(u8, .of(u32), bytes.len);
                    @memcpy(out, bytes);
                    return out;
                }
            }
        }
    }
    return error.SegmentNotFound;
}

// ── Assertion tests ────────────────────────────────────────────────────

test "embed + extract roundtrip on minimal module" {
    const allocator = std.testing.allocator;
    const index = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const patched = try embed(allocator, &test_minimal_wasm, &index);
    defer allocator.free(patched);

    // Output is a wasm module
    try std.testing.expectEqualSlices(u8, &WASM_MAGIC, patched[0..4]);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, WASM_PAGE_SIZE), loc.ptr); // min was 1 page
    try std.testing.expectEqual(@as(u32, index.len), loc.len);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &index, extracted);
}

test "embed: memory min extended to cover the index" {
    const allocator = std.testing.allocator;
    // Index bigger than one page → min 1 → 1 + 2 = 3 pages
    const index = try allocator.alloc(u8, WASM_PAGE_SIZE + 100);
    defer allocator.free(index);
    for (index, 0..) |*b, i| b.* = @intCast(i % 251);

    const patched = try embed(allocator, &test_minimal_wasm, index);
    defer allocator.free(patched);

    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    var checked = false;
    for (sections.items) |s| {
        if (s.id == SEC_MEMORY) {
            const limits = try parseMemorySection(s.payload);
            try std.testing.expectEqual(@as(u32, 3), limits.min);
            checked = true;
        }
    }
    try std.testing.expect(checked);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, index, extracted);
}

test "embed on module with existing data/datacount sections" {
    const allocator = std.testing.allocator;
    // Module: memory + "memory" export + datacount(1) + sentinel at addr 0 +
    // existing data segment at addr 1024. The metadata slot is at address 0
    // (sentinel); the existing segment at 1024 must not collide.
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // memory section: min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export section: "memory" mem 0
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
        // datacount: 2 (matching the 2 data segments below)
        0x0C, 0x01, 0x02,
        // data: 2 segments
        0x0B, 0x17, 0x02,
        // segment 0: sentinel at addr 0 (8 bytes)
        0x00, // flags: active, memory 0
        0x41, 0x00, 0x0B, // i32.const 0, end
        0x08, // 8 bytes
        0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
        // segment 1: existing data at addr 1024 (3 bytes)
        0x00,
        0x41, 0x80, 0x08, 0x0B, // i32.const 1024, end
        0x03, // 3 bytes
        0xAA, 0xBB, 0xCC,
    };

    const index = [_]u8{ 9, 8, 7, 6 };
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, WASM_PAGE_SIZE), loc.ptr);
    try std.testing.expectEqual(@as(u32, 4), loc.len);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &index, extracted);

    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    for (sections.items) |s| {
        switch (s.id) {
            SEC_MEMORY => {
                const limits = try parseMemorySection(s.payload);
                try std.testing.expectEqual(@as(u32, 2), limits.min);
            },
            SEC_DATACOUNT => {
                var off: usize = 0;
                try std.testing.expectEqual(@as(u32, 4), try readLebU32(s.payload, &off));
            },
            SEC_DATA => {
                var off: usize = 0;
                try std.testing.expectEqual(@as(u32, 4), try readLebU32(s.payload, &off));
            },
            else => {},
        }
    }
}

test "embed: section order preserved (rank strictly increasing)" {
    const allocator = std.testing.allocator;
    const index = [_]u8{ 1, 2, 3 };
    const patched = try embed(allocator, &test_minimal_wasm, &index);
    defer allocator.free(patched);

    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    var last_rank: u8 = 0;
    for (sections.items) |s| {
        if (s.id == SEC_CUSTOM) continue;
        const r = sectionRank(s.id).?;
        try std.testing.expect(r > last_rank);
        last_rank = r;
    }
}

test "embed: no global or export sections added" {
    const allocator = std.testing.allocator;
    const index = [_]u8{ 1, 2, 3, 4 };
    const patched = try embed(allocator, &test_minimal_wasm, &index);
    defer allocator.free(patched);

    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    for (sections.items) |s| {
        // The patcher must not add global or export sections
        try std.testing.expect(s.id != SEC_GLOBAL);
    }
    // Export section count is unchanged from the input (1 export: "memory")
    for (sections.items) |s| {
        if (s.id == SEC_EXPORT) {
            var off: usize = 0;
            try std.testing.expectEqual(@as(u32, 1), try readLebU32(s.payload, &off));
        }
    }
}

test "embed: imported globals do not affect patching (no global logic)" {
    const allocator = std.testing.allocator;
    // import 1 global ("e"."g" i32 const) + memory + export + sentinel.
    // The patcher doesn't touch globals at all — the sentinel scan is
    // independent of the global index space.
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1 global, module "e", field "g", i32 const
        0x02, 0x08, 0x01, 0x01, 'e', 0x01, 'g', 0x03, 0x7F, 0x00,
        // memory: min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export: "memory" mem 0
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
        // data: sentinel at addr 512
        0x0B, 0x0F, 0x01,
        0x00, // flags: active, memory 0
        0x41, 0x80, 0x04, 0x0B, // i32.const 512, end
        0x08, // 8 bytes
        0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
    };
    const index = [_]u8{ 5, 6, 7, 8 };
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, WASM_PAGE_SIZE), loc.ptr);
    try std.testing.expectEqual(@as(u32, 4), loc.len);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &index, extracted);
}

test "embed: imported memory rejected (would extend the wrong memory)" {
    const allocator = std.testing.allocator;
    const index = [_]u8{1};

    // imported memory only — no defined memory section
    const imported_only = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1 entry, module "e", field "m", memory flags 0 min 1
        0x02, 0x08, 0x01, 0x01, 'e', 0x01, 'm', 0x02,
        0x00, 0x01,
    };
    try std.testing.expectError(error.UnsupportedMemory, embed(allocator, &imported_only, &index));
}

test "embed: already patched module rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{ 1, 2, 3 };
    const once = try embed(allocator, &test_minimal_wasm, &index);
    defer allocator.free(once);

    try std.testing.expectError(error.AlreadyPatched, embed(allocator, once, &index));
}

test "embed: missing sentinel rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{1};

    // memory + "memory" export + data segment WITHOUT sentinel
    const no_sentinel = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
        // data: 4 bytes at addr 0 (NOT the sentinel)
        0x0B, 0x0A, 0x01,
        0x00, 0x41, 0x00, 0x0B, 0x04, 0x01, 0x02, 0x03, 0x04,
    };
    try std.testing.expectError(error.MetaSlotNotFound, embed(allocator, &no_sentinel, &index));
}

test "embed: multiple sentinels at different addresses rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{1};

    const dup_sentinel = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
        // data: 2 segments, sentinel at addr 0 AND addr 16
        0x0B, 0x1B, 0x02,
        // segment 0: sentinel at 0
        0x00, 0x41, 0x00, 0x0B, 0x08,
        0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
        // segment 1: sentinel at 16
        0x00, 0x41, 0x10, 0x0B, 0x08,
        0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
    };
    try std.testing.expectError(error.MultipleMetaSlots, embed(allocator, &dup_sentinel, &index));
}

test "embed: invalid input rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{1};

    // not wasm
    try std.testing.expectError(error.InvalidWasm, embed(allocator, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &index));
    // empty
    try std.testing.expectError(error.InvalidWasm, embed(allocator, &.{}, &index));
    // valid header but no memory section
    const no_mem = [_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 };
    try std.testing.expectError(error.NoMemorySection, embed(allocator, &no_mem, &index));
}

test "parseSections: duplicate / misordered / unknown sections rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{1};

    // two memory sections
    const dup_memory = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.InvalidWasm, embed(allocator, &dup_memory, &index));

    // unknown non-custom section id 14
    const unknown = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x0E, 0x01, 0x00,
    };
    try std.testing.expectError(error.InvalidWasm, embed(allocator, &unknown, &index));

    // section size larger than remaining bytes
    const truncated = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x7F, 0x01,
    };
    try std.testing.expectError(error.InvalidWasm, embed(allocator, &truncated, &index));
}

test "extract: module without sentinel rejected" {
    const no_sentinel = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
    };
    try std.testing.expectError(error.MetaSlotNotFound, extractIndex(std.testing.allocator, &no_sentinel));
}

test "embed: empty index still valid (0-byte segment, 0 extra pages)" {
    const allocator = std.testing.allocator;
    const patched = try embed(allocator, &test_minimal_wasm, &.{});
    defer allocator.free(patched);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, WASM_PAGE_SIZE), loc.ptr);
    try std.testing.expectEqual(@as(u32, 0), loc.len);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqual(@as(usize, 0), extracted.len);
}

test "readLebU32: malformed encodings rejected" {
    // 5th byte with unused high bits set (value needs 35 bits)
    {
        var off: usize = 0;
        const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x7F };
        try std.testing.expectError(error.InvalidWasm, readLebU32(&bytes, &off));
    }
    // 6-byte encoding (continuation on the 5th byte)
    {
        var off: usize = 0;
        const bytes = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
        try std.testing.expectError(error.InvalidWasm, readLebU32(&bytes, &off));
    }
    // truncated (continuation with no next byte)
    {
        var off: usize = 0;
        const bytes = [_]u8{0x80};
        try std.testing.expectError(error.InvalidWasm, readLebU32(&bytes, &off));
    }
    // max valid u32 still accepted
    {
        var off: usize = 0;
        const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F };
        try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try readLebU32(&bytes, &off));
    }
}

test "readSlebI32: malformed encodings rejected" {
    // 6-byte encoding
    {
        var off: usize = 0;
        const bytes = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
        try std.testing.expectError(error.InvalidWasm, readSlebI32(&bytes, &off));
    }
    // 5th byte with non-sign-extension upper bits
    {
        var off: usize = 0;
        const bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x27 };
        try std.testing.expectError(error.InvalidWasm, readSlebI32(&bytes, &off));
    }
    // minInt/maxInt i32 still accepted
    {
        var off: usize = 0;
        const min_bytes = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x78 };
        try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), try readSlebI32(&min_bytes, &off));
    }
    {
        var off: usize = 0;
        const max_bytes = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x07 };
        try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), try readSlebI32(&max_bytes, &off));
    }
}

test "sleb32 encode/decode roundtrip" {
    const allocator = std.testing.allocator;
    const values = [_]i32{ 0, 1, 63, 64, 127, 128, 65536, 123456789, std.math.maxInt(i32), -1, -64, -65, -123456, std.math.minInt(i32) };
    for (values) |v| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try writeSlebI32(&buf, allocator, v);
        var off: usize = 0;
        try std.testing.expectEqual(v, try readSlebI32(buf.items, &off));
        try std.testing.expectEqual(buf.items.len, off);
    }
}

// ── parseImports: import kind branches ──

test "parseImports: func import (kind 0x00) counted" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1, module "e", field "f", func, typeidx 0
        0x02, 0x07, 0x01, 0x01, 'e', 0x01, 'f', 0x00, 0x00,
        // memory: min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export "memory"
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
        // data: sentinel at addr 0
        0x0B, 0x0E, 0x01,
        0x00, 0x41, 0x00, 0x0B, 0x08,
        0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
    };
    const index = [_]u8{ 5, 6, 7 };
    const allocator = std.testing.allocator;
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, WASM_PAGE_SIZE), loc.ptr);
    try std.testing.expectEqual(@as(u32, 3), loc.len);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &index, extracted);
}

test "parseImports: table import (kind 0x01)" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1, module "e", field "t", table, funcref, limits 0/0
        0x02, 0x09, 0x01, 0x01, 'e', 0x01, 't', 0x01, 0x70, 0x00, 0x00,
        // memory: min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export "memory"
        0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00,
        // data: sentinel at addr 0
        0x0B, 0x0E, 0x01,
        0x00, 0x41, 0x00, 0x0B, 0x08,
        0xCE, 0xFA, 0xED, 0xFE, 0xCE, 0xFA, 0xED, 0xFE,
    };
    const index = [_]u8{ 8, 9 };
    const allocator = std.testing.allocator;
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, WASM_PAGE_SIZE), loc.ptr);
    try std.testing.expectEqual(@as(u32, 2), loc.len);
}

test "parseImports: tag import (kind 0x04) rejected" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1, module "e", field "x", tag
        0x02, 0x06, 0x01, 0x01, 'e', 0x01, 'x', 0x04,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    const index = [_]u8{1};
    try std.testing.expectError(error.UnsupportedWasmFeature, embed(std.testing.allocator, &module, &index));
}

test "parseImports: invalid import kind rejected" {
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1, module "e", field "x", kind 0x05 (invalid)
        0x02, 0x06, 0x01, 0x01, 'e', 0x01, 'x', 0x05,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    const index = [_]u8{1};
    try std.testing.expectError(error.InvalidWasm, embed(std.testing.allocator, &module, &index));
}
