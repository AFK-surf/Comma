import Foundation
import Observation
import CommaCore

struct PhoneDriveFile: Identifiable {
    let id: String
    let name: String
    let folder: String
    let space: String
    let size: Int
    let system: CoreJSON
    let writable: Bool
    init?(_ json: NSDictionary) {
        guard let id = json.string("id"), let name = json.string("name"), let space = json.string("spaceId") else { return nil }
        self.id = id; self.name = name; self.space = space; folder = json.string("folderPath") ?? ""
        size = json.int("sizeBytes") ?? 0; system = CoreJSON(value: json.object("system")); writable = json.bool("writable")
    }
}

struct PhoneDriveSpace: Identifiable {
    let id: String
    let name: String

    init?(_ json: NSDictionary) {
        guard let id = json.string("id") else { return nil }
        self.id = id
        let name = json.string("name") ?? ""
        switch id {
        case "comma-system-files": self.name = name.isEmpty ? String(localized: "System Files") : name
        case "comma-task-files": self.name = name.isEmpty ? String(localized: "Task Files") : name
        default: self.name = name.isEmpty ? id : name
        }
    }
}

enum PhoneDriveEntry: Identifiable {
    case folder(String)
    case file(PhoneDriveFile)

    var name: String {
        switch self { case .folder(let name): name; case .file(let file): file.name }
    }
    var id: String {
        switch self { case .folder(let name): "folder:\(name)"; case .file(let file): "file:\(file.id)" }
    }
}

/// A local index of the shared Core catalog. Folder navigation reads one directory and renders at most 100 rows.
@MainActor @Observable final class PhoneDriveModel {
    let feed: WorkspaceTopic
    var scope: WorkspaceSettingsScope { feed.scope }
    private(set) var spaces: [PhoneDriveSpace] = []
    private(set) var selectedSpaceID = ""
    private(set) var folderPath: [String] = []
    private(set) var entries: [PhoneDriveEntry] = []
    private(set) var page = 0
    private(set) var entryCount = 0
    var query = "" {
        didSet { if query != oldValue { rebuildSearch(); page = 0; showDirectory() } }
    }

    private struct Directory: Hashable { let space: String; let path: String }
    private var filesBySpace: [String: [PhoneDriveFile]] = [:]
    private var directories: [Directory: [PhoneDriveEntry]] = [:]
    private var searchDirectories: [Directory: [PhoneDriveEntry]] = [:]
    private let pageSize = 100

    init(store: CommaStore, workspace: Workspace) { feed = WorkspaceTopic(store: store, workspace: workspace, topic: "drive") }
    var selectedSpace: PhoneDriveSpace? { spaces.first { $0.id == selectedSpaceID } }
    var pageCount: Int { max(1, (entryCount + pageSize - 1) / pageSize) }

    func follow() async { await feed.follow { [weak self] in self?.update($0) } }

    func selectSpace(_ id: String) {
        guard scope.current, id != selectedSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id; folderPath = []; page = 0; query = ""
        showDirectory()
    }

    func openFolder(_ name: String) {
        guard scope.current, entries.contains(where: { if case .folder(let folder) = $0 { return folder == name }; return false }) else { return }
        folderPath.append(name); page = 0; showDirectory()
    }

    func navigate(to depth: Int) {
        guard scope.current, depth >= 0, depth < folderPath.count else { return }
        folderPath = Array(folderPath.prefix(depth)); page = 0; showDirectory()
    }

    func movePage(by delta: Int) {
        guard scope.current else { return }
        page = min(max(0, page + delta), pageCount - 1); showDirectory()
    }

