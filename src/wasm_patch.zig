//! chaza wasm patcher — embeds index bytes directly into the runtime wasm
//! binary as an active data segment.
//!
//! embed() rewrites the module:
//!   1. Memory section: min pages extended so the index region [old_end,
//!      old_end + index_len) is inside initial memory (index sits at the old
//!      memory end, page-aligned).
//!   2. Global section: two immutable i32 globals appended holding the index
//!      address and length.
//!   3. Export section: the globals exported as "chaza_index_ptr" /
//!      "chaza_index_len".
//!   4. Data section: one active segment (memory 0, i32.const index_ptr)
//!      carrying the index bytes.
//!   5. Data count section (if present): count incremented.
//!
//! The output is a self-contained valid .wasm file: the JS loader
//! instantiates it, reads the two exported globals, and calls
//! set_index(ptr, len) — no alloc/copy of the index at load time.
//!
//! extractIndex() is the read-side counterpart (tests·verification): it
//! locates the exported globals and returns an aligned copy of the matching
//! data segment payload.
//!
//! Scope: this is a chaza-runtime-profile patcher, not a general wasm
//! rewriter. Inputs outside the profile are rejected up front rather than
//! silently mis-patched:
//!   - imported memory / tag imports / typed (GC) references →
//!     error.UnsupportedWasmFeature / UnsupportedMemory
//!   - already-patched modules or export-name collisions →
//!     error.AlreadyPatched / ExportNameConflict (wasm export names must be
//!     unique; re-embedding would emit invalid wasm)
//!   - const expressions are single-instruction only (i32/i64/f32/f64.const,
//!     global.get) — extended const expressions are out of profile

const std = @import("std");

pub const PTR_EXPORT_NAME = "chaza_index_ptr";
pub const LEN_EXPORT_NAME = "chaza_index_len";

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
const KIND_GLOBAL: u8 = 0x03;

// Opcodes / types used in const expressions
const OP_I32_CONST: u8 = 0x41;
const OP_I64_CONST: u8 = 0x42;
const OP_F32_CONST: u8 = 0x43;
const OP_F64_CONST: u8 = 0x44;
const OP_GLOBAL_GET: u8 = 0x23;
const OP_END: u8 = 0x0B;
const VALTYPE_I32: u8 = 0x7F;

/// Minimal valid module for tests: memory (min 1 page) + "memory" export.
pub const test_minimal_wasm = [_]u8{
    0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, // header
    0x05, 0x03, 0x01, 0x00, 0x01, // memory section: 1 memory, flags 0, min 1
    0x07, 0x0A, 0x01, 0x06, 'm', 'e', 'm', 'o', 'r', 'y', 0x02, 0x00, // export "memory"
};

pub const PatchError = error{
    InvalidWasm,
    NoMemorySection,
    UnsupportedMemory,
    UnsupportedWasmFeature,
    UnsupportedConstExpr,
    IndexTooLarge,
    AlreadyPatched,
    ExportNameConflict,
    MissingChazaExports,
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
};

/// Count imported globals/memories (they precede defined entries in their
/// index spaces). Rejects tag imports and typed-reference tables (out of
/// profile).
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
            0x00 => _ = try readLebU32(payload, &off), // func: typeidx
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

/// What the export section already says about the two chaza export names.
const ExportScan = struct {
    ptr_found: bool = false,
    ptr_kind: u8 = 0,
    ptr_idx: u32 = 0,
    len_found: bool = false,
    len_kind: u8 = 0,
    len_idx: u32 = 0,
};

