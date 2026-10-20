import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var commandServer: StatusMenuCommandServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let commandServer = StatusMenuCommandServer()
        self.commandServer = commandServer
        commandServer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandServer?.stop()
        commandServer = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
