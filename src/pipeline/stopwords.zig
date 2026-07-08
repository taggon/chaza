//! chaza stopword set — parser + filter.
//!
//! Tokenization pipeline stage 3: after segmentation, before unique token collection·choseong generation, remove stopwords.
//!
//! File format (SPEC): UTF-8, one stopword per line.
//! Trim leading/trailing whitespace, ignore empty lines, ignore '#' starting lines as comments.
//!
//! Case sensitivity: since tokenize() lowercases ASCII A-Z, parse time also ASCII lowercases for storage.
//! isStopword O(1) lookup on already-lowercased token (per pipeline contract).

const std = @import("std");

/// Stopword set. HashSet for O(1) lookup.
pub const StopwordSet = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,

    /// Parse stopword set from file content (UTF-8 bytes).
    /// Per line, '#' comments, trim, ignore empty lines. ASCII A-Z lowercased for storage.
    /// Each key owned by allocator. caller free via deinit.
    pub fn fromFileBytes(allocator: std.mem.Allocator, file_bytes: []const u8) !StopwordSet {
        var self: StopwordSet = .{};
        errdefer self.deinit(allocator);

        var it = std.mem.splitScalar(u8, file_bytes, '\n');
        while (it.next()) |raw_line| {
            // Trim leading/trailing whitespace (space·tab·CR)
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue; // ignore empty lines
            if (line[0] == '#') continue; // ignore comments

            // ASCII lowercased copy (consistency with tokenize result comparison)
            const lowered = try asciiLowerDup(allocator, line);
            errdefer allocator.free(lowered);

            // If same key already exists, free this copy
            const gop = try self.set.getOrPut(allocator, lowered);
            if (gop.found_existing) {
                allocator.free(lowered);
            }
        }
        return self;
    }

    /// O(1) lookup: is token a stopword?
    /// Per pipeline contract, token must be ASCII-lowercased via tokenize().
    pub fn isStopword(self: StopwordSet, token: []const u8) bool {
        return self.set.contains(token);
    }

    /// Count of stopwords in set.
    pub fn count(self: StopwordSet) usize {
        return self.set.count();
    }

    /// Free allocation. Return each key string and hashmap to allocator.
    pub fn deinit(self: *StopwordSet, allocator: std.mem.Allocator) void {
        var it = self.set.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.set.deinit(allocator);
    }
};

/// Stopword removal disabled state. isStopword always false.
pub const EMPTY: StopwordSet = .{};

/// Create copy lowercasing only ASCII A-Z. Non-ASCII preserved.
/// Same logic as tokenize.appendCodepoint lowercasing.
fn asciiLowerDup(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        out[i] = if (c >= 'A' and c <= 'Z') c + 0x20 else c;
    }
    return out;
}

// ── Assertion tests ────────────────────────────────────────────────────

test "empty file → empty set, isStopword always false" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), set.count());
    try std.testing.expect(!set.isStopword("the"));
    try std.testing.expect(!set.isStopword(""));
}

test "single word file → that word is stopword" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(!set.isStopword("foo"));
}

test "multiple lines → each is stopword" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\na\nan\nof\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("a"));
    try std.testing.expect(set.isStopword("an"));
    try std.testing.expect(set.isStopword("of"));
}

test "ignore empty lines" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\n\n\nan\n\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
}

test "ignore '#' starting lines as comments" {
    const allocator = std.testing.allocator;
    const file =
        \\# this is comment
        \\the
        \\# other comment
        \\an
        \\
        \\# comment with leading space
    ;
    var set = try StopwordSet.fromFileBytes(allocator, file);
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
    // comment content not registered as stopwords
    try std.testing.expect(!set.isStopword("이것은"));
    try std.testing.expect(!set.isStopword("주석"));
}

test "trim leading/trailing whitespace on lines" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "   the   \n\tan\t\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
}

test "uppercase input → lowercased then stored (THE → the)" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "THE\nAn\nOF");
    defer set.deinit(allocator);

    // Lowercased at parse time: set stores lowercase
    try std.testing.expectEqual(@as(usize, 3), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
    try std.testing.expect(set.isStopword("of"));
}

test "Korean stopwords processing (이, 가)" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "이\n가\n은\n는\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), set.count());
    try std.testing.expect(set.isStopword("이"));
    try std.testing.expect(set.isStopword("가"));
    try std.testing.expect(set.isStopword("은"));
    try std.testing.expect(set.isStopword("는"));
    try std.testing.expect(!set.isStopword("안녕"));
}

test "isStopword empty set → always false" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "");
    defer set.deinit(allocator);

    try std.testing.expect(!set.isStopword("the"));
    try std.testing.expect(!set.isStopword("이"));
    try std.testing.expect(!set.isStopword("anything"));
}

test "fromFileBytes memory management: no leaks with deinit (testing.allocator)" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "a\nb\nc\nd\ne\n");
    set.deinit(allocator);
    // testing.allocator fails on leaks. passing here means freed.
}

test "pipeline consistency: file 'THE' matches tokenize('The') token" {
    const allocator = std.testing.allocator;
    const tokenize = @import("tokenize.zig");

    var set = try StopwordSet.fromFileBytes(allocator, "THE\n");
    defer set.deinit(allocator);

    // tokenize lowercases so "The" → "the"
    var tokens: std.ArrayList([]const u8) = .empty;
    defer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }
    try tokenize.tokenize(allocator, "The quick", &tokens);

    // First token ("the") should match as stopword
    try std.testing.expectEqualStrings("the", tokens.items[0]);
    try std.testing.expect(set.isStopword(tokens.items[0]));
    try std.testing.expect(!set.isStopword(tokens.items[1])); // "quick"
}

test "complex file: comments + empty lines + words + mixed case" {
    const allocator = std.testing.allocator;
    const file =
        \\# English stopwords
        \\the
        \\THE
        \\a
        \\
        \\# Korean
        \\이
        \\가
        \\
        \\   of
    ;
    var set = try StopwordSet.fromFileBytes(allocator, file);
    defer set.deinit(allocator);

    // "the" and "THE" same key → deduplicated
    try std.testing.expectEqual(@as(usize, 5), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("a"));
    try std.testing.expect(set.isStopword("이"));
    try std.testing.expect(set.isStopword("가"));
    try std.testing.expect(set.isStopword("of"));
}

test "CRLF line ending trim handling" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\r\nan\r\n");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
}

test "parse file without trailing newline" {
    const allocator = std.testing.allocator;
    var set = try StopwordSet.fromFileBytes(allocator, "the\nan");
    defer set.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), set.count());
    try std.testing.expect(set.isStopword("the"));
    try std.testing.expect(set.isStopword("an"));
}

test "EMPTY constant → isStopword always false" {
    try std.testing.expect(!EMPTY.isStopword("the"));
    try std.testing.expect(!EMPTY.isStopword(""));
    try std.testing.expectEqual(@as(usize, 0), EMPTY.count());
}