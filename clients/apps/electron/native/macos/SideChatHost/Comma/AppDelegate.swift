import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: EdgeChatController?
    private var commandServer: SideChatCommandServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = EdgeChatController()
        self.controller = controller
        controller.start()

        let commandServer = SideChatCommandServer(controller: controller)
        self.commandServer = commandServer
        commandServer.start()
        controller.publishCurrentPresentation()

        if ProcessInfo.processInfo.arguments.contains("--open-on-launch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                controller.open()
            }
        }

        if ProcessInfo.processInfo.arguments.contains("--exit-after-smoke") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandServer?.stop()
        commandServer = nil
        controller?.stop()
        controller = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
