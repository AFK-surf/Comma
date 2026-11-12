import Foundation

struct ChatSuggestion: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let prompt: String

    init?(_ json: NSDictionary) {
        guard let id = json.string("id"), let label = json.string("label"), let prompt = json.string("prompt"),
              !prompt.isEmpty, prompt.count <= 12 else { return nil }
        self.id = id; self.label = label; self.prompt = prompt
    }
}