fn scanExports(payload: []const u8) PatchError!ExportScan {
    var scan: ExportScan = .{};
    var off: usize = 0;
    const count = try readLebU32(payload, &off);
    for (0..count) |_| {
        const name_len = try readLebU32(payload, &off);
        if (name_len > payload.len - off) return error.InvalidWasm;
        const name = payload[off..][0..name_len];
        off += name_len;
        if (off >= payload.len) return error.InvalidWasm;
        const kind = payload[off];
        off += 1;
        const idx = try readLebU32(payload, &off);
        if (std.mem.eql(u8, name, PTR_EXPORT_NAME)) {
            scan.ptr_found = true;
            scan.ptr_kind = kind;
            scan.ptr_idx = idx;
        } else if (std.mem.eql(u8, name, LEN_EXPORT_NAME)) {
            scan.len_found = true;
            scan.len_kind = kind;
            scan.len_idx = idx;
        }
    }
    if (off != payload.len) return error.InvalidWasm;
    return scan;
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

    // Locate memory limits, import counts, defined globals, existing exports
    var mem: ?MemLimits = null;
    var imports: ImportCounts = .{};
    var defined_globals: u32 = 0;
    for (sections.items) |s| {
        switch (s.id) {
            SEC_MEMORY => mem = try parseMemorySection(s.payload),
            SEC_IMPORT => imports = try parseImports(s.payload),
            SEC_GLOBAL => {
                var off: usize = 0;
                defined_globals = try readLebU32(s.payload, &off);
            },
            SEC_EXPORT => {
                // Wasm export names must be unique — refuse rather than emit
                // an invalid module. Both names present = already patched.
                const scan = try scanExports(s.payload);
                if (scan.ptr_found and scan.len_found) return error.AlreadyPatched;
                if (scan.ptr_found or scan.len_found) return error.ExportNameConflict;
            },
            else => {},
        }
    }
    // The new data segment targets memory 0; with an imported memory that
    // would be a different memory than the one whose limits we extend.
    if (imports.memories != 0) return error.UnsupportedMemory;
    const limits = mem orelse return error.NoMemorySection;

    // Index region: starts at the old memory end (page-aligned)
    const index_ptr_u: u64 = @as(u64, limits.min) * WASM_PAGE_SIZE;
    const extra_pages: u64 = (@as(u64, index_bytes.len) + WASM_PAGE_SIZE - 1) / WASM_PAGE_SIZE;
    const new_min: u64 = limits.min + extra_pages;
    if (index_ptr_u + index_bytes.len > std.math.maxInt(i32)) return error.IndexTooLarge;
    if (new_min > std.math.maxInt(u32)) return error.IndexTooLarge;
    const index_ptr: i32 = @intCast(index_ptr_u);
    const index_len: i32 = @intCast(index_bytes.len);

    const ptr_global_idx = std.math.add(u32, imports.globals, defined_globals) catch return error.InvalidWasm;
    const len_global_idx = std.math.add(u32, ptr_global_idx, 1) catch return error.InvalidWasm;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &WASM_MAGIC);
    try out.appendSlice(allocator, &WASM_VERSION);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(allocator);

    const rank_global = sectionRank(SEC_GLOBAL).?;
    const rank_export = sectionRank(SEC_EXPORT).?;

    var global_done = false;
    var export_done = false;
    var data_done = false;

    for (sections.items) |s| {
        if (s.id != SEC_CUSTOM) {
            const r = sectionRank(s.id).?; // validated in parseSections
            // Insert missing sections at their spec-mandated position
            if (!global_done and s.id != SEC_GLOBAL and r > rank_global) {
                try emitNewGlobalSection(allocator, &out, &scratch, index_ptr, index_len);
                global_done = true;
            }
            if (!export_done and s.id != SEC_EXPORT and r > rank_export) {
                try emitNewExportSection(allocator, &out, &scratch, ptr_global_idx, len_global_idx);
                export_done = true;
            }
        }
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
            SEC_GLOBAL => {
                var off: usize = 0;
                const count = try readLebU32(s.payload, &off);
                const new_count = std.math.add(u32, count, 2) catch return error.InvalidWasm;
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, new_count);
                try scratch.appendSlice(allocator, s.payload[off..]);
                try appendI32Global(&scratch, allocator, index_ptr);
                try appendI32Global(&scratch, allocator, index_len);
                try emitSection(allocator, &out, SEC_GLOBAL, scratch.items);
                global_done = true;
            },
            SEC_EXPORT => {
                var off: usize = 0;
                const count = try readLebU32(s.payload, &off);
                const new_count = std.math.add(u32, count, 2) catch return error.InvalidWasm;
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, new_count);
                try scratch.appendSlice(allocator, s.payload[off..]);
                try appendGlobalExport(&scratch, allocator, PTR_EXPORT_NAME, ptr_global_idx);
                try appendGlobalExport(&scratch, allocator, LEN_EXPORT_NAME, len_global_idx);
                try emitSection(allocator, &out, SEC_EXPORT, scratch.items);
                export_done = true;
            },
            SEC_DATACOUNT => {
                var off: usize = 0;
                const count = try readLebU32(s.payload, &off);
                if (off != s.payload.len) return error.InvalidWasm;
                const new_count = std.math.add(u32, count, 1) catch return error.InvalidWasm;
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, new_count);
                try emitSection(allocator, &out, SEC_DATACOUNT, scratch.items);
            },
            SEC_DATA => {
                var off: usize = 0;
                const count = try readLebU32(s.payload, &off);
                const new_count = std.math.add(u32, count, 1) catch return error.InvalidWasm;
                scratch.clearRetainingCapacity();
                try writeLebU32(&scratch, allocator, new_count);
                try scratch.appendSlice(allocator, s.payload[off..]);
                try appendIndexSegment(&scratch, allocator, index_ptr, index_bytes);
                try emitSection(allocator, &out, SEC_DATA, scratch.items);
                data_done = true;
            },
            else => try emitSection(allocator, &out, s.id, s.payload),
        }
    }

    // Sections absent from the module → append at the end (relative order
    // global < export < data is preserved by this emission order).
    if (!global_done) try emitNewGlobalSection(allocator, &out, &scratch, index_ptr, index_len);
    if (!export_done) try emitNewExportSection(allocator, &out, &scratch, ptr_global_idx, len_global_idx);
    if (!data_done) {
        scratch.clearRetainingCapacity();
        try writeLebU32(&scratch, allocator, 1);
        try appendIndexSegment(&scratch, allocator, index_ptr, index_bytes);
        try emitSection(allocator, &out, SEC_DATA, scratch.items);
    }

    return out.toOwnedSlice(allocator);
}

