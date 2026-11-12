// The Mac's clipboard for a view a person drives (station/src/screens/screen-pipe.ts, ScreenView.swift's messages 4 and
// 5): set from the viewer and pasted with ⌘V, watched while the view asks (its changeCount looked at every half a second,
// on the main queue, nothing else read until it changes). Text first, else a picture as PNG (from PNG or TIFF), each
// within its bound; what this view set itself is not said back to it, nor what was said last (a viewer on a device of
// the same Apple Account puts what it was told on its own clipboard, which Universal Clipboard brings back here as a
// change: said again, it would go round for good).
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 3d517e022e) station/native/helper/Sources/
// StillfailHelper/Clipboard.swift: `set`, `watch`, `stop`, `look`, `say`, as they are. What differs: the pasteboard is
// given (NSPasteboard.general in the daemon; a private named one in the tests, which never touch the person's), the
// set and the paste go on the view's own queue after the input before it (Cue's views post input there, not on
// still.fail's ScreenInput queue), the paste is the view's (`paste`: an app's view sends ⌘V to its windows), and
// still.fail's reveal (message 6) is not ported.
import AppKit
import Foundation

final class ScreenClipboard: @unchecked Sendable {
    /// What a view carries each way at most (@comma/mesh screen-wire.ts CLIP_TEXT_MAX, CLIP_PNG_MAX).
    static let textMax = 1024 * 1024
    static let pngMax = 8 * 1024 * 1024
    /// How often the changeCount is looked at while watched.
    static let interval: TimeInterval = 0.5

    let channel: ScreenChannel
    let board: NSPasteboard
    /// The view's queue: its input goes there, and a set goes after the input before it.
    let queue: DispatchQueue
    /// ⌘V where the focus is, on `queue`.
    let paste: () -> Void
    /// What looks at it while watched (on the main queue).
    private(set) var timer: DispatchSourceTimer?
    /// The changeCount last seen (or set here): a change after it is a copy made on the Mac.
    private var seen = 0
    /// What was last said or set (its type, its bytes): the same again is no copy made on the Mac.
    private var last: Data?

    init(channel: ScreenChannel, board: NSPasteboard = .general, queue: DispatchQueue, paste: @escaping () -> Void) {
        self.channel = channel
        self.board = board
        self.queue = queue
        self.paste = paste
    }

    /// Message 4: flags (bit 0: paste), type (1 text, 2 PNG), the bytes. Set after the input before it, on its queue,
    /// then ⌘V where the focus is.
    func set(_ payload: Data) {
        guard payload.count >= 3 else { return }
        let bytes = [UInt8](payload)
        let paste = bytes[0] & 1 == 1
        let type = bytes[1]
        let body = payload.subdata(in: payload.startIndex + 2..<payload.endIndex)
        queue.async {
            let done = DispatchQueue.main.sync { () -> Bool in
                switch type {
                case 1:
                    guard body.count <= ScreenClipboard.textMax, let text = String(data: body, encoding: .utf8) else { return false }
                    self.board.clearContents()
                    self.board.setString(text, forType: .string)
                case 2:
                    guard body.count <= ScreenClipboard.pngMax, let image = NSBitmapImageRep(data: body) else { return false }
                    self.board.clearContents()
                    self.board.setData(body, forType: .png)
                    // Apps that read only TIFF (older ones) find it too.
                    if let tiff = image.tiffRepresentation { self.board.setData(tiff, forType: .tiff) }
                default:
                    return false
                }
                self.seen = self.board.changeCount
                self.last = Data([type]) + body
                return true
            }
            if done && paste { self.paste() }
        }
    }

    /// Message 5: watched (1) or not (0).
    func watch(_ payload: Data) {
        let on = payload.first == 1
        DispatchQueue.main.async {
            self.timer?.cancel()
            self.timer = nil
            guard on else { return }
            // What it holds now is not a copy made while watched.
            self.seen = self.board.changeCount
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + ScreenClipboard.interval, repeating: ScreenClipboard.interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.look() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// The clipboard changed since last seen: what it holds now, said as message 5 (type, bytes). On the main queue.
    func look() {
        let count = board.changeCount
        guard count != seen else { return }
        seen = count
        if let text = board.string(forType: .string), !text.isEmpty {
            let data = Data(text.utf8)
            if data.count <= ScreenClipboard.textMax { say(Data([1]) + data) }
            return
        }
        var png = board.data(forType: .png)
        if png == nil, let tiff = board.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) {
            png = image.representation(using: .png, properties: [:])
        }
        if let png, !png.isEmpty, png.count <= ScreenClipboard.pngMax { say(Data([2]) + png) }
    }

    /// Message 5 (type, bytes), unless it is what was last said or set.
    private func say(_ what: Data) {
        guard what != last else { return }
        last = what
        channel.send(5, what)
    }
}
