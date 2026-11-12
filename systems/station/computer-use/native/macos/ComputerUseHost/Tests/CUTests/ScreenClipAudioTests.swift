import AppKit
import Darwin
import Foundation
import Testing
@testable import CUStream

// The clipboard and the system output of a screen view (ScreenClipboard.swift, SystemAudio.swift; still.fail's
// Clipboard.swift and SystemAudio.swift). The clipboard's tests use a private named pasteboard: never the person's.

private func pair() -> (ScreenChannel, Int32) {
    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    return (ScreenChannel(fd: fds[0]), fds[1])
}

private func message(_ fd: Int32, within ms: Int32 = 3000) -> (UInt8, Data)? {
    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, ms) > 0 else { return nil }
    return ScreenChannel(fd: fd).message(limit: 1 << 24)
}

/// Once what was put on `queue` before this ran: the main queue (the test's actor) is free meanwhile, for what the
/// clipboard does there.
@MainActor private func drained(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
}

private final class Pastes: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

/// A paste sets the clipboard, then pastes (on the view's queue, after it); a copy made while watched is said, what the
/// view set itself and what was said last are not, and it is no longer looked at once it is not watched.
@Test @MainActor
func theClipboardIsSetPastedAndWatched() async throws {
    let board = NSPasteboard(name: NSPasteboard.Name("comma.test.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    let (channel, station) = pair()
    defer { close(station); close(channel.fd) }
    let pastes = Pastes()
    let queue = DispatchQueue(label: "test.view")
    let clipboard = ScreenClipboard(channel: channel, board: board, queue: queue) { @Sendable in pastes.add() }

    clipboard.set(Data([1, 1]) + Data("粘贴的".utf8))
    await drained(queue)
    #expect(pastes.count == 1)
    #expect(board.string(forType: .string) == "粘贴的")
    // Set without a paste: a picture, with a TIFF beside it.
    let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
    clipboard.set(Data([0, 2]) + png)
    await drained(queue)
    #expect(board.data(forType: .png) == png)
    #expect(board.data(forType: .tiff) != nil)
    #expect(pastes.count == 1)
    // Neither text of no UTF-8 nor no type sets anything.
    clipboard.set(Data([1, 9, 0x41]))
    clipboard.set(Data([1, 1, 0xff, 0xfe]))
    await drained(queue)
    #expect(board.data(forType: .png) == png)

    clipboard.watch(Data([1]))
    await drained(.main)
    #expect(clipboard.timer != nil)
    // What the view set is not said back (what is said is written at once).
    clipboard.look()
    #expect(message(station, within: 0) == nil)
    // A copy made on the Mac is.
    board.clearContents()
    board.setString("复制的", forType: .string)
    clipboard.look()
    let said = try #require(message(station))
    #expect(said.0 == 5)
    #expect(said.1 == Data([1]) + Data("复制的".utf8))
    // The same again (Universal Clipboard bringing it back) is not.
    board.clearContents()
    board.setString("复制的", forType: .string)
    clipboard.look()
    #expect(message(station, within: 0) == nil)
    // No longer watched: nothing looks at it.
    clipboard.watch(Data([0]))
    await drained(.main)
    #expect(clipboard.timer == nil)
}

/// Sound as it comes, made into packets of exactly 20 ms each stamped with its first frame's capture time; a gap starts
/// a packet of its own (the part before it dropped); at most 300 ms kept, the oldest dropped first.
@Test
func soundIsMadeIntoTwentyMillisecondPackets() {
    var packets = AudioPackets()
    // 1.5 packets, then the rest of the second following on: two packets.
    packets.add([Int16](repeating: 1, count: 960 * 3), at: 1_000_000)
    #expect(packets.queued.count == 1)
    packets.add([Int16](repeating: 2, count: 480 * 2), at: 1_030_000)
    #expect(packets.queued.map(\.0) == [1_000_000, 1_020_000])
    #expect(packets.queued.allSatisfy { $0.1.count == AudioPackets.bytes })
    // Half a packet, then a gap (nothing played): the half is dropped, the next starts at its own time.
    packets.add([Int16](repeating: 3, count: 480 * 2), at: 1_040_000)
    packets.add([Int16](repeating: 4, count: 960 * 2), at: 2_000_000)
    #expect(packets.queued.map(\.0) == [1_000_000, 1_020_000, 2_000_000])
    #expect(packets.pop()?.0 == 1_000_000)
    // A slow transport: only the newest 15 kept.
    for n in 0..<20 { packets.add([Int16](repeating: 5, count: 960 * 2), at: 2_020_000 + Int64(n) * 20_000) }
    #expect(packets.queued.count == AudioPackets.kept)
    #expect(packets.queued.first?.0 == Int64(2_120_000))
}

/// Float or 16-bit samples, interleaved or planar, made interleaved stereo PCM16; one channel given to both sides.
@Test
func samplesAreInterleavedStereo() {
    let left: [Float32] = [0.5, -1.5], right: [Float32] = [-0.5, 1]
    let planar = left.withUnsafeBytes { l in right.withUnsafeBytes { r in SystemAudio.interleave([l, r], frames: 2, channels: 2, planar: true, float: true) } }
    #expect(planar == [16384, -16384, -32767, 32767])
    let mono: [Int16] = [7, -8]
    let both = mono.withUnsafeBytes { SystemAudio.interleave([$0], frames: 2, channels: 1, planar: false, float: false) }
    #expect(both == [7, 7, -8, -8])
}

/// A view that asks Opus gets one Opus packet for each 20 ms of PCM, a small part of its size, and is told so first.
@Test
func opusPacketsComeOneForEachPacketOfSound() throws {
    let (channel, other) = pair()
    defer { close(other) }
    let audio = SystemAudio(channel: channel, opus: true)
    audio.said()
    let (kind, config) = try #require(message(other))
    #expect(kind == 8)
    #expect(String(data: config, encoding: .utf8)?.contains("\"opus\"") == true)
    for n in 0..<3 {
        let tone = (0..<(AudioPackets.frames * 2)).map { Int16(sin(Double(n * AudioPackets.frames + $0 / 2) * 2 * .pi * 440 / 48_000) * 8000) }
        audio.tapped(tone, at: 1_000_000 + Int64(n) * 20_000)
        audio.next()
        let (kind, packet) = try #require(message(other))
        #expect(kind == 9)
        // 8 bytes of time, then one Opus packet: a few hundred bytes at most, never PCM's 3840.
        #expect(packet.count > 8 && packet.count <= 8 + 1275)
    }
}

private struct App: SoundApp, Equatable {
    let bundleIdentifier: String
}

/// A display's view hears every app but the Comma apps (any channel, a source build, this helper), so a screen's sound
/// that Comma plays back is not sent back to that screen; an app's view hears its apps, never a Comma app among them.
@Test
func aViewDoesNotHearTheCommaApps() throws {
    let running = [
        "com.apple.Music", "surf.comma.desktop", "surf.comma.desktop.staging", "surf.comma.desktop.dev",
        "surf.comma.desktop.dev.source-wt", "surf.comma.desktop.dev.computer-use", "surf.comma.desktopper",
        "com.google.Chrome",
    ].map(App.init)
    guard case let .allBut(left) = ScreenStreamSession.soundApps(of: .display(nil), viewed: [], running: running) else {
        Issue.record("a display hears every app but some")
        return
    }
    #expect(left.map(\.bundleIdentifier) == [
        "surf.comma.desktop", "surf.comma.desktop.staging", "surf.comma.desktop.dev", "surf.comma.desktop.dev.source-wt",
        "surf.comma.desktop.dev.computer-use",
    ])
    let viewed = [App(bundleIdentifier: "com.apple.Music"), App(bundleIdentifier: "surf.comma.desktop.dev")]
    guard case let .only(heard) = ScreenStreamSession.soundApps(of: .apps(["Music", "Comma Dev"]), viewed: viewed, running: running) else {
        Issue.record("an app's view hears only its apps")
        return
    }
    #expect(heard == [App(bundleIdentifier: "com.apple.Music")])
    // The sound-only stream asks no picture worth the name, and never the microphone or this helper's own sound.
    let config = ScreenStreamSession.soundConfiguration()
    #expect(config.capturesAudio && config.excludesCurrentProcessAudio && config.width == 2 && config.sampleRate == 48_000)
}

/// A display's process tap leaves out every Comma process by its bundle identifier (the app, its Electron helpers with
/// Chromium's audio service, a source build, this helper) and this helper's own process, and no other app.
@Test
func theTapLeavesOutTheCommaProcesses() {
    let processes = [
        AudioProcess(object: 70, pid: 10, bundleIdentifier: "com.apple.Music"),
        AudioProcess(object: 71, pid: 11, bundleIdentifier: "surf.comma.desktop"),
        AudioProcess(object: 72, pid: 12, bundleIdentifier: "surf.comma.desktop.helper"),
        AudioProcess(object: 73, pid: 13, bundleIdentifier: "surf.comma.desktop.dev.helper"),
        AudioProcess(object: 74, pid: 14, bundleIdentifier: "surf.comma.desktop.dev.source-wt"),
        AudioProcess(object: 75, pid: 15, bundleIdentifier: "surf.comma.desktopper"),
        AudioProcess(object: 76, pid: 16, bundleIdentifier: ""),
        AudioProcess(object: 77, pid: 99, bundleIdentifier: "surf.comma.salix-connect.computer-use"),
    ]
    #expect(AudioProcess.leftOut(processes, own: 99).map(\.object) == [71, 72, 73, 74, 77])
}