fn emitSection(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id: u8, payload: []const u8) !void {
    try out.append(allocator, id);
    try writeLebU32(out, allocator, @intCast(payload.len));
    try out.appendSlice(allocator, payload);
}

/// Immutable i32 global with an i32.const init.
fn appendI32Global(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    try list.append(allocator, VALTYPE_I32);
    try list.append(allocator, 0x00); // const
    try list.append(allocator, OP_I32_CONST);
    try writeSlebI32(list, allocator, value);
    try list.append(allocator, OP_END);
}

fn appendGlobalExport(list: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, idx: u32) !void {
    try writeLebU32(list, allocator, @intCast(name.len));
    try list.appendSlice(allocator, name);
    try list.append(allocator, KIND_GLOBAL);
    try writeLebU32(list, allocator, idx);
}

/// Active data segment (memory 0) at offset index_ptr.
fn appendIndexSegment(list: *std.ArrayList(u8), allocator: std.mem.Allocator, index_ptr: i32, index_bytes: []const u8) !void {
    try list.append(allocator, 0x00); // flags: active, memory 0
    try list.append(allocator, OP_I32_CONST);
    try writeSlebI32(list, allocator, index_ptr);
    try list.append(allocator, OP_END);
    try writeLebU32(list, allocator, @intCast(index_bytes.len));
    try list.appendSlice(allocator, index_bytes);
}

fn emitNewGlobalSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: *std.ArrayList(u8),
    index_ptr: i32,
    index_len: i32,
) !void {
    scratch.clearRetainingCapacity();
    try writeLebU32(scratch, allocator, 2);
    try appendI32Global(scratch, allocator, index_ptr);
    try appendI32Global(scratch, allocator, index_len);
    try emitSection(allocator, out, SEC_GLOBAL, scratch.items);
}

fn emitNewExportSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    scratch: *std.ArrayList(u8),
    ptr_idx: u32,
    len_idx: u32,
) !void {
    scratch.clearRetainingCapacity();
    try writeLebU32(scratch, allocator, 2);
    try appendGlobalExport(scratch, allocator, PTR_EXPORT_NAME, ptr_idx);
    try appendGlobalExport(scratch, allocator, LEN_EXPORT_NAME, len_idx);
    try emitSection(allocator, out, SEC_EXPORT, scratch.items);
}

// ── extract ──

pub const IndexLocation = struct {
    ptr: u32,
    len: u32,
};

