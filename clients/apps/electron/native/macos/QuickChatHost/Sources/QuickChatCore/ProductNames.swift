/// Comma and the apps it connects to, written as their makers write them. The
/// recognizer often mishears them, most of all inside Chinese ("Githop上",
/// "sleck上"); Enter sends them corrected.
public enum ProductNames {
    /// Comma, then the apps of the integration plugins
    /// (`systems/apps/salix_web/lib/salix/control/plugins.ex`) and of the
    /// Composio sources (`systems/apps/comma_web/lib/comma_web/recommendation_source_catalog.ex`),
    /// and Figma, which people name in their requests without a connection.
    /// X is left out: a name shorter than three letters never matches.
    public static let names = [
        "Comma",
        "Feishu",
        "Figma",
        "GitHub",
        "Gmail",
        "Google Calendar",
        "Google Drive",
        "Google Workspace",
        "Linear",
        "Microsoft Outlook",
        "Notion",
        "Slack",
    ]

    /// `text` with its misheard names corrected. A Latin word of three or more
    /// letters, in lowercase or capitalized, becomes
    ///
    /// - the name it spells in another case ("github" → "GitHub"), unless the
    ///   name is also an English word ("slack" stays);
    /// - else the name nearest to it, at most a third of the name's letters
    ///   away ("Githop" → "GitHub"), unless the word is English as written or
    ///   capitalized ("Linda" and "lina" stay) or another name is as near.
    ///
    /// `isWord` says whether a word is English. Addresses ("github.com",
    /// "a@feishu.cn"), mixed-case words ("GitLab") and words joined to digits
    /// stay. A name of several words matches one word without its spaces.
    public static func corrected(
        _ text: String,
        names: [String] = names,
        isWord: (String) -> Bool
    ) -> String {
        let entries = names.map { name in
            (name: name, key: Array(name.lowercased().filter { !$0.isWhitespace }))
        }
        var result = ""
        var chunk = ""
        for character in text {
            if character.isWhitespace {
                result += corrected(chunk: chunk, entries: entries, isWord: isWord)
                result.append(character)
                chunk = ""
            } else {
                chunk.append(character)
            }
        }
        return result + corrected(chunk: chunk, entries: entries, isWord: isWord)
    }

    /// One run of text without spaces, such as "Githop上那个".
    private static func corrected(
        chunk: String,
        entries: [(name: String, key: [Character])],
        isWord: (String) -> Bool
    ) -> String {
        let characters = Array(chunk)
        let isAddress = characters.indices.contains { index in
            let character = characters[index]
            if character == "@" || character == "/" { return true }
            // A dot between word characters: "github.com", "notes.txt".
            return character == "." && index > 0 && index + 1 < characters.count
                && characters[index - 1].isLatinWordCharacter && characters[index + 1].isLatinWordCharacter
        }
        guard !isAddress else { return chunk }

        var result = ""
        var word = ""
        for character in characters {
            if character.isLatinWordCharacter || character == "_" || character == "'" || character == "’" {
                word.append(character)
                continue
            }
            result += replacement(for: word, entries: entries, isWord: isWord) ?? word
            result.append(character)
            word = ""
        }
        return result + (replacement(for: word, entries: entries, isWord: isWord) ?? word)
    }

    private static func replacement(
        for word: String,
        entries: [(name: String, key: [Character])],
        isWord: (String) -> Bool
    ) -> String? {
        guard word.count >= 3,
              word.allSatisfy({ $0.isASCII && $0.isLetter }),
              word.dropFirst().allSatisfy(\.isLowercase)
        else { return nil }
        let key = Array(word.lowercased())
        if let exact = entries.first(where: { $0.key == key }) {
            return isWord(String(key)) ? nil : exact.name
        }
        // The dictionary has a person's name only capitalized ("Lina"), and
        // inside Chinese the recognizer often writes it in lowercase.
        guard !isWord(word), !isWord(word.prefix(1).uppercased() + word.dropFirst()) else { return nil }

        var nearest: (name: String, distance: Int)?
        var tied = false
        for entry in entries {
            let distance = editDistance(key, entry.key)
            guard distance <= entry.key.count / 3 else { continue }
            if let best = nearest, distance >= best.distance {
                if distance == best.distance { tied = true }
            } else {
                nearest = (entry.name, distance)
                tied = false
            }
        }
        return tied ? nil : nearest?.name
    }

    /// Insertions, deletions, substitutions and swaps of two neighbors, each
    /// counted once (Damerau-Levenshtein, optimal string alignment).
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { table[i][0] = i }
        for j in 0...b.count { table[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
                }
            }
        }
        return table[a.count][b.count]
    }
}
