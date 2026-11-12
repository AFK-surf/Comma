// An app's windows or a whole display as a screen view (station/src/screens/helper.ts opens it): ScreenCaptureKit
// captures it scaled into the view's bounds, and ScreenView (still.fail's ScreenView.swift, ported) encodes a picture
// when the station asks for one. Input goes as RemoteInputInjector says.
//
// Cue's own beside still.fail's whole display: an app's view captures only those apps' windows (a display filter that
// includes only them, so another app's window never shows even where it covers them), the rectangle following the union
// of their windows (said as message 64, `target`), a background where the picture has no window, a display chosen by
// its index, and the pointer in the pictures unless the station draws it (`cursor`: message 6).
//
// As still.fail's desktop view (its ScreenView.swift `run` and `start`): a view that drives carries the clipboard both
// ways (ScreenClipboard.swift), and a view asked `audio: true` the system output (SystemAudio.swift). Cue's own: the
// paste is posted as the view's input is (to an app's windows, or as HID events), and the sound leaves out the Comma
// apps: what Comma plays is mostly another screen's sound, and captured it would go back there (two computers that view
// each other loop). A display's sound comes from a Core Audio process tap without the Comma apps' processes
// (SystemAudioTap.swift); where it cannot start, from a second, sound-only ScreenCaptureKit stream whose filter leaves
// out the Comma apps (`soundApps`), which still hears Chromium's audio service. The picture's filter cannot do either:
// ScreenCaptureKit filters sound by app, and an app whose windows the picture shows is heard. An app's view hears only
// its apps, from the sound-only stream.
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// What a screen stream shows.
public enum ScreenStreamTarget: Sendable {
    /// Only the windows of these apps. An empty list selects the frontmost app.
    case apps([String])
    /// A whole display, selected by its 1-based index. `nil` selects the main display.
    case display(Int?)
}

/// The view a request asks for: an iOS Simulator, or an app's windows or a display.
public func makeScreenView(channel: ScreenChannel, json: [String: Any]) -> ScreenView {
    (json["target"] as? String) == "simulator"
        ? SimulatorStreamSession(channel: channel, options: json)
        : ScreenStreamSession(channel: channel, options: json)
}

public final class ScreenStreamSession: ScreenView, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let target: ScreenStreamTarget
    let allowInput: Bool
    /// What shows where the frame has no window: round an app's corners and between its windows.
    let background: CGColor?
    /// The pointer left out of the frames and said apart (message 6): a viewer that draws it asks so (`cursor`). Not
    /// asked, it is in them.
    let reportCursor: Bool
    /// The system output asked too (`audio: true`), and what captures it once it is (never the microphone).
    let audio: Bool
    /// Its packets encoded as Opus (`audioCodec: "opus"`: the viewer decodes it), else PCM16.
    let opus: Bool
    private var sound: SystemAudio?
    /// The sound-only stream, and what updates its filter when a Comma app starts (a display's view).
    private var soundStream: SCStream?
    /// A display's process tap in place of the sound-only stream: what stops it.
    private var stopTap: (() -> Void)?
    private var commaLaunches: NSObjectProtocol?
    /// The Mac's clipboard, for a view that drives (the station sends its messages only while a person does).
    private lazy var clipboard = ScreenClipboard(channel: channel, queue: queue) { [weak self] in self?.injector.paste() }
    private let injector = RemoteInputInjector()
    private var stream: SCStream?
    private var geometryTimer: DispatchSourceTimer?
    private var display: SCDisplay?
    private var pids: Set<pid_t> = []
    private var appNames: [String] = []
    private var hadWindows = false
    /// Captured area in global top-left-origin points. Guarded by `queue`.
    private var captureRect = CGRect.zero
    /// The captured area as the pointer is placed in it, read on the main thread (`followCursor`).
    private let pointerLock = NSLock()
    private var pointerRect = CGRect.zero
    /// Where the pointer is and its shape, looked at 60 times a second on the main thread; the last said.
    private var cursorTimer: DispatchSourceTimer?
    private var cursorSaid: [String: Any] = [:]
    private var cursorTicks = 0
    private var cursorShape = "default"

    public init(channel: ScreenChannel, options json: [String: Any]) {
        let apps = (json["apps"] as? [String] ?? []).filter { !$0.isEmpty }
        let display = (json["display"] as? NSNumber)?.intValue
        target = (json["target"] as? String) == "display" ? .display(display) : .apps(apps)
        allowInput = (json["control"] as? Bool) ?? false
        background = Self.color(hex: json["background"] as? String)
        reportCursor = (json["cursor"] as? Bool) ?? false
        audio = (json["audio"] as? Bool) == true
        opus = (json["audioCodec"] as? String) == "opus"
        super.init(channel: channel, options: json, label: "CommaComputerUse.ScreenStream")
        if case .apps = target {
            injector.windows = WindowInputSink(windows: { [weak self] in
                self.map { Self.inputWindows(of: $0.pids) } ?? []
            })
        }
    }

    var sendsToWindows: Bool { injector.windows != nil }

    /// A `#rrggbb` colour.
    static func color(hex: String?) -> CGColor? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
            return nil
        }
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: capture

    public override func start() {
        // still.fail ScreenView.swift `start`: the display woken and kept on while the view lasts (a display asleep is
        // captured black). The helper's views are never previews (no `peek`: helper.ts).
        wake()
        let started = DispatchSemaphore(value: 0)
        Task {
            defer { started.signal() }
            do {
                try await self.capture()
            } catch let error as ScreenStreamFailure {
                self.channel.sendJSON(1, ["error": error.message, "code": error.code])
            } catch {
                self.channel.sendJSON(1, ["error": error.localizedDescription, "code": "capture", "capture": CGPreflightScreenCaptureAccess()])
            }
        }
        started.wait()
    }

    private func capture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenStreamFailure("Screen Recording is not granted: \(error.localizedDescription)", code: "capture")
        }
        let filter: SCContentFilter
        let display: SCDisplay
        var rect: CGRect
        switch target {
        case let .display(index):
            guard let selected = Self.display(index, in: content.displays) else {
                throw ScreenStreamFailure("Display was not found", code: "display")
            }
            display = selected
            rect = selected.frame
            filter = SCContentFilter(display: selected, excludingWindows: [])
        case let .apps(names):
            let apps = Self.applications(named: names, in: content.applications)
            guard !apps.isEmpty else {
                throw ScreenStreamFailure("App was not found: \(names.joined(separator: ", "))", code: "app")
            }
            let pids = Set(apps.map(\.processID))
            let windows = Self.windowBounds(of: pids)
            display = Self.display(containing: windows, in: content.displays) ?? content.displays[0]
            rect = Self.captureRect(windows: windows, displayFrame: display.frame)
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            queue.sync {
                self.pids = pids
                self.appNames = apps.map(\.applicationName)
                self.hadWindows = !windows.isEmpty
            }
        }
        let configuration = queue.sync { () -> SCStreamConfiguration in
            self.display = display
            self.captureRect = rect
            return self.configuration(for: rect, display: display)
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        setPointerRect(rect)
        try await stream.startCapture()
        let (sound, soundStream) = audio ? await listen(display: display, content: content) : (nil, nil)
        queue.sync {
            self.stream = stream
            self.sound = sound
            self.soundStream = soundStream
            var more: [String: Any] = ["geometry": self.geometry(rect)]
            if sound != nil { more["audio"] = true }
            self.opened(configuration.width, configuration.height, more)
            // Its format after the info (still.fail's `opened`).
            sound?.said()
        }
        if reportCursor {
            DispatchQueue.main.async { [weak self] in self?.followCursor() }
        }
        if case .apps = target {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.followWindows() }
            timer.resume()
            geometryTimer = timer
        }
    }

    public override func setClipboard(_ payload: Data) {
        if allowInput { clipboard.set(payload) }
    }

    public override func watchClipboard(_ payload: Data) {
        if allowInput { clipboard.watch(payload) }
    }

    public override func nextAudio() {
        queue.async { self.sound?.next() }
    }

    // MARK: Sound

    /// The system output: a display's from the process tap where it starts, else on a stream of its own, its filter
    /// `soundApps`; nil and said (message 4) where it cannot be captured: the picture goes on without it, the info says
    /// no audio, and the station pulls none.
    private func listen(display: SCDisplay, content: SCShareableContent) async -> (SystemAudio?, SCStream?) {
        let made = SystemAudio(channel: channel, opus: opus)
        if case .display = target {
            // As Windows' audio.rs: one event says whether the Comma app's sound is left out, and why not.
            let why: String
            if #available(macOS 14.2, *) {
                switch SystemAudioGrant.now() {
                case .granted:
                    switch await Self.openTap(made) {
                    case let .success(tap):
                        channel.sendJSON(4, ["audio": "the Comma app's sound left out"])
                        queue.sync { self.stopTap = tap.stop }
                        return (made, nil)
                    case let .failure(error):
                        why = "the process tap did not start: \(error)"
                    }
                case .undecided:
                    SystemAudioGrant.ask()
                    why = "System Audio Recording is not allowed yet (asked)"
                case .denied:
                    why = "System Audio Recording is denied"
                case .unknown:
                    why = "System Audio Recording is not known"
                }
            } else {
                why = "macOS before 14.2 has no process tap"
            }
            channel.sendJSON(4, ["audio": "the Comma app's sound not left out (only its main process's): \(why)"])
        }
        let filter = soundFilter(display: display, running: content.applications)
        let listening = SCStream(filter: filter, configuration: Self.soundConfiguration(), delegate: nil)
        do {
            try listening.addStreamOutput(made, type: .audio, sampleHandlerQueue: made.queue)
            try await listening.startCapture()
        } catch {
            channel.sendJSON(4, ["audio": error.localizedDescription])
            return (nil, nil)
        }
        if case .display = target {
            // A Comma app started later (a relaunch, an update) is left out too, once ScreenCaptureKit lists it.
            commaLaunches = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let app, Self.isComma(app.bundleIdentifier ?? "") else { return }
                self?.leaveOut(app.processIdentifier, display: display, tries: 5)
            }
        }
        return (made, listening)
    }

    /// The tap started off the view's threads, given at most 2 s: with the grant it starts at once, and a tap that
    /// starts later is stopped. Never on a thread that matters, as Core Audio can wait on macOS's prompt.
    @available(macOS 14.2, *)
    private static func openTap(_ sink: SystemAudio) async -> Result<SystemAudioTap, SystemAudioTap.Failure> {
        await withCheckedContinuation { done in
            let lock = NSLock()
            var answered = false
            func answer(_ result: Result<SystemAudioTap, SystemAudioTap.Failure>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if answered { return false }
                answered = true
                done.resume(returning: result)
                return true
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let tap = SystemAudioTap(sink: sink)
                do {
                    try tap.start()
                    if !answer(.success(tap)) { tap.stop() }
                } catch {
                    _ = answer(.failure(error as? SystemAudioTap.Failure ?? SystemAudioTap.Failure("\(error)")))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                _ = answer(.failure(SystemAudioTap.Failure("it did not start in 2 s")))
            }
        }
    }

    /// The sound's filter made again with the Comma app `pid` left out; looked for again 0.5 s later while
    /// ScreenCaptureKit does not list it yet (`tries` times).
    private func leaveOut(_ pid: pid_t, display: SCDisplay, tries: Int) {
        Task { [weak self] in
            guard let self, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                let listening = self.queue.sync(execute: { self.soundStream })
            else { return }
            if !content.applications.contains(where: { $0.processID == pid }) {
                if tries > 1 {
                    queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.leaveOut(pid, display: display, tries: tries - 1) }
                }
                return
            }
            try? await listening.updateContentFilter(self.soundFilter(display: display, running: content.applications))
        }
    }

    private func soundFilter(display: SCDisplay, running: [SCRunningApplication]) -> SCContentFilter {
        let viewed: [SCRunningApplication]
        if case .apps = target {
            let pids = queue.sync { self.pids }
            viewed = running.filter { pids.contains($0.processID) }
        } else {
            viewed = []
        }
        switch Self.soundApps(of: target, viewed: viewed, running: running) {
        case let .allBut(apps): return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        case let .only(apps): return SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
    }

    /// The bundle identifiers of the Comma apps start so: the app (`surf.comma.desktop`, `….staging`, `….dev`, a source
    /// build's `….dev.source-…`), its Electron helpers (`….helper`, …) and this helper (`….computer-use`).
    static let commaFamily = "surf.comma.desktop"

    static func isComma(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == commaFamily || bundleIdentifier.hasPrefix(commaFamily + ".")
    }

    /// Whose sound a view hears: a display's, every app's but the Comma apps'; an app's, its apps' but a Comma app's.
    /// ScreenCaptureKit hears a Comma app only in the app's own process, not in Chromium's audio service, which is no
    /// app that a filter can name: a display's view uses the process tap where it can (`listen`).
    static func soundApps<App: SoundApp>(of target: ScreenStreamTarget, viewed: [App], running: [App]) -> SoundApps<App> {
        switch target {
        case .display: .allBut(running.filter { isComma($0.bundleIdentifier) })
        case .apps: .only(viewed.filter { !isComma($0.bundleIdentifier) })
        }
    }

    /// A stream for the sound alone: no picture is taken from it (the smallest, once a second).
    static func soundConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        // The system output, as Windows' loopback has it: never this helper's own sound, never the microphone
        // (still.fail ScreenView.swift `start`).
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = SystemAudio.rate
        config.channelCount = SystemAudio.channels
        if #available(macOS 15.0, *) { config.captureMicrophone = false }
        return config
    }

    public override func stop() {
        if allowInput { clipboard.stop() }
        geometryTimer?.cancel()
        geometryTimer = nil
        DispatchQueue.main.async { [weak self] in
            self?.cursorTimer?.cancel()
            self?.cursorTimer = nil
        }
        if let commaLaunches { NSWorkspace.shared.notificationCenter.removeObserver(commaLaunches) }
        let (streams, stopTap) = queue.sync { () -> ([SCStream], (() -> Void)?) in
            let streams = [self.stream, self.soundStream].compactMap { $0 }
            let stopTap = self.stopTap
            self.stream = nil
            self.soundStream = nil
            self.stopTap = nil
            self.injector.releaseAll()
            return (streams, stopTap)
        }
        stopTap?()
        for stream in streams {
            let done = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
        super.stop()
    }

    /// The bounds changed: the capture asked for the size they take (still.fail ScreenView.swift `bounds`).
    public override func resized() {
        guard let stream, let display else { return }
        let configuration = configuration(for: captureRect, display: display)
        stream.updateConfiguration(configuration) { [weak self] error in
            if let error { self?.channel.sendJSON(4, ["bounds": error.localizedDescription]) }
        }
    }

    /// Applies one viewer input event. `x`/`y` are fractions of the video frame.
    public override func post(_ op: [String: Any]) {
        guard allowInput else { return }
        queue.async {
            let rect = self.captureRect
            self.injector.handle(op) { x, y in
                guard rect.width > 0, rect.height > 0 else { return nil }
                return CGPoint(
                    x: rect.minX + min(1, max(0, x)) * rect.width,
                    y: rect.minY + min(1, max(0, y)) * rect.height
                )
            }
        }
    }

    // MARK: SCStreamOutput

    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // Only a picture that is new: an idle one says the screen did not change.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        guard status == nil || status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let pts = sampleBuffer.presentationTimeStamp
        took(pixelBuffer, pts.isValid ? HostClock.stamp(uptime: Int64(CMTimeGetSeconds(pts) * 1_000_000)) : now())
    }

    public func stream(_: SCStream, didStopWithError error: Error) {
        channel.sendJSON(4, ["stopped": error.localizedDescription])
        shutdown(channel.fd, SHUT_RDWR)
    }

    // MARK: Geometry

    private func followWindows() {
        guard let stream, let display else { return }
        let windows = Self.windowBounds(of: pids)
        let rect = Self.captureRect(windows: windows, displayFrame: display.frame)
        guard rect != captureRect || windows.isEmpty == hadWindows else { return }
        hadWindows = !windows.isEmpty
        captureRect = rect
        setPointerRect(rect)
        stream.updateConfiguration(configuration(for: rect, display: display)) { _ in }
        // Another part of the display: from a key frame.
        forceKey = true
        channel.sendJSON(64, geometry(rect))
    }

    private func configuration(for rect: CGRect, display: SCDisplay) -> SCStreamConfiguration {
        let pointScale = CGFloat(CGDisplayPixelsWide(display.displayID)) / max(1, display.frame.width)
        let byWidth = CGFloat(maxWidth) / max(1, rect.width)
        let byHeight = CGFloat(maxHeight) / max(1, rect.height)
        let scale = min(max(1, pointScale), byWidth, byHeight)
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Self.even(rect.width * scale)
        config.height = Self.even(rect.height * scale)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // The space the stream says it is in (`p3`), not the display's own (still.fail ScreenView.swift `start`).
        config.colorSpaceName = p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        if let background {
            config.backgroundColor = background
        }
        // In the frames unless the viewer draws it (message 6: followCursor).
        config.showsCursor = !reportCursor
        return config
    }

    // MARK: Pointer

    private func setPointerRect(_ rect: CGRect) {
        pointerLock.lock()
        pointerRect = rect
        pointerLock.unlock()
    }

    /// The pointer said (message 6) as it moves or changes shape, while the stream lasts: where it is in the captured
    /// area (0..1 of the frame, as input is), and its shape as CSS names it (the standard cursors; any other "default";
    /// "none" while it is outside the area: another display, off the app's windows). A shape is looked at 10 times a
    /// second. Ported from still.fail's ScreenView.swift `followCursor`, which places it on the whole display.
    @MainActor
    private func followCursor() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard let at = CGEvent(source: nil)?.location else { return }
                self.pointerLock.lock()
                let b = self.pointerRect
                self.pointerLock.unlock()
                guard b.width > 0, b.height > 0 else { return }
                if self.cursorTicks % 6 == 0 { self.cursorShape = CursorShapes.name(of: NSCursor.currentSystem) }
                self.cursorTicks += 1
                let x = min(1, max(0, (at.x - b.minX) / b.width)), y = min(1, max(0, (at.y - b.minY) / b.height))
                let shape = b.contains(at) ? self.cursorShape : "none"
                let said: [String: Any] = ["x": (x * 10000).rounded() / 10000, "y": (y * 10000).rounded() / 10000, "shape": shape]
                if NSDictionary(dictionary: said).isEqual(to: self.cursorSaid) { return }
                self.cursorSaid = said
                self.channel.sendJSON(6, said)
            }
        }
        timer.resume()
        cursorTimer = timer
    }

    /// What the view shows: the info's `geometry` (Cue's), and message 64 as an app's windows move.
    private func geometry(_ rect: CGRect) -> [String: Any] {
        var meta: [String: Any] = [
            "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
            "control": allowInput,
        ]
        if case .apps = target {
            meta["target"] = "app"
            meta["apps"] = appNames
            // None: the rectangle is the whole display's, and there is nothing of the app to see or to drive.
            meta["windows"] = Self.windowBounds(of: pids).count
        } else {
            meta["target"] = "display"
        }
        return meta
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    private static func display(_ index: Int?, in displays: [SCDisplay]) -> SCDisplay? {
        guard let index else {
            return displays.first { $0.displayID == CGMainDisplayID() } ?? displays.first
        }
        return displays.indices.contains(index - 1) ? displays[index - 1] : nil
    }

    private static func applications(named names: [String], in applications: [SCRunningApplication]) -> [SCRunningApplication] {
        if names.isEmpty {
            let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return applications.filter { $0.processID == frontmost }
        }
        let needles = Set(names.map { $0.lowercased() })
        return applications.filter {
            needles.contains($0.applicationName.lowercased()) || needles.contains($0.bundleIdentifier.lowercased())
        }
    }

    /// Bounds of the apps' normal on-screen windows, in global top-left-origin points.
    private static func windowBounds(of pids: Set<pid_t>) -> [CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return windows.compactMap { window in
            guard
                let pid = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value, pids.contains(pid),
                (window[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                let boundsValue = window[kCGWindowBounds],
                let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary),
                bounds.width >= 40, bounds.height >= 40
            else { return nil }
            return bounds
        }
    }

    /// The apps' windows that show on screen, front to back, menus and sheets too: what the picture shows of them.
    static func inputWindows(of pids: Set<pid_t>) -> [RemoteInputWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        return windows.compactMap { window in
            guard
                let pid = (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value, pids.contains(pid),
                let number = (window[kCGWindowNumber] as? NSNumber)?.intValue,
                (window[kCGWindowAlpha] as? NSNumber)?.doubleValue != 0,
                let boundsValue = window[kCGWindowBounds],
                let bounds = CGRect(dictionaryRepresentation: boundsValue as! CFDictionary)
            else { return nil }
            return RemoteInputWindow(pid: pid, number: number, frame: bounds)
        }
    }

    private static func display(containing windows: [CGRect], in displays: [SCDisplay]) -> SCDisplay? {
        guard let first = windows.first else { return nil }
        return displays.max { lhs, rhs in
            let left = lhs.frame.intersection(first)
            let right = rhs.frame.intersection(first)
            return left.width * left.height < right.width * right.height
        }
    }

    /// The union of the windows, clipped to the display. Without a window, the whole display.
    private static func captureRect(windows: [CGRect], displayFrame: CGRect) -> CGRect {
        let union = windows.reduce(CGRect.null) { $0.union($1) }.intersection(displayFrame).integral
        return union.isNull || union.width < 40 || union.height < 40 ? displayFrame : union
    }
}

/// An app as `soundApps` tells the Comma apps apart.
public protocol SoundApp {
    var bundleIdentifier: String { get }
}

extension SCRunningApplication: SoundApp {}

/// Whose sound a view hears: every app's but these, or only these.
public enum SoundApps<App> {
    case allBut([App])
    case only([App])
}

/// A view that did not start, and why (message 1's `code`).
struct ScreenStreamFailure: Error {
    let message: String
    let code: String
    init(_ message: String, code: String) {
        self.message = message
        self.code = code
    }
}

/// The system's standard cursors by the CSS names a client shows them with, told apart by their hot spots and pixels
/// (an NSCursor is made anew each time it is asked for: the same object it never is). One not told apart (a picture
/// macOS draws itself, an app's own) is "default". Ported as it is from still.fail's ScreenView.swift `CursorShapes`.
@MainActor
enum CursorShapes {
    struct Look: Equatable {
        let hotSpot: NSPoint
        let pixels: Data
    }

    static func look(_ cursor: NSCursor) -> Look? {
        guard let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = image.dataProvider?.data else { return nil }
        return Look(hotSpot: cursor.hotSpot, pixels: data as Data)
    }

    static let known: [(Look, String)] = [
        (NSCursor.iBeam, "text"), (NSCursor.pointingHand, "pointer"), (NSCursor.resizeLeftRight, "ew-resize"),
        (NSCursor.resizeUpDown, "ns-resize"), (NSCursor.crosshair, "crosshair"), (NSCursor.openHand, "grab"),
        (NSCursor.closedHand, "grabbing"), (NSCursor.operationNotAllowed, "not-allowed"),
        (NSCursor.iBeamCursorForVerticalLayout, "vertical-text"), (NSCursor.arrow, "default"),
    ].compactMap { cursor, name in look(cursor).map { ($0, name) } }

    static func name(of cursor: NSCursor?) -> String {
        guard let cursor, let seen = look(cursor) else { return "default" }
        return known.first { $0.0 == seen }?.1 ?? "default"
    }
}