    private func update(_ value: CoreJSON) {
        spaces = (value.object?.objects("spaces") ?? []).compactMap(PhoneDriveSpace.init)
        let files = (value.object?.objects("files") ?? []).compactMap(PhoneDriveFile.init).filter {
            guard let system = $0.system.object else { return true }
            return (system.string("group") == nil || system.string("group") == scope.workspace.groupID) &&
                (system.string("workspace") == nil || system.string("workspace") == scope.workspace.id)
        }
        filesBySpace = Dictionary(grouping: files, by: \.space)
        directories = Self.index(files)
        if !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first { !["comma-system-files", "comma-task-files"].contains($0.id) }?.id ?? spaces.first?.id ?? ""
            folderPath = []; page = 0; query = ""
        }
        // A removed directory returns to its nearest surviving parent. Empty spaces keep their root.
        while !folderPath.isEmpty, directories[Directory(space: selectedSpaceID, path: folderPath.joined(separator: "/"))] == nil {
            folderPath.removeLast(); page = 0
        }
        rebuildSearch(); showDirectory()
    }

    private func rebuildSearch() {
        guard !query.isEmpty else { searchDirectories = [:]; return }
        let files = (filesBySpace[selectedSpaceID] ?? []).filter { ($0.folder + "/" + $0.name).localizedStandardContains(query) }
        searchDirectories = Self.index(files)
    }

    private func showDirectory() {
        let key = Directory(space: selectedSpaceID, path: folderPath.joined(separator: "/"))
        let rows = (query.isEmpty ? directories[key] : searchDirectories[key]) ?? []
        entryCount = rows.count
        page = min(page, pageCount - 1)
        entries = Array(rows.dropFirst(page * pageSize).prefix(pageSize))
    }

    private static func index(_ files: [PhoneDriveFile]) -> [Directory: [PhoneDriveEntry]] {
        var folders: [Directory: Set<String>] = [:], documents: [Directory: [PhoneDriveEntry]] = [:]
        for file in files {
            let path = file.folder.split(separator: "/").map(String.init)
            var parent = ""
            for name in path {
                let key = Directory(space: file.space, path: parent)
                folders[key, default: []].insert(name)
                parent = parent.isEmpty ? name : parent + "/" + name
            }
            documents[Directory(space: file.space, path: parent), default: []].append(.file(file))
        }
        var result: [Directory: [PhoneDriveEntry]] = [:]
        for key in Set(folders.keys).union(documents.keys) {
            let children = (folders[key] ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(PhoneDriveEntry.folder)
            let files = (documents[key] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            result[key] = children + files
        }
        return result
    }
    func refresh() async { _ = await scope.perform("drive.refresh", workspaceParameter: false) }
}

@MainActor @Observable final class PhoneDriveDocument {
    let scope: WorkspaceSettingsScope
    let file: PhoneDriveFile?
    var path = "/memory/scoped/"
    var text = ""
    private(set) var saved: String?
    private(set) var hash: String?
    private(set) var loaded = false
    private(set) var preview: URL?
    private(set) var mediaType = "text/plain"
    private var bytes: Data?

    init(scope: WorkspaceSettingsScope, file: PhoneDriveFile? = nil) { self.scope = scope; self.file = file }
    var editable: Bool { file == nil || file?.writable == true && ["vfs", "instructions"].contains(file?.system.object?.string("kind") ?? "") }

    func load() async {
        guard let file else { saved = ""; loaded = true; return }
        do {
            let system = file.system.object
            switch system?.string("kind") {
            case "vfs":
                path = system?.string("path") ?? ""
                let answer = try await scope.call("systemFiles.read", ["group": scope.workspace.groupID, "path": path], workspaceParameter: false)
                text = answer.object?.text("content") ?? ""; hash = answer.object?.string("hash"); bytes = Data(text.utf8)
            case "instructions":
                let answer = try await scope.call("systemFiles.instructions", ["group": scope.workspace.groupID], workspaceParameter: false)
                text = answer.object?.text("content") ?? ""; hash = answer.object?.string("hash"); bytes = Data(text.utf8)
            case "skill":
                guard let skill = system?.string("skill") else { return }
                let answer = try await scope.call("skills.detail", ["skill": skill])
                text = answer.object?.text("content") ?? ""; bytes = Data(text.utf8)
            default:
                let answer = try await scope.call("drive.read", ["file": file.id], workspaceParameter: false)
                guard let data = CoreBytes.read(answer.object?["bytes"]), data.count <= 10 * 1024 * 1024 else {
                    throw CoreError(code: "too_large", message: String(localized: "This file is too large to preview here."))
                }
                bytes = data; mediaType = answer.object?.string("mediaType") ?? "application/octet-stream"
                if mediaType.hasPrefix("text/") { text = String(data: data, encoding: .utf8) ?? "" }
            }
            guard scope.current else { return }
            saved = text; loaded = true; scope.error = nil
            if let bytes { preview = try Self.keep(bytes, name: file.name) }
        } catch is CancellationError { }
        catch { if scope.current { scope.error = error.localizedDescription } }
    }

    func save() async -> Bool {
        guard editable, loaded else { return false }
        var params: [String: Any] = ["group": scope.workspace.groupID, "content": text]
        if let hash { params["expectedHash"] = hash }
        let instructions = file?.system.object?.string("kind") == "instructions"
        if !instructions { params["path"] = path }
        guard let answer = await scope.perform(instructions ? "systemFiles.writeInstructions" : "systemFiles.write", params, workspaceParameter: false) else { return false }
        hash = answer.object?.string("hash"); saved = text; bytes = Data(text.utf8)
        preview = try? Self.keep(Data(text.utf8), name: file?.name ?? URL(fileURLWithPath: path).lastPathComponent)
        return true
    }

    func attach(to target: ConversationPane?) async -> Bool {
        guard loaded, let bytes, let pane = target, scope.current, pane.attachmentRoom > 0 else { return false }
        let file = AttachmentPayload(filename: file?.name ?? URL(fileURLWithPath: path).lastPathComponent, contentType: mediaType, data: bytes)
        await pane.attach(file, thumbnail: nil).value
        return scope.current && !pane.closed
    }

    private static func keep(_ bytes: Data, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drive-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        let url = folder.appendingPathComponent(safeName.isEmpty ? "file" : safeName)
        try bytes.write(to: url, options: .atomic)
        return url
    }
}
