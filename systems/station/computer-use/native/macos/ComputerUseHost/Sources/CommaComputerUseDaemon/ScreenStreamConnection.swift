import CUShared
import CUStream
import CoreGraphics
import Darwin
import Foundation

/// Serves one screen view on a daemon socket connection: after the request line the connection carries ScreenView's
/// messages (CUStream/ScreenView.swift, still.fail's) both ways until either side closes it.
///
/// A view of the display or an app's windows first checks Screen Recording, as still.fail's Daemon.swift `screen.view`
/// does: granted since this process started (macOS gives a running process a grant only once it starts again), it says
/// so (`code: "restart"`) and the daemon ends, for the station to start it again (helper.ts); not granted at all, it
/// says that (`code: "capture"`).
@available(macOS 14.0, *)
final class ScreenStreamConnection: @unchecked Sendable {
    private let socket: Int32

    init(socket: Int32) {
        self.socket = socket
    }

    /// Runs the view until the client closes the connection or capture ends. `restart` ends this process.
    func run(options: [String: Any], restart: () -> Void) {
        var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let channel = ScreenChannel(fd: socket)
        if (options["target"] as? String) != "simulator", !CGPreflightScreenCaptureAccess() {
            let granted = PermissionStatusProbe.fresh(.screenRecording) ?? false
            // Gone from the socket's path before it says so: the station's next connection starts another.
            if granted { restart() }
            channel.sendJSON(1, [
                "error": granted ? "restarting to take Screen Recording" : "Screen Recording is not granted",
                "code": granted ? "restart" : "capture",
                "capture": granted,
            ])
            return
        }
        makeScreenView(channel: channel, json: options).run()
    }
}
