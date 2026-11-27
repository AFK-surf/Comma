import Foundation
import Observation
import os
import CommaCore

struct PhoneDriveFile: Identifiable {
    let id: String
    let name: String
    let folder: String
    let folderSegments: [String]
    let space: String
    let size: Int
    let system: CoreJSON
    let writable: Bool
    init?(_ json: NSDictionary) {
        guard let id = json.string("id"), let name = json.string("name"), let space = json.string("spaceId") else { return nil }
        let folder = json.string("folderPath") ?? ""
        self.id = id; self.name = name; self.space = space; self.folder = folder
        self.folderSegments = folder.split(separator: "/").map(String.init)
        size = json.int("sizeBytes") ?? 0; system = CoreJSON(value: json.object("system")); writable = json.bool("writable")
    }

    var isImage: Bool {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "svg": true
        default: false
        }
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
        case PhoneDriveModel.systemFilesSpaceID: self.name = name.isEmpty ? String(localized: "System Files") : name
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

struct PhoneDriveSearchResult: Identifiable {
    let file: PhoneDriveFile
    /// Relative folder path under the searched directory, joined with " / ", or empty if directly inside it.
    let relativeFolder: String

    var id: String { file.id }
}

/// A local index of the shared Core catalog. Folder navigation reads one directory and renders at most 100 rows.
@MainActor @Observable final class PhoneDriveModel {
    static let systemFilesSpaceID = "comma-system-files"

    let feed: WorkspaceTopic
    var scope: WorkspaceSettingsScope { feed.scope }
    private(set) var spaces: [PhoneDriveSpace] = []
    private(set) var selectedSpaceID = ""
    private(set) var folderPath: [String] = []
    private(set) var catalogVersion = 0

    private struct Directory: Hashable { let space: String; let path: String }
    private struct SearchKey: Hashable { let spaceID: String; let path: [String]; let query: String }
    private var filesBySpace: [String: [PhoneDriveFile]] = [:]
    private var directories: [Directory: [PhoneDriveEntry]] = [:]
    @ObservationIgnored private var searchCache: [SearchKey: [PhoneDriveSearchResult]] = [:]
    @ObservationIgnored private let followState = OSAllocatedUnfairLock<(id: UUID, task: Task<Void, Never>)?>(initialState: nil)
    private let pageSize = 100

    init(store: CommaStore, workspace: Workspace) { feed = WorkspaceTopic(store: store, workspace: workspace, topic: "drive") }

    deinit {
        followState.withLock { state in
            state?.task.cancel()
            state = nil
        }
    }

    var selectedSpace: PhoneDriveSpace? { spaces.first { $0.id == selectedSpaceID } }

    func follow() async { await feed.follow { [weak self] in self?.update($0) } }

    /// Owns one `drive` subscription across the entire folder navigation stack.
    /// Pushed folders keep receiving live updates and pull-to-refresh results without re-subscribing.
    func startFollowing() {
        guard scope.current else { return }
        let alreadyRunning = followState.withLock { state in
            if let state, !state.task.isCancelled { return true }
            return false
        }
        guard !alreadyRunning else { return }
        let id = UUID()
        let feed = self.feed
        let task = Task { [weak self] in
            await feed.follow { [weak self] value in
                self?.update(value)
            }
            self?.followState.withLock { state in
                if state?.id == id { state = nil }
            }
        }
        followState.withLock { $0 = (id, task) }
    }

    func stopFollowing() {
        followState.withLock { state in
            state?.task.cancel()
            state = nil
        }
    }

    func selectSpace(_ id: String) {
        guard scope.current, id != selectedSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        selectedSpaceID = id
        folderPath = []
    }

    func openFolder(_ name: String) {
        openFolder(name, in: selectedSpaceID, from: folderPath)
    }

    func openFolder(_ name: String, in spaceID: String, from path: [String]) {
        guard scope.current, spaceID == selectedSpaceID else { return }
        let nextPath = path + [name]
        guard directoryExists(in: spaceID, path: nextPath) else { return }
        folderPath = nextPath
    }

    func popFolder(toDepth depth: Int) {
        let clamped = min(max(0, depth), folderPath.count)
        if clamped < folderPath.count {
            folderPath = Array(folderPath.prefix(clamped))
        }
    }

    func directoryExists(in spaceID: String, path: [String]) -> Bool {
        guard spaces.contains(where: { $0.id == spaceID }) else { return false }
        if path.isEmpty { return true }
        return directories[Directory(space: spaceID, path: path.joined(separator: "/"))] != nil
    }

