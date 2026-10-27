import Foundation

/**
 * Files a pick left with the app, which a product request's body can be (`localFileRef` in the core's phone host), as
 * Android's `HostLocalFiles` are: the core names one by its `lfi1_` ref, and the app sends it from disk as it reads
 * it, so a large file is never held whole. A picked file is copied into `root` first (coordinated, so a file still on
 * its way from iCloud arrives whole): the picker's access to it ends with the pick. Copies left by an earlier run are
 * removed when this starts.
 */
final class HostLocalFiles: @unchecked Sendable {
    struct File: Sendable {
        let url: URL
        let size: Int64
    }

    /// The most the server takes of one file.
    static let maxSize: Int64 = 512 * 1024 * 1024

    private let root: URL
    private let lock = NSLock()
    private var files: [String: File] = [:]

    init(root: URL) {
        self.root = root
        try? FileManager.default.removeItem(at: root)
    }

    /// The file `ref` names, or nil when the app holds none by that name.
    func file(_ ref: String) -> File? { lock.withLock { files[ref] } }

    /// `length` bytes of the file `ref` names from `offset`, fewer only where it ends; nil when the app holds none by
    /// that name.
    func read(_ ref: String, offset: UInt64, length: Int) throws -> Data? {
        guard let file = file(ref) else { return nil }
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }

    /**
     * Keeps a copy of the picked file `url` under a new ref: the ref, the file's name and its size. Nil when it is not
     * a regular file the server takes.
     */
    @concurrent func keep(_ url: URL) async throws -> (ref: String, name: String, size: Int64)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize.map(Int64.init), size <= Self.maxSize else {
            return nil
        }
        let ref = Self.newRef()
        let directory = root.appendingPathComponent(ref, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(url.lastPathComponent)
        var copied: Result<Void, any Error> = .failure(CocoaError(.fileReadUnknown))
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { url in
            copied = Result { try FileManager.default.copyItem(at: url, to: copy) }
        }
        if let coordination { throw coordination }
        try copied.get()
        let kept = Int64(try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        lock.withLock { files[ref] = File(url: copy, size: kept) }
        return (ref, url.lastPathComponent, kept)
    }

    /// The app no longer needs the file `ref` names (its draft row was removed).
    func release(_ ref: String) {
        guard let file = lock.withLock({ files.removeValue(forKey: ref) }) else { return }
        try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
    }

    /// `lfi1_` and 43 URL-safe base64 characters: 32 random bytes, as the core's schema takes.
    private static func newRef() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let encoded = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "lfi1_" + encoded
    }
}
