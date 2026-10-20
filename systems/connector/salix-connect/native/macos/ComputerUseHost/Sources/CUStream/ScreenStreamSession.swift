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

public struct ScreenStreamOptions: Sendable {
    public var target: ScreenStreamTarget
    public var fps: Int
    public var maxWidth: Int
    public var bitrate: Int
    public var allowInput: Bool
    /// What shows where the frame has no window: round an app's corners and between its windows.
    public var background: CGColor?

    public init(
        target: ScreenStreamTarget, fps: Int = 30, maxWidth: Int = 1920, bitrate: Int = 4_000_000,
        allowInput: Bool = false, background: CGColor? = nil
    ) {
        self.target = target
        self.fps = fps
        self.maxWidth = maxWidth
        self.bitrate = bitrate
        self.allowInput = allowInput
        self.background = background
    }

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

    public init(json: [String: Any]) {
        let apps = (json["apps"] as? [String] ?? []).filter { !$0.isEmpty }
        let display = (json["display"] as? NSNumber)?.intValue
        let target: ScreenStreamTarget = (json["target"] as? String) == "display" ? .display(display) : .apps(apps)
        self.init(
            target: target,
            fps: min(60, max(1, (json["fps"] as? NSNumber)?.intValue ?? 30)),
            maxWidth: min(3840, max(320, (json["max_width"] as? NSNumber)?.intValue ?? 1920)),
            bitrate: min(20_000_000, max(200_000, (json["bitrate"] as? NSNumber)?.intValue ?? 4_000_000)),
            allowInput: (json["control"] as? Bool) ?? false,
            background: Self.color(hex: json["background"] as? String)
        )
    }
}