    func entryCount(in spaceID: String, path: [String]) -> Int {
        allEntries(in: spaceID, path: path).count
    }

    func pageCount(in spaceID: String, path: [String]) -> Int {
        let total = entryCount(in: spaceID, path: path)
        return max(1, (total + pageSize - 1) / pageSize)
    }

    static func clampedPage(_ page: Int, pageCount: Int) -> Int {
        min(max(0, page), max(0, pageCount - 1))
    }

    /// Prefills only memory directories accepted by `SalixAgent.Tools.Memory.allowed_write_path?/1`
    /// (`/memory/scoped/...` or `/memory/episodes/`); top-level `/memory/` defaults to `/memory/scoped/`.
    static func initialMemoryPath(for folderPath: [String]) -> String {
        if folderPath == ["memory", "episodes"] { return "/memory/episodes/" }
        if folderPath.count >= 2, folderPath[0] == "memory", folderPath[1] == "scoped" {
            return "/" + folderPath.joined(separator: "/") + "/"
        }
        return "/memory/scoped/"
    }

    func entries(in spaceID: String, path: [String], page: Int = 0) -> [PhoneDriveEntry] {
        let rows = allEntries(in: spaceID, path: path)
        let pages = max(1, (rows.count + pageSize - 1) / pageSize)
        let clamped = Self.clampedPage(page, pageCount: pages)
        return Array(rows.dropFirst(clamped * pageSize).prefix(pageSize))
    }

    func searchFiles(in spaceID: String, under path: [String] = [], query: String,
                     page: Int = 0) -> (results: [PhoneDriveSearchResult], total: Int, pageCount: Int) {
        // Read the observed catalog version so SwiftUI invalidates search views when the catalog updates.
        _ = catalogVersion
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 0, 1) }
        let key = SearchKey(spaceID: spaceID, path: path, query: trimmed)
        let matched: [PhoneDriveSearchResult]
        if let cached = searchCache[key] {
            matched = cached
        } else {
            let computed = (filesBySpace[spaceID] ?? []).compactMap { file -> PhoneDriveSearchResult? in
                guard file.folderSegments.starts(with: path) else { return nil }
                let relativeSegments = Array(file.folderSegments.dropFirst(path.count))
                let relativePath = relativeSegments.joined(separator: "/")
                let haystack = relativePath.isEmpty ? file.name : relativePath + "/" + file.name
                guard haystack.localizedStandardContains(trimmed) else { return nil }
                return PhoneDriveSearchResult(file: file, relativeFolder: relativeSegments.joined(separator: " / "))
            }.sorted { lhs, rhs in
                let nameOrder = lhs.file.name.localizedStandardCompare(rhs.file.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.relativeFolder.localizedStandardCompare(rhs.relativeFolder) == .orderedAscending
            }
            if searchCache.count >= 16 { searchCache.removeAll(keepingCapacity: true) }
            searchCache[key] = computed
            matched = computed
        }
        let total = matched.count
        let pages = max(1, (total + pageSize - 1) / pageSize)
        let clamped = Self.clampedPage(page, pageCount: pages)
        return (Array(matched.dropFirst(clamped * pageSize).prefix(pageSize)), total, pages)
    }

    private func allEntries(in spaceID: String, path: [String]) -> [PhoneDriveEntry] {
        directories[Directory(space: spaceID, path: path.joined(separator: "/"))] ?? []
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
        searchCache.removeAll(keepingCapacity: true)
        catalogVersion &+= 1
        if !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first { ![Self.systemFilesSpaceID, "comma-task-files"].contains($0.id) }?.id ?? spaces.first?.id ?? ""
            folderPath = []
        }
        // A removed directory returns to its nearest surviving parent. Empty spaces keep their root.
        while !folderPath.isEmpty, !directoryExists(in: selectedSpaceID, path: folderPath) {
            folderPath.removeLast()
        }
    }

    private static func index(_ files: [PhoneDriveFile]) -> [Directory: [PhoneDriveEntry]] {
        var folders: [Directory: Set<String>] = [:], documents: [Directory: [PhoneDriveEntry]] = [:]
        for file in files {
            var parent = ""
            for name in file.folderSegments {
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
    var path: String
    var text = ""
    private(set) var saved: String?
    private(set) var hash: String?
    private(set) var loaded = false
    private(set) var preview: URL?
    private(set) var mediaType = "text/plain"
    private var bytes: Data?

    init(scope: WorkspaceSettingsScope, file: PhoneDriveFile? = nil, initialPath: String = "/memory/scoped/") {
        self.scope = scope
        self.file = file
        self.path = initialPath
    }
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
