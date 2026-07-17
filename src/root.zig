//! chaza — tiny static site search engine that finds by choseong.
//! Module root: re-export sub-modules.
const std = @import("std");

pub const index = struct {
    pub const format = @import("index/format.zig");
    pub const writer = @import("index/writer.zig");
    pub const reader = @import("index/reader.zig");
    pub const roundtrip_test = @import("index/roundtrip_test.zig");
};

pub const pipeline = struct {
    pub const script = @import("pipeline/script.zig");
    pub const hash = @import("pipeline/hash.zig");
    pub const tokenize = @import("pipeline/tokenize.zig");
    pub const binary_fuse = @import("pipeline/binary_fuse.zig");
    pub const choseong = @import("pipeline/choseong.zig");
    pub const prefix = @import("pipeline/prefix.zig");
    pub const stopwords = @import("pipeline/stopwords.zig");
};

pub const wasm_patch = @import("wasm_patch.zig");
pub const runtime = @import("runtime.zig");
pub const generator = @import("generator.zig");
pub const golden_test = @import("golden_test.zig");

test {
    // Force sub-module test blocks to be included in analysis target.
    _ = index.format;
    _ = index.writer;
    _ = index.reader;
    _ = index.roundtrip_test;
    _ = pipeline.script;
    _ = pipeline.hash;
    _ = pipeline.tokenize;
    _ = pipeline.binary_fuse;
    _ = pipeline.choseong;
    _ = pipeline.prefix;
    _ = pipeline.stopwords;
    _ = wasm_patch;
    _ = runtime;
    _ = generator;
    _ = golden_test;
}