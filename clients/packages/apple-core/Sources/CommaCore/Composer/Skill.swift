import Foundation

/// A Workspace skill from `GET /v1/comma/workspaces/:id/skills`. The composer's / menu lists them; a message
/// names one as `/<skill_id>` in its text and tags its `location` in the send's `skills` field, which is what
/// activates it: the server ignores a bare `/name`.
public struct Skill: Codable, Equatable, Identifiable, Sendable {
    public let skillID: String
    public let name: String
    /// At most 280 characters; the server truncates.
    public let description: String?
    /// `/.runtime/skills/<skill_id>/SKILL.md`, the key a send tags.
    public let location: String
    /// `system`, `imported` or `custom`.
    public let source: String?
    /// `regular` or `per-message`.
    public let activation: String?
    public var id: String { skillID }

    enum CodingKeys: String, CodingKey { case skillID = "skill_id", name, description, location, source, activation }

    public init(skillID: String, name: String, description: String? = nil, location: String,
                source: String? = nil, activation: String? = nil) {
        self.skillID = skillID; self.name = name; self.description = description
        self.location = location; self.source = source; self.activation = activation
    }

    /// The server activates at most this many tagged skills in one message.
    public static let maxMentions = 10

    /// The locations of the catalog skills `text` names, for the send's `skills` field: the desktop
    /// `deriveMentionedSkills` (app composer/mentions.ts). A name is `/` at the start or after whitespace followed
    /// by a known id, matched case-insensitively. Each location appears once, in text order, at most
    /// `maxMentions` of them.
    public static func mentionedLocations(in text: String, catalog: [Skill]) -> [String] {
        var locations: [String] = []
        for mention in mentions(in: text, catalog: catalog) where !locations.contains(mention.location) {
            locations.append(mention.location)
        }
        return locations
    }

    /// Each name in `text` that tags a skill, from its `/` to the end of the id, with the location it tags, in text
    /// order: every name of the first `maxMentions` skills named, none of the skills after them.
    public static func mentions(in text: String, catalog: [Skill]) -> [(range: Range<String.Index>, location: String)] {
        guard !catalog.isEmpty, text.utf8.contains(UInt8(ascii: "/")) else { return [] }
        let byID = Dictionary(catalog.map { ($0.skillID.lowercased(), $0) }, uniquingKeysWith: { _, last in last })
        var mentions: [(range: Range<String.Index>, location: String)] = [], tagged: [String] = []
        for match in mention.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let id = Range(match.range(at: 2), in: text), let skill = byID[text[id].lowercased()] else { continue }
            if !tagged.contains(skill.location) {
                guard tagged.count < maxMentions else { continue }
                tagged.append(skill.location)
            }
            mentions.append((text.index(before: id.lowerBound)..<id.upperBound, skill.location))
        }
        return mentions
    }

    /// The desktop `mentionedSkillPattern`.
    private static let mention = try! NSRegularExpression(pattern: "(^|\\s)/([a-z0-9][a-z0-9_-]*)", options: .caseInsensitive)
}
