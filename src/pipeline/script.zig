//! chaza 토큰화용 유니코드 스크립트 그룹 분류.
//!
//! MVP 처리 범위: Latin / Hangul / Han / Hiragana / Katakana / Number(ASCII + 전각) +
//! 흔한 Combining Mark. 범위 밖 Letter(Cyrillic/Arabic/Thai 등)는 delimiter로 취급해
//! run을 끊는다. 향후 "other" 도입 시 these를 별도 run으로 묶는 경로로 확장 예정.

const std = @import("std");

/// 문자의 토큰화 그룹. 연속 같은 그룹이 한 run(토큰 후보)을 이룸.
pub const ScriptGroup = enum(u4) {
    /// 토큰 문자 아님. run 경계. (기호/공백/제어/미지원 Letter 포함)
    delimiter,
    /// Combining mark (Mn/Mc). 앞 run에 흡수되며 run을 끊지 않음.
    mark,
    /// 라틴 알파벳 (ASCII + Latin Extended + IPA + Latin Additional).
    latin,
    /// 한글 (음절/자모/호환자모/반각).
    hangul,
    /// 한자 (CJK 통합한자 + Ext A/B + 호환한자).
    han,
    /// 히라가나.
    hiragana,
    /// 가타카나 (전각/반각).
    katakana,
    /// 숫자 (ASCII 0-9 + 전각 0-9). 향후 다른 Nd 확장 가능.
    number,
    /// Letter/Number이지만 위 범위 밖. MVP에서는 사용 안 함 — 현재는 모두 delimiter로 떨어짐.
    _,
};

/// codepoint를 ScriptGroup으로 분류.
/// 빈도 높은 ASCII를 먼저 처리하고, 이어 블록 범위 검사.
pub fn scriptGroupOf(cp: u21) ScriptGroup {
    // ── ASCII fast path ──
    if (cp < 0x80) {
        if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z')) return .latin;
        if (cp >= '0' and cp <= '9') return .number;
        return .delimiter;
    }

    // ── Combining marks (자주 쓰이는 범위) ──
    if (in(cp, 0x0300, 0x036F)) return .mark;
    if (in(cp, 0x1AB0, 0x1AFF)) return .mark;
    if (in(cp, 0x1DC0, 0x1DFF)) return .mark;
    if (in(cp, 0x20D0, 0x20FF)) return .mark;
    if (in(cp, 0xFE20, 0xFE2F)) return .mark;

    // ── Latin ──
    // ×(U+00D7), ÷(U+00F7)은 기호이므로 Latin-1 보충에서 제외.
    if (cp == 0x00D7 or cp == 0x00F7) return .delimiter;
    if (in(cp, 0x00C0, 0x00FF)) return .latin; // Latin-1 보충
    if (in(cp, 0x0100, 0x024F)) return .latin; // Latin Extended A/B
    if (in(cp, 0x0250, 0x02AF)) return .latin; // IPA
    if (in(cp, 0x1E00, 0x1EFF)) return .latin; // Latin Extended Additional

    // ── Hangul ──
    if (in(cp, 0xAC00, 0xD7A3)) return .hangul; // 음절
    if (in(cp, 0x1100, 0x11FF)) return .hangul; // 자모
    if (in(cp, 0x3130, 0x318F)) return .hangul; // 호환 자모
    if (in(cp, 0xFFA0, 0xFFDC)) return .hangul; // 반각

    // ── 일본어 가나 ──
    if (in(cp, 0x3040, 0x309F)) return .hiragana;
    if (in(cp, 0x30A0, 0x30FF)) return .katakana;
    if (in(cp, 0x31F0, 0x31FF)) return .katakana; // phonetic ext
    if (in(cp, 0xFF65, 0xFF9F)) return .katakana; // 반각

    // ── 한자 ──
    if (in(cp, 0x4E00, 0x9FFF)) return .han; // CJK 통합
    if (in(cp, 0x3400, 0x4DBF)) return .han; // Ext A
    if (in(cp, 0xF900, 0xFAFF)) return .han; // 호환 한자
    if (in(cp, 0x20000, 0x2FFFF)) return .han; // Ext B+

    // ── 전각 숫자 ──
    if (in(cp, 0xFF10, 0xFF19)) return .number;

    // 그 외: 미지원 Letter/기호/emoji — MVP에서는 모두 delimiter.
    return .delimiter;
}

