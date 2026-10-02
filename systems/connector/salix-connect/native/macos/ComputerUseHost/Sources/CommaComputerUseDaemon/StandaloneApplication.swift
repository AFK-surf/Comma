import Darwin
import Foundation

enum StandaloneApplication {
    static func isNested(_ app: URL) -> Bool {
        var parent = app.resolvingSymlinksInPath().deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "app" { return true }
            parent.deleteLastPathComponent()
        }
        return false
    }

    static func prepare(bundle: Bundle = .main) throws -> URL {
        let source = bundle.bundleURL.resolvingSymlinksInPath()
        guard isNested(source) else { return source }
        guard let identifier = bundle.bundleIdentifier else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("Comma Computer Use")
            .appendingPathComponent(identifier)
        return try install(source: source, directory: directory)
    }

    // The installed bundle is a copy of shipped code, with no user data.
    // Keep its path stable and preserve the shipped code signature.
    static func install(source: URL, directory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(.EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(lock, LOCK_UN) }

        let destination = directory.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        // These comparisons only avoid recopying an unchanged signed bundle.
        // They do not authenticate code or grant permissions.
        let codeFiles = [
            "Contents/MacOS/CommaComputerUseDaemon",
            "Contents/Info.plist",
            "Contents/_CodeSignature/CodeResources",
        ]
        if codeFiles.allSatisfy({ relative in
            let original = source.appendingPathComponent(relative).path
            return files.fileExists(atPath: original) && files.contentsEqual(
                atPath: original, andPath: destination.appendingPathComponent(relative).path
            )
        }) {
            return destination
        }

        let staging = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let replacement = staging.appendingPathComponent(source.lastPathComponent)
        try files.copyItem(at: source, to: replacement)
        if files.fileExists(atPath: destination.path) {
            // Exchange complete bundles. A copy failure leaves the old app intact.
            guard renameatx_np(AT_FDCWD, replacement.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try files.moveItem(at: replacement, to: destination)
        }
        return destination
    }
}
