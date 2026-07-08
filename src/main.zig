//! chaza CLI — corpus JSON → searchable static bundle.
//!
//! Usage:
//!   chaza build corpus.json [-o chaza.wasm] [--config config.json]
//!                          [--stopwords stopwords.txt] [--no-choseong]
//!                          [--no-js] [-q]

const std = @import("std");
const chaza = @import("chaza");
const generator = chaza.generator;
const embeds = @import("chaza_embeds");

// build.zig injects runtime.wasm and chaza.js via @embedFile.
const RUNTIME_WASM: []const u8 = embeds.runtime_wasm;
const LOADER_JS: []const u8 = embeds.loader_js;

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    if (args.len < 2) {
        printUsage();
        return error.MissingCommand;
    }

    if (!std.mem.eql(u8, args[1], "build")) {
        std.debug.print("chaza: unknown command '{s}'\n", .{args[1]});
        printUsage();
        return error.UnknownCommand;
    }

    if (args.len < 3) {
        std.debug.print("chaza: missing corpus path\n", .{});
        printUsage();
        return error.MissingCorpusPath;
    }

    const corpus_path = args[2];

    // Defaults
    var output_path: []const u8 = "chaza.bundle";
    var config_path: ?[]const u8 = null;
    var stopwords_path: ?[]const u8 = null;
    var no_choseong = false;
    var no_js = false;
    var quiet = false;

    // Option parsing (manual)
    var i: usize = 3;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--stopwords")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            stopwords_path = args[i];
        } else if (std.mem.eql(u8, arg, "--no-choseong")) {
            no_choseong = true;
        } else if (std.mem.eql(u8, arg, "--no-js")) {
            no_js = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return;
        } else {
            std.debug.print("chaza: unknown option '{s}'\n", .{arg});
            return error.UnknownOption;
        }
        i += 1;
    }

    // Read corpus.json
    const corpus_bytes = cwd.readFileAlloc(io, corpus_path, arena, .limited(200 * 1024 * 1024)) catch |err| {
        std.debug.print("chaza: cannot read '{s}': {}\n", .{ corpus_path, err });
        return err;
    };

    // Configure GenerateOptions
    var options = generator.GenerateOptions{};

    // Apply config.json
    if (config_path) |cp| {
        const config_bytes = cwd.readFileAlloc(io, cp, arena, .limited(10 * 1024 * 1024)) catch |err| {
            std.debug.print("chaza: cannot read config '{s}': {}\n", .{ cp, err });
            return err;
        };
        options = try parseConfig(arena, config_bytes, options);
    }

    // CLI override
    if (no_choseong) options.choseong_max_len = 0;

    // Load stopwords file
    var sw_count: ?usize = null;
    if (stopwords_path) |sp| {
        const sw_bytes = cwd.readFileAlloc(io, sp, arena, .limited(10 * 1024 * 1024)) catch |err| {
            std.debug.print("chaza: cannot read stopwords '{s}': {}\n", .{ sp, err });
            return err;
        };
        const sw = chaza.pipeline.stopwords.StopwordSet.fromFileBytes(arena, sw_bytes) catch |err| {
            std.debug.print("chaza: cannot parse stopwords '{s}': {}\n", .{ sp, err });
            return err;
        };
        sw_count = sw.count();
        options.stopwords = sw;
    }

    // Generate
    const result = generator.generate(arena, corpus_bytes, RUNTIME_WASM, options) catch |err| {
        std.debug.print("chaza: generation failed: {}\n", .{err});
        return err;
    };

    // Write bundle
    cwd.writeFile(io, .{ .sub_path = output_path, .data = result.bundle_bytes }) catch |err| {
        std.debug.print("chaza: cannot write '{s}': {}\n", .{ output_path, err });
        return err;
    };

    // Write chaza.js loader to same directory (omit if --no-js)
    if (!no_js) {
        const loader_path = blk: {
            if (std.mem.lastIndexOfScalar(u8, output_path, '/')) |sep| {
                break :blk try std.fmt.allocPrint(arena, "{s}/chaza.js", .{output_path[0..sep]});
            }
            break :blk "chaza.js";
        };
        cwd.writeFile(io, .{ .sub_path = loader_path, .data = LOADER_JS }) catch |err| {
            std.debug.print("chaza: cannot write '{s}': {}\n", .{ loader_path, err });
            return err;
        };
    }

    // Progress log (stderr)
    if (!quiet) {
        const choseong_status = if (options.choseong_max_len > 0) "on" else "off";
        std.debug.print("parsed {d} documents\n", .{result.num_docs});
        if (sw_count) |c| {
            std.debug.print("stopwords: {d} entries\n", .{c});
        }
        std.debug.print("tokenized (choseong: {s}, max_len {d})\n", .{ choseong_status, options.choseong_max_len });
        std.debug.print("wrote index: ~{d} bytes\n", .{result.index_size});
        std.debug.print("embedded runtime wasm: {d} bytes\n", .{RUNTIME_WASM.len});
        std.debug.print("→ {s} ({d} bytes)\n", .{ output_path, result.bundle_bytes.len });
    }
}

/// Parse chaza.json config file → apply to GenerateOptions.
fn parseConfig(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    base: generator.GenerateOptions,
) !generator.GenerateOptions {
    var result = base;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return result;

    if (root.object.get("schema")) |schema| {
        if (schema == .object) {
            if (schema.object.get("indexed_fields")) |f| {
                if (f == .array) result.indexed_fields = try jsonArrayOfStrings(allocator, f.array.items);
            }
            if (schema.object.get("metadata_fields")) |f| {
                if (f == .array) result.metadata_fields = try jsonArrayOfStrings(allocator, f.array.items);
            }
            if (schema.object.get("prefix_fields")) |f| {
                if (f == .array) result.prefix_fields = try jsonArrayOfStrings(allocator, f.array.items);
            }
            if (schema.object.get("url_field")) |f| {
                if (f == .string) result.url_field = f.string;
            }
        }
    }

    if (root.object.get("korean")) |korean| {
        if (korean == .object) {
            if (korean.object.get("choseong_search")) |f| {
                if (f == .bool and !f.bool) result.choseong_max_len = 0;
            }
            if (korean.object.get("choseong_max_len")) |f| {
                if (f == .integer) result.choseong_max_len = @intCast(f.integer);
            }
        }
    }

    return result;
}

/// Extract string slice from JSON array.
fn jsonArrayOfStrings(allocator: std.mem.Allocator, items: []std.json.Value) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, idx| {
        result[idx] = if (item == .string) item.string else "";
    }
    return result;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: chaza build <corpus.json> [options]
        \\
        \\Options:
        \\  -o, --output <path>      Output bundle path (default: chaza.bundle)
        \\  --config <path>          Path to chaza.json config file
        \\  --stopwords <path>       Stopwords file (line-separated)
        \\  --no-choseong            Disable choseong search
        \\  --no-js                  Skip writing chaza.js loader
        \\  -q, --quiet              Suppress progress output
        \\  -h, --help               Show this help
        \\
    , .{});
}