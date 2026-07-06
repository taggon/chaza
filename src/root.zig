//! chaza — 초성으로도 찾아주는 아주 작은 정적 사이트 검색 엔진.
//! 모듈 루트: 하위 모듈을 재노출.
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
    pub const stopwords = @import("pipeline/stopwords.zig");
};

pub const bundle = @import("bundle.zig");
pub const runtime = @import("runtime.zig");
pub const generator = @import("generator.zig");
pub const golden_test = @import("golden_test.zig");

test {
    // 하위 모듈의 test 블록이 분석 대상에 포함되도록 강제.
    _ = index.format;
    _ = index.writer;
    _ = index.reader;
    _ = index.roundtrip_test;
    _ = pipeline.script;
    _ = pipeline.hash;
    _ = pipeline.tokenize;
    _ = pipeline.binary_fuse;
    _ = pipeline.choseong;
    _ = pipeline.stopwords;
    _ = bundle;
    _ = runtime;
    _ = generator;
    _ = golden_test;
}
