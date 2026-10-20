import Testing
@testable import QuickChatCore

/// English as NSSpellChecker answers for these words: common words in any
/// case, a person's name only capitalized.
private func isEnglish(_ word: String) -> Bool {
    ["a", "comma", "linear", "liner", "notion", "regression", "slack", "time"].contains(word.lowercased())
        || ["Linda", "Lina", "Norton"].contains(word)
}

private func corrected(_ text: String) -> String {
    ProductNames.corrected(text, isWord: isEnglish)
}

struct ProductNamesTests {
    /// The recognizer's own mistakes, from the benchmark's synthetic voices.
    @Test func misheardNamesAreCorrected() {
        #expect(corrected("法 Githop上那个 glorycrest的评论总结一下。") == "法 GitHub上那个 glorycrest的评论总结一下。")
        #expect(corrected("把 Githok上那个评论总结一下") == "把 GitHub上那个评论总结一下")
        #expect(corrected("在 sleck上提醒大家明天的 stand up改到 10:00。") == "在 Slack上提醒大家明天的 stand up改到 10:00。")
        #expect(corrected("查一下 Notin你的 rotemath有没有更新。") == "查一下 Notion你的 rotemath有没有更新。")
        #expect(corrected("把 Figman里的设计稿 review一下") == "把 Figma里的设计稿 review一下")
    }

    @Test func aNameInAnotherCaseTakesItsMakersCase() {
        #expect(corrected("open github and feishu") == "open GitHub and Feishu")
        #expect(corrected("Github, googledrive") == "GitHub, Google Drive")
    }

    @Test func englishWordsStay() {
        #expect(corrected("linear regression, slack time, a comma, notion") == "linear regression, slack time, a comma, notion")
        // Two letters from "linear", but a person's name.
        #expect(corrected("ask Linda about the liner") == "ask Linda about the liner")
        // Names in lowercase, as the recognizer writes Latin words inside Chinese.
        #expect(corrected("跟 lina 说一下，问问 norton 的报价") == "跟 lina 说一下，问问 norton 的报价")
    }

    @Test func addressesNumbersAndIdentifiersStay() {
        let unchanged = [
            "https://github.com/comma/app",
            "ops@feishu.cn",
            "github2 and GITHUB",
            // Mixed case: an identifier, two letters from "GitHub".
            "GitLab",
        ]
        for text in unchanged {
            #expect(ProductNames.corrected(text) { _ in false } == text)
        }
    }

    @Test func aWordAsNearToTwoNamesOrTooShortStays() {
        let names = ["Box", "Loom", "Zoom"]
        #expect(ProductNames.corrected("bax woom bo", names: names) { _ in false } == "Box woom bo")
    }
}
