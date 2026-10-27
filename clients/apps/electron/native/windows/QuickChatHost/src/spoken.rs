//! Words joined as Quick Chat joins what was said (src/quick-chat-host/spoken.ts): Latin words keep a space between
//! them, and so does an English sentence's end before the next; Chinese and a Latin word or digit get one (as Comma's
//! Chinese text is written), CJK text has none.

fn cjk_letter(c: char) -> bool {
    matches!(c as u32,
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x2FA1F // Han
        | 0x3040..=0x309F | 0x30A0..=0x30FF | 0x31F0..=0x31FF // Hiragana, Katakana
        | 0x1100..=0x11FF | 0x3130..=0x318F | 0xAC00..=0xD7AF) // Hangul
}

fn cjk(c: char) -> bool {
    cjk_letter(c) || matches!(c as u32, 0x3000..=0x303F | 0xFF00..=0xFFEF)
}

fn latin(c: char) -> bool {
    c.is_alphanumeric() && !cjk(c)
}

/// `words` continuing `draft`.
pub fn join_spoken(draft: &str, words: &str) -> String {
    let head = draft.trim();
    let (Some(last), Some(first)) = (head.chars().last(), words.chars().next()) else {
        return format!("{head}{words}");
    };
    let spaced = (latin(last) || ".,!?;:".contains(last) || cjk_letter(last))
        && (latin(first) || cjk_letter(first))
        && !(cjk_letter(last) && cjk_letter(first));
    if spaced {
        format!("{head} {words}")
    } else {
        format!("{head}{words}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_join_as_comma_writes_them() {
        assert_eq!(join_spoken("Draft the reply", "and send it"), "Draft the reply and send it");
        assert_eq!(join_spoken("Send it.", "Then check"), "Send it. Then check");
        assert_eq!(join_spoken("帮我整理", "一下"), "帮我整理一下");
        assert_eq!(join_spoken("把", "Figma"), "把 Figma");
        assert_eq!(join_spoken("Figma", "稿子"), "Figma 稿子");
        assert_eq!(join_spoken("", "words"), "words");
        assert_eq!(join_spoken("日程。", "然后"), "日程。然后");
    }
}
