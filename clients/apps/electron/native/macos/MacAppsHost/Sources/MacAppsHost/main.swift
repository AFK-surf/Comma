import Foundation
import MCP
import MacApps

// An MCP server on stdin and stdout for Comma's Main, which starts it and is its
// only client. It exits when Main closes stdin.

let usage = "usage: MacAppsHost [serve]\n"

switch CommandLine.arguments.dropFirst().first ?? "serve" {
case "serve":
    Task.detached {
        let server = Server(
            name: "comma-mac-apps",
            version: "1.0.0",
            title: "Mac apps",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await MacAppsService.live().register(on: server)
        do {
            try await server.start(transport: StdioTransport())
            await server.waitUntilCompleted()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("MacAppsHost: \(error)\n".utf8))
            exit(1)
        }
    }
    // The main run loop serves AppleScript (main thread only) and framework callbacks.
    RunLoop.main.run()
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