public struct ScreenStreamError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Captures one app or one display with ScreenCaptureKit and emits H.264 access units.
///
/// An app stream uses a display filter that includes only the target apps, so
/// windows of other apps never reach the frame, even when they cover the target.
/// The capture rectangle follows the union of the target apps' windows.
public final class ScreenStreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// `(flags, ptsMicros, annexB)`; flags bit 0 marks a keyframe.
    public var onVideo: ((UInt8, UInt64, Data) -> Void)?
    /// JSON-ready status for the viewer: `ready`, `geometry`, or `ended`.
    public var onMeta: (([String: Any]) -> Void)?

    private let options: ScreenStreamOptions
    private let queue = DispatchQueue(label: "CommaComputerUse.ScreenStream")
    private let injector = RemoteInputInjector()
    private var stream: SCStream?
    private var encoder: H264Encoder?
    private var geometryTimer: DispatchSourceTimer?
    private var display: SCDisplay?
    private var pids: Set<pid_t> = []
    private var appNames: [String] = []
    /// Captured area in global top-left-origin points. Guarded by `queue`.
    private var captureRect = CGRect.zero
    /// The newest captured frame, kept for a keyframe request while the screen is still.
    private var lastFrame: CVPixelBuffer?
    private var capturedFrames = 0
    private var skippedFrames = 0
    private var encodedFrames = 0
    private var encodedBytes = 0
    private var statsTicks = 0

    public init(options: ScreenStreamOptions) {
        self.options = options
    }

    public func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenStreamError("Screen Recording permission is missing: \(error.localizedDescription)")
        }

        let filter: SCContentFilter
        let display: SCDisplay
        var rect: CGRect
        switch options.target {
        case let .display(index):
            guard let selected = Self.display(index, in: content.displays) else {
                throw ScreenStreamError("Display was not found")
            }
            display = selected
            rect = selected.frame
            filter = SCContentFilter(display: selected, excludingWindows: [])
        case let .apps(names):
            let apps = Self.applications(named: names, in: content.applications)
            guard !apps.isEmpty else {
                throw ScreenStreamError("App was not found: \(names.joined(separator: ", "))")
            }
            pids = Set(apps.map(\.processID))
            appNames = apps.map(\.applicationName)
            let windows = Self.windowBounds(of: pids)
            display = Self.display(containing: windows, in: content.displays) ?? content.displays[0]
            rect = Self.captureRect(windows: windows, displayFrame: display.frame)
            filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        }
        self.display = display

        let encoder = H264Encoder(bitrate: options.bitrate, fps: options.fps) { [weak self] unit in
            guard let self else { return }
            self.queue.async {
                self.encodedFrames += 1
                self.encodedBytes += unit.data.count
            }
            self.onVideo?(unit.isKeyframe ? 1 : 0, unit.ptsMicros, unit.data)
        }
        let stream = SCStream(filter: filter, configuration: configuration(for: rect, display: display), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.encoder = encoder
            self.captureRect = rect
        }
        try await stream.startCapture()
        self.stream = stream
        onMeta?(geometryMeta(type: "ready", rect: rect))

        let followsWindows = if case .apps = options.target { true } else { false }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if followsWindows { self.followWindows() }
            self.statsTicks += 1
            if self.statsTicks % 8 == 0 { self.reportStats() }
        }
        timer.resume()
        geometryTimer = timer
    }

    /// Counters since the previous report, for the viewer's status line and for diagnosis.
    private func reportStats() {
        onMeta?([
            "type": "stats",
            "captured": capturedFrames, "skipped": skippedFrames,
            "encoded": encodedFrames, "bytes": encodedBytes,
            "encoder_status": Int(encoder?.lastStatus ?? 0),
        ])
        capturedFrames = 0
        skippedFrames = 0
        encodedFrames = 0
        encodedBytes = 0
    }

    public func stop() {
        geometryTimer?.cancel()
        geometryTimer = nil
        let stream = stream
        self.stream = nil
        stream?.stopCapture { _ in }
        queue.sync {
            encoder?.invalidate()
            encoder = nil
            lastFrame = nil
            injector.releaseAll()
        }
    }

    /// Sends a keyframe now. A still screen delivers no new frame, so the last one is encoded again.
    public func requestKeyframe() {
        queue.async {
            self.encoder?.requestKeyframe()
            if let lastFrame = self.lastFrame {
                self.encoder?.encode(lastFrame, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    /// Applies one viewer input event. `x`/`y` are fractions of the video frame.
    public func handleInput(_ event: [String: Any]) {
        guard options.allowInput else { return }
        queue.async {
            let rect = self.captureRect
            self.injector.handle(event) { x, y in
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
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let status = (attachments?.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
        guard status == nil || status == .complete, let pixelBuffer = sampleBuffer.imageBuffer else {
            skippedFrames += 1
            return
        }
        capturedFrames += 1
        lastFrame = pixelBuffer
        encoder?.encode(pixelBuffer, pts: sampleBuffer.presentationTimeStamp)
    }

    public func stream(_: SCStream, didStopWithError error: Error) {
        onMeta?(["type": "ended", "error": error.localizedDescription])
    }

    // MARK: Geometry

    private func followWindows() {
        guard let stream, let display else { return }
        let rect = Self.captureRect(windows: Self.windowBounds(of: pids), displayFrame: display.frame)
        guard rect != captureRect else { return }
        captureRect = rect
        stream.updateConfiguration(configuration(for: rect, display: display)) { _ in }
        encoder?.requestKeyframe()
        onMeta?(geometryMeta(type: "geometry", rect: rect))
    }

    private func configuration(for rect: CGRect, display: SCDisplay) -> SCStreamConfiguration {
        let pointScale = CGFloat(CGDisplayPixelsWide(display.displayID)) / max(1, display.frame.width)
        let scale = min(max(1, pointScale), CGFloat(options.maxWidth) / max(1, rect.width))
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Self.even(rect.width * scale)
        config.height = Self.even(rect.height * scale)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.queueDepth = 4
        if let background = options.background {
            config.backgroundColor = background
        }
        config.showsCursor = true
        return config
    }

    private func geometryMeta(type: String, rect: CGRect) -> [String: Any] {
        var meta: [String: Any] = [
            "type": type,
            "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
            "control": options.allowInput,
        ]
        if case .apps = options.target {
            meta["target"] = "app"
            meta["apps"] = appNames
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