/// Read the chaza_index_ptr / chaza_index_len exported global values.
/// The exports must be immutable i32 globals with i32.const initializers.
pub fn indexLocation(wasm_bytes: []const u8) PatchError!IndexLocation {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var sections = try parseSections(a, wasm_bytes);
    defer sections.deinit(a);

    var import_payload: ?[]const u8 = null;
    var global_payload: ?[]const u8 = null;
    var export_payload: ?[]const u8 = null;
    for (sections.items) |s| {
        switch (s.id) {
            SEC_IMPORT => import_payload = s.payload,
            SEC_GLOBAL => global_payload = s.payload,
            SEC_EXPORT => export_payload = s.payload,
            else => {},
        }
    }

    const scan = try scanExports(export_payload orelse return error.MissingChazaExports);
    if (!scan.ptr_found or !scan.len_found) return error.MissingChazaExports;
    if (scan.ptr_kind != KIND_GLOBAL or scan.len_kind != KIND_GLOBAL) return error.MissingChazaExports;
    const pg = scan.ptr_idx;
    const lg = scan.len_idx;

    const imported = if (import_payload) |p| (try parseImports(p)).globals else 0;
    if (pg < imported or lg < imported) return error.MissingChazaExports;

    // Walk defined globals to the wanted indices
    const payload = global_payload orelse return error.MissingChazaExports;
    var off: usize = 0;
    const count = try readLebU32(payload, &off);
    var ptr_val: ?i32 = null;
    var len_val: ?i32 = null;
    for (0..count) |i| {
        const valtype = try checkValType(payload, &off);
        if (off >= payload.len) return error.InvalidWasm;
        const mutability = payload[off];
        off += 1;
        if (mutability > 1) return error.InvalidWasm;
        const value = try readSimpleConstExpr(payload, &off);
        const gidx = imported + @as(u32, @intCast(i));
        if (gidx == pg or gidx == lg) {
            // Chaza index globals must be immutable i32 constants
            if (valtype != VALTYPE_I32 or mutability != 0) return error.MissingChazaExports;
            const v = value orelse return error.UnsupportedConstExpr;
            if (gidx == pg) ptr_val = v;
            if (gidx == lg) len_val = v;
        }
    }
    const p = ptr_val orelse return error.MissingChazaExports;
    const l = len_val orelse return error.MissingChazaExports;
    if (p < 0 or l < 0) return error.InvalidWasm;
    return .{ .ptr = @intCast(p), .len = @intCast(l) };
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

test "embed on module with existing global/export/data/datacount sections" {
    const allocator = std.testing.allocator;
    // Synthetic module: memory(min 2, max 2) + 1 mutable global + export
    // "memory" + datacount(1) + data(1 active segment at 0)
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // memory: 1 memory, flags 1 (max), min 2, max 2
        0x05, 0x04, 0x01, 0x01, 0x02, 0x02,
        // global: 1 global, i32 mut, i32.const 42
        0x06, 0x06, 0x01, 0x7F, 0x01, 0x41, 0x2A, 0x0B,
        // export: "memory" mem 0
        0x07, 0x0A, 0x01, 0x06, 'm',  'e',  'm',  'o',
        'r',  'y',  0x02, 0x00,
        // datacount: 1
        0x0C, 0x01, 0x01,
        // data: 1 segment, active, i32.const 0, 3 bytes
        0x0B, 0x09, 0x01, 0x00, 0x41, 0x00, 0x0B, 0x03,
        0xAA, 0xBB, 0xCC,
    };
    const index = [_]u8{ 9, 8, 7, 6 };
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    const loc = try indexLocation(patched);
    try std.testing.expectEqual(@as(u32, 2 * WASM_PAGE_SIZE), loc.ptr);
    try std.testing.expectEqual(@as(u32, 4), loc.len);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &index, extracted);

    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    for (sections.items) |s| {
        switch (s.id) {
            SEC_MEMORY => {
                // min 2 + 1 page for the index; max raised alongside
                const limits = try parseMemorySection(s.payload);
                try std.testing.expectEqual(@as(u32, 3), limits.min);
                try std.testing.expect(limits.has_max);
                try std.testing.expectEqual(@as(u32, 3), limits.max);
            },
            SEC_GLOBAL => {
                var off: usize = 0;
                try std.testing.expectEqual(@as(u32, 3), try readLebU32(s.payload, &off));
            },
            SEC_EXPORT => {
                var off: usize = 0;
                try std.testing.expectEqual(@as(u32, 3), try readLebU32(s.payload, &off));
            },
            SEC_DATACOUNT => {
                var off: usize = 0;
                try std.testing.expectEqual(@as(u32, 2), try readLebU32(s.payload, &off));
            },
            SEC_DATA => {
                var off: usize = 0;
                try std.testing.expectEqual(@as(u32, 2), try readLebU32(s.payload, &off));
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

test "embed: tag section keeps its place before the inserted global section" {
    const allocator = std.testing.allocator;
    // memory + tag(empty) + export "memory": global/export insertion must
    // not land between memory and tag (tag binary-orders before global).
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // memory: 1 memory, flags 0, min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // tag section: 0 tags
        0x0D, 0x01, 0x00,
        // export: "memory" mem 0
        0x07, 0x0A, 0x01, 0x06, 'm',  'e',  'm',  'o',
        'r',  'y',  0x02, 0x00,
    };
    const index = [_]u8{ 1, 2, 3 };
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    // parseSections validates strict binary order — enough on its own, but
    // assert the expected sequence explicitly.
    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    var ids: std.ArrayList(u8) = .empty;
    defer ids.deinit(allocator);
    for (sections.items) |s| try ids.append(allocator, s.id);
    try std.testing.expectEqualSlices(u8, &.{ SEC_MEMORY, SEC_TAG, SEC_GLOBAL, SEC_EXPORT, SEC_DATA }, ids.items);

    const extracted = try extractIndex(allocator, patched);
    defer allocator.free(extracted);
    try std.testing.expectEqualSlices(u8, &index, extracted);
}

test "embed: imported globals shift the new global indices" {
    const allocator = std.testing.allocator;
    // import 1 global ("e"."g" i32 const) + 1 defined global → new globals
    // get indices 2 and 3; extract must still resolve them.
    const module = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1 entry, module "e", field "g", global i32 const
        0x02, 0x08, 0x01, 0x01, 'e',  0x01, 'g',  0x03,
        0x7F, 0x00,
        // memory: 1 memory, flags 0, min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
        // global: 1 defined global, i32 const, i32.const 7
        0x06, 0x06, 0x01, 0x7F, 0x00, 0x41, 0x07, 0x0B,
        // export: "memory" mem 0
        0x07, 0x0A, 0x01, 0x06, 'm',  'e',  'm',  'o',
        'r',  'y',  0x02, 0x00,
    };
    const index = [_]u8{ 5, 6, 7, 8 };
    const patched = try embed(allocator, &module, &index);
    defer allocator.free(patched);

    // Exported indices must account for the imported global
    var sections = try parseSections(allocator, patched);
    defer sections.deinit(allocator);
    for (sections.items) |s| {
        if (s.id != SEC_EXPORT) continue;
        const scan = try scanExports(s.payload);
        try std.testing.expect(scan.ptr_found and scan.len_found);
        try std.testing.expectEqual(@as(u32, 2), scan.ptr_idx);
        try std.testing.expectEqual(@as(u32, 3), scan.len_idx);
    }

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

    // imported memory only
    const imported_only = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // import: 1 entry, module "e", field "m", memory flags 0 min 1
        0x02, 0x08, 0x01, 0x01, 'e',  0x01, 'm',  0x02,
        0x00, 0x01,
    };
    try std.testing.expectError(error.UnsupportedMemory, embed(allocator, &imported_only, &index));

    // imported memory + defined memory (multi-memory)
    const imported_plus_defined = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x02, 0x08, 0x01, 0x01, 'e',  0x01, 'm',  0x02,
        0x00, 0x01,
        // memory: 1 defined memory, flags 0, min 1
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.UnsupportedMemory, embed(allocator, &imported_plus_defined, &index));
}

