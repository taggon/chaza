//! chaza tokenization Unicode script group classification.
//!
//! MVP handling scope: Latin / Hangul / Han / Hiragana / Katakana / Number(ASCII + fullwidth) +
//! common Combining Mark. Letters outside this scope (Cyrillic/Arabic/Thai etc) treated as delimiters
//! breaking runs. Future "other" introduction planned to group these as separate runs.

const std = @import("std");

/// Tokenization group for character. Consecutive same group forms one run (token candidate).
pub const ScriptGroup = enum(u4) {
    /// Not a token character. Run boundary. (includes symbols/space/control/unsupported Letter)
    delimiter,
    /// Combining mark (Mn/Mc). Absorbed into preceding run, doesn't break run.
    mark,
    /// Latin alphabet (ASCII + Latin Extended + IPA + Latin Additional).
    latin,
    /// Hangul (syllable/jamo/compatibility jamo/halfwidth).
    hangul,
    /// Han (CJK Unified Han + Ext A/B + Compatibility Han).
    han,
    /// Hiragana.
    hiragana,
    /// Katakana (fullwidth/halfwidth).
    katakana,
    /// Numbers (ASCII 0-9 + fullwidth 0-9). Can extend to other Nd in future.
    number,
    /// Letter/Number but outside above ranges. MVP unused — currently all fall as delimiter.
    _,
};

/// Classify codepoint into ScriptGroup.
/// Handle frequent ASCII first, then block range checks.
pub fn scriptGroupOf(cp: u21) ScriptGroup {
    // ── ASCII fast path ──
    if (cp < 0x80) {
        if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z')) return .latin;
        if (cp >= '0' and cp <= '9') return .number;
        return .delimiter;
    }

    // ── Combining marks (frequently used ranges) ──
    if (in(cp, 0x0300, 0x036F)) return .mark;
    if (in(cp, 0x1AB0, 0x1AFF)) return .mark;
    if (in(cp, 0x1DC0, 0x1DFF)) return .mark;
    if (in(cp, 0x20D0, 0x20FF)) return .mark;
    if (in(cp, 0xFE20, 0xFE2F)) return .mark;

    // ── Latin ──
    // ×(U+00D7), ÷(U+00F7) are symbols, exclude from Latin-1 Supplement.
    if (cp == 0x00D7 or cp == 0x00F7) return .delimiter;
    if (in(cp, 0x00C0, 0x00FF)) return .latin; // Latin-1 Supplement
    if (in(cp, 0x0100, 0x024F)) return .latin; // Latin Extended A/B
    if (in(cp, 0x0250, 0x02AF)) return .latin; // IPA
    if (in(cp, 0x1E00, 0x1EFF)) return .latin; // Latin Extended Additional

    // ── Hangul ──
    if (in(cp, 0xAC00, 0xD7A3)) return .hangul; // syllable
    if (in(cp, 0x1100, 0x11FF)) return .hangul; // jamo
    if (in(cp, 0x3130, 0x318F)) return .hangul; // compatibility jamo
    if (in(cp, 0xFFA0, 0xFFDC)) return .hangul; // halfwidth

    // ── Japanese kana ──
    if (in(cp, 0x3040, 0x309F)) return .hiragana;
    if (in(cp, 0x30A0, 0x30FF)) return .katakana;
    if (in(cp, 0x31F0, 0x31FF)) return .katakana; // phonetic ext
    if (in(cp, 0xFF65, 0xFF9F)) return .katakana; // halfwidth

    // ── Han ──
    if (in(cp, 0x4E00, 0x9FFF)) return .han; // CJK Unified
    if (in(cp, 0x3400, 0x4DBF)) return .han; // Ext A
    if (in(cp, 0xF900, 0xFAFF)) return .han; // Compatibility Han
    if (in(cp, 0x20000, 0x2FFFF)) return .han; // Ext B+

    // ── Fullwidth numbers ──
    if (in(cp, 0xFF10, 0xFF19)) return .number;

    // Others: unsupported Letter/symbols/emoji — MVP treats all as delimiter.
    return .delimiter;
}

/// Closed interval [lo, hi] inclusive check.
inline fn in(cp: u21, lo: u21, hi: u21) bool {
    return cp >= lo and cp <= hi;
}

// ── Assertion tests ────────────────────────────────────────────────────

test "ASCII latin/number/delimiter" {
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf('a'));
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf('A'));
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf('z'));
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf('Z'));
    try std.testing.expectEqual(ScriptGroup.number, scriptGroupOf('0'));
    try std.testing.expectEqual(ScriptGroup.number, scriptGroupOf('9'));
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(' '));
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('!'));
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('\n'));
}

test "ASCII boundary characters are delimiters" {
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('@')); // 0x40, just before A
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('[')); // 0x5B, just after Z
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('`')); // 0x60, just before a
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('{')); // 0x7B, just after z
}

test "representative combining mark codepoints" {
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x0300)); // combining grave
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x036F));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x1AB0));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x1DC0));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x20D0));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0xFE20));
}

test "Latin-1 Supplement: latin vs ×, ÷ symbols" {
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00C0)); // À
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00F6)); // ö
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x00D7)); // ×
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x00F7)); // ÷
    // characters immediately adjacent to ×, ÷ are latin
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00D6)); // Ö
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00D8)); // Ø
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00F6)); // ö
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00F8)); // ø
}

test "Latin Extended-A/B and IPA, Additional" {
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x0100)); // Ā (Ext-A start)
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x024F)); // Ext-B end
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x0250)); // IPA start
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x1E00)); // Latin Additional start
}

test "Hangul syllable/jamo/compatibility jamo/halfwidth" {
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0xAC00)); // 가
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0xD7A3)); // 힣
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0x1100)); // ᄀ jamo
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0x3131)); // ㄱ compatibility jamo
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0xFFA0)); // halfwidth
}

test "Hiragana/Katakana" {
    try std.testing.expectEqual(ScriptGroup.hiragana, scriptGroupOf(0x3042)); // あ
    try std.testing.expectEqual(ScriptGroup.hiragana, scriptGroupOf(0x309F)); // block end
    try std.testing.expectEqual(ScriptGroup.katakana, scriptGroupOf(0x30A2)); // ア
    try std.testing.expectEqual(ScriptGroup.katakana, scriptGroupOf(0x31F0)); // phonetic ext
    try std.testing.expectEqual(ScriptGroup.katakana, scriptGroupOf(0xFF66)); // halfwidth ｱ
}

test "Han Unified/Ext A/Ext B" {
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x4E00)); // 一 (Unified start)
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x9FA5)); // 龥
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x3400)); // 㐀 (Ext A start)
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0xF900)); // Compatibility Han
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x20000)); // Ext B start
}

test "Fullwidth numbers" {
    try std.testing.expectEqual(ScriptGroup.number, scriptGroupOf(0xFF10)); // ０
    try std.testing.expectEqual(ScriptGroup.number, scriptGroupOf(0xFF19)); // ９
}

test "unsupported characters are delimiters: emoji/symbols/Cyrillic" {
    // emoji
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x1F525)); // 🔥
    // fullwidth punctuation/space
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x3000)); // fullwidth space
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0xFF0C)); // ，
    // CJK symbols
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x3001)); // 、
}

test "MVP constraint specified: Cyrillic/Arabic are delimiter not other" {
    // When "other" introduced, these assertions change to .other.
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x0414)); // Д (Cyrillic)
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x0627)); // ا (Arabic)
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x0E01)); // ก (Thai)
}