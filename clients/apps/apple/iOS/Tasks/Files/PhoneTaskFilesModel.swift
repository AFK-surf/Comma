import Foundation
import Observation

struct PhoneTaskFile: Identifiable, Sendable, Equatable {
    let conversation: String
    let message: String
    let index: Int
    let name: String
    let size: Int
    let mediaType: String?
    let createdAt: Double
    var id: String { "\(conversation)/\(message)/\(index)" }

    init?(_ json: NSDictionary) {
        guard let conversation = json.string("conversation_id"), let message = json.string("message_id"),
              let index = json.int("index"), let name = json.string("file_name") else { return nil }
        self.conversation = conversation; self.message = message; self.index = index; self.name = name
        size = json.int("size") ?? 0; mediaType = json.string("mime_type"); createdAt = json.double("created_at") ?? 0
    }

    func source(group: String) -> [String: Any] {
        ["source": "attachment", "group": group, "conversation": conversation, "message": message, "index": index]
    }
}

@MainActor @Observable
final class PhoneTaskFilesModel {
    let scope: WorkspaceSettingsScope
    let pane: ConversationPane
    private(set) var files: [PhoneTaskFile] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var indexing = false
    private(set) var cursor: String?
    private(set) var preparing: String?
    private(set) var attaching = false
    private var readGeneration = 0

    init(store: CommaStore, pane: ConversationPane) {
        self.pane = pane
        scope = WorkspaceSettingsScope(store: store, workspace: pane.workspace)
    }

    var current: Bool { scope.current && !pane.closed }

    func load(more: Bool = false) async {
        guard current, !more || !loading && cursor != nil else { return }
        readGeneration += 1
        let generation = readGeneration
        loading = true; scope.error = nil
        defer { if generation == readGeneration { loading = false } }
        var params: [String: Any] = ["group": scope.workspace.groupID, "conversation": pane.conversationID]
        if more, let cursor { params["cursor"] = cursor }
        do {
            let answer = try await scope.call("taskFiles.list", params, workspaceParameter: false)
            guard current, generation == readGeneration, let json = answer.object else { return }
            loaded = true
            indexing = json.string("status") == "indexing"
            guard json.string("status") == "ready" else {
                if !indexing { scope.error = String(localized: "Couldn’t load task files") }
                return
            }
            let next = json.objects("files").compactMap(PhoneTaskFile.init).filter { $0.conversation == pane.conversationID }
            var ids = Set<String>()
            files = ((more ? files : []) + next).filter { ids.insert($0.id).inserted }
            cursor = json.string("nextCursor")
        } catch is CancellationError { }
        catch { if current, generation == readGeneration { loaded = true; scope.error = error.localizedDescription } }
    }

    func prepare(_ file: PhoneTaskFile) async -> URL? {
        guard current, preparing == nil else { return nil }
        preparing = file.id; scope.error = nil
        defer { preparing = nil }
        do {
            let path = try await AttachmentDownload.path(core: scope.store.core, source: file.source(group: scope.workspace.groupID), name: file.name)
            guard current, !Task.isCancelled else { return nil }
            return scope.store.downloadedFile(path)
        } catch is CancellationError { return nil }
        catch { if current { scope.error = error.localizedDescription }; return nil }
    }

    func attach(_ file: PhoneTaskFile) async -> Bool {
        guard current, !scope.busy, !attaching else { return false }
        attaching = true
        defer { attaching = false }
        do {
            _ = try await pane.call("attachConversationFiles", ["files": [["conversationId": file.conversation,
                "messageId": file.message, "index": file.index, "name": file.name, "size": file.size]]])
            return current && !Task.isCancelled
        } catch is CancellationError { return false }
        catch { if current { scope.error = error.localizedDescription }; return false }
    }
}