test "embed: already patched module rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{ 1, 2, 3 };
    const once = try embed(allocator, &test_minimal_wasm, &index);
    defer allocator.free(once);

    try std.testing.expectError(error.AlreadyPatched, embed(allocator, once, &index));
}

test "embed: export name conflict rejected" {
    const allocator = std.testing.allocator;
    const index = [_]u8{1};

    // memory + export "chaza_index_ptr" of kind func (name taken, wrong kind)
    const func_name_clash = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        // memory
        0x05, 0x03, 0x01, 0x00, 0x01,
        // export: 1 entry, "chaza_index_ptr" func 0
        0x07, 0x13, 0x01, 0x0F, 'c',  'h',  'a',  'z',
        'a',  '_',  'i',  'n',  'd',  'e',  'x',  '_',
        'p',  't',  'r',  0x00, 0x00,
    };
    try std.testing.expectError(error.ExportNameConflict, embed(allocator, &func_name_clash, &index));
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

    // export before memory (order violation)
    const misordered = [_]u8{
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x07, 0x0A, 0x01, 0x06, 'm',  'e',  'm',  'o',
        'r',  'y',  0x02, 0x00,
        0x05, 0x03, 0x01, 0x00, 0x01,
    };
    try std.testing.expectError(error.InvalidWasm, embed(allocator, &misordered, &index));

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

test "extract: module without chaza exports rejected" {
    try std.testing.expectError(error.MissingChazaExports, extractIndex(std.testing.allocator, &test_minimal_wasm));
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