/// 닫힌 구간 [lo, hi] 포함 검사.
inline fn in(cp: u21, lo: u21, hi: u21) bool {
    return cp >= lo and cp <= hi;
}

// ── 단정 테스트 ────────────────────────────────────────────────────

test "ASCII 라틴/숫자/구분자" {
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

test "ASCII 경계 문자는 delimiter" {
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('@')); // 0x40, A 직전
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('[')); // 0x5B, Z 직후
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('`')); // 0x60, a 직전
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf('{')); // 0x7B, z 직후
}

test "Combining mark 대표 codepoint" {
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x0300)); // combining grave
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x036F));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x1AB0));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x1DC0));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0x20D0));
    try std.testing.expectEqual(ScriptGroup.mark, scriptGroupOf(0xFE20));
}

test "Latin-1 보충: 라틴과 ×, ÷ 기호 구분" {
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00C0)); // À
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00F6)); // ö
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x00D7)); // ×
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x00F7)); // ÷
    // ×, ÷ 바로 양옆은 라틴
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00D6)); // Ö
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00D8)); // Ø
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00F6)); // ö
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x00F8)); // ø
}

test "Latin Extended-A/B 및 IPA, Additional" {
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x0100)); // Ā (Ext-A 시작)
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x024F)); // Ext-B 끝
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x0250)); // IPA 시작
    try std.testing.expectEqual(ScriptGroup.latin, scriptGroupOf(0x1E00)); // Latin Additional 시작
}

test "Hangul 음절/자모/호환자모/반각" {
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0xAC00)); // 가
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0xD7A3)); // 힣
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0x1100)); // ᄀ 자모
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0x3131)); // ㄱ 호환자모
    try std.testing.expectEqual(ScriptGroup.hangul, scriptGroupOf(0xFFA0)); // 반각
}

test "히라가나/가타카나" {
    try std.testing.expectEqual(ScriptGroup.hiragana, scriptGroupOf(0x3042)); // あ
    try std.testing.expectEqual(ScriptGroup.hiragana, scriptGroupOf(0x309F)); // 블록 끝
    try std.testing.expectEqual(ScriptGroup.katakana, scriptGroupOf(0x30A2)); // ア
    try std.testing.expectEqual(ScriptGroup.katakana, scriptGroupOf(0x31F0)); // phonetic ext
    try std.testing.expectEqual(ScriptGroup.katakana, scriptGroupOf(0xFF66)); // 반각 ｱ
}

test "한자 통일/Ext A/Ext B" {
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x4E00)); // 一 (통일 시작)
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x9FA5)); // 龥
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x3400)); // 㐀 (Ext A 시작)
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0xF900)); // 호환 한자
    try std.testing.expectEqual(ScriptGroup.han, scriptGroupOf(0x20000)); // Ext B 시작
}

test "전각 숫자" {
    try std.testing.expectEqual(ScriptGroup.number, scriptGroupOf(0xFF10)); // ０
    try std.testing.expectEqual(ScriptGroup.number, scriptGroupOf(0xFF19)); // ９
}

test "미지원 문자는 delimiter: emoji/기호/Cyrillic" {
    // emoji
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x1F525)); // 🔥
    // 전각 구두점/공백
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x3000)); // 전각 공백
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0xFF0C)); // ，
    // CJK 기호
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x3001)); // 、
}

test "MVP 제약 명시: Cyrillic/Arabic은 other가 아닌 delimiter" {
    // 향후 "other" 도입 시 이 단정들은 .other로 변경됨.
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x0414)); // Д (Cyrillic)
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x0627)); // ا (Arabic)
    try std.testing.expectEqual(ScriptGroup.delimiter, scriptGroupOf(0x0E01)); // ก (Thai)
}
