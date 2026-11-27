import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import QuartzCore
import ScreenCaptureKit
import SwiftUI

private let vdStreamLogger = Logger(
    subsystem: "surf.comma.CommaComputerUse",
    category: "VirtualDesktopStream"
)

/// Live `ScreenCaptureKit` frame stream of the agent's virtual display.
///
/// Captures the entire virtual display (including the AI `DaemonCursor` overlay
/// and `BorderOverlay`, while excluding the human pointer via `showsCursor = false`)
/// and pushes IOSurface/CGImage frames directly into registered `CALayer` hosts
/// for zero-copy, 30fps live preview inside both the Notch thumbnail and the
/// expanded "Check computer" viewer window.
///
/// Capture size follows what is on screen: one pixel per point while only the
/// thumbnail shows it (`.preview`, 1440×900 for the default display), and the
/// display's full pixel size while the viewer is open (`.full`, 2880×1800), so
/// the viewer gets 2× Retina text without paying 4× the pixels all session.
@available(macOS 14.0, *)
@MainActor
public final class VirtualDesktopStream: NSObject, ObservableObject {
    public enum CaptureQuality: Equatable, Sendable {
        /// One pixel per point: enough for the notch thumbnail.
        case preview
        /// The display's native pixel size: for the full-size viewer.
        case full
    }

    @Published public private(set) var isStreaming = false
    public private(set) var quality: CaptureQuality = .preview
    /// Pixel size of the running capture; zero when not streaming.
    public private(set) var captureSize: CGSize = .zero

    private var stream: SCStream?
    private var outputBridge: FrameOutputBridge?
    private var targets: [ObjectIdentifier: WeakLayerBox] = [:]
    private var latestSurface: IOSurfaceRef?
    private var previewImage: CGImage?
    private var currentDisplayID: CGDirectDisplayID?
    private var currentFPS = 30
    /// Serializes reconfiguration so the last requested quality always wins.
    private var reconfigureTask: Task<Void, Never>?
    /// Monotonic token incremented on start/stop so a superseded `start()` never leaks an orphan SCStream.
    private var startGeneration: UInt64 = 0

    private final class WeakLayerBox {
        weak var layer: CALayer?
        init(_ layer: CALayer) { self.layer = layer }
    }

    public override init() {
        super.init()
    }

    public func registerLayer(_ layer: CALayer) {
        let id = ObjectIdentifier(layer)
        targets[id] = WeakLayerBox(layer)
        if let contents: Any = latestSurface ?? previewImage {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = contents
            CATransaction.commit()
        }
    }

    public func unregisterLayer(_ layer: CALayer) {
        targets.removeValue(forKey: ObjectIdentifier(layer))
    }

    /// Sets a static `CGImage` fallback frame on registered preview layers (used for
    /// deterministic offscreen previews and visual regression tests without live capture).
    public func setPreviewImage(_ image: CGImage?) {
        previewImage = image
        guard latestSurface == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for box in targets.values {
            box.layer?.contents = image
        }
        CATransaction.commit()
    }

    /// Capture size for a display of `pointSize` points backed by `pixelSize`
    /// pixels.
    public nonisolated static func captureSize(
        pointSize: CGSize,
        pixelSize: CGSize,
        quality: CaptureQuality
    ) -> CGSize {
        let size = quality == .full ? pixelSize : pointSize
        return CGSize(width: max(2, size.width.rounded()), height: max(2, size.height.rounded()))
    }

    private static func captureSize(for displayID: CGDirectDisplayID, quality: CaptureQuality) -> CGSize {
        let bounds = CGDisplayBounds(displayID)
        var pixels = CGSize(width: bounds.width * 2, height: bounds.height * 2)
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let points = bounds.isEmpty ? CGSize(width: 1440, height: 900) : bounds.size
        if pixels.width < points.width { pixels = points }
        return captureSize(pointSize: points, pixelSize: pixels, quality: quality)
    }

    private func configuration(size: CGSize, fps: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        return config
    }

    /// Switches the capture size of the running stream in place (no restart,
    /// no blank frame). Also remembered for the next `start`.
    public func setQuality(_ newQuality: CaptureQuality) {
        guard newQuality != quality else { return }
        quality = newQuality
        let previous = reconfigureTask
        reconfigureTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyQuality()
        }
    }

    private func applyQuality() async {
        guard let stream, let displayID = currentDisplayID else { return }
        let size = Self.captureSize(for: displayID, quality: quality)
        guard size != captureSize else { return }
        do {
            try await stream.updateConfiguration(configuration(size: size, fps: currentFPS))
            // The stream may have been stopped or replaced while updating.
            guard self.stream === stream else { return }
            captureSize = size
            vdStreamLogger.notice("VirtualDesktopStream capture now \(Int(size.width))x\(Int(size.height))")
        } catch {
            vdStreamLogger.error("VirtualDesktopStream reconfigure failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Starts streaming `displayID` at the current quality's size and `fps`.
    public func start(displayID: CGDirectDisplayID, fps: Int = 30) async {
        await stop()
        startGeneration &+= 1
        let gen = startGeneration
        currentDisplayID = displayID
        currentFPS = fps

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard startGeneration == gen else { return }
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                vdStreamLogger.warning("Virtual display \(displayID) not found in SCShareableContent")
                return
            }

            // Include all windows on the virtual display (including DaemonCursor & BorderOverlay)
            // so the user sees the live AI cursor moving and clicking in real time.
            let excludedWindows = content.windows.filter { w in
                w.windowLayer >= 2000 || w.owningApplication?.bundleIdentifier == "com.apple.loginwindow"
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
            let size = Self.captureSize(for: displayID, quality: quality)
            let config = configuration(size: size, fps: fps)

            let bridge = FrameOutputBridge(
                onSurface: { [weak self] box in
                    Task { @MainActor [weak self] in
                        self?.deliver(surface: box.ref)
                    }
                },
                onStop: { [weak self] stoppedID in
                    Task { @MainActor [weak self] in
                        self?.handleStreamStopped(id: stoppedID)
                    }
                }
            )
            let scStream = SCStream(filter: filter, configuration: config, delegate: bridge)
            try scStream.addStreamOutput(
                bridge,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "surf.comma.vd-stream", qos: .userInteractive)
            )
            try await scStream.startCapture()
            guard startGeneration == gen else {
                try? await scStream.stopCapture()
                return
            }

            self.outputBridge = bridge
            self.stream = scStream
            self.captureSize = size
            self.isStreaming = true
            vdStreamLogger.notice(
                "VirtualDesktopStream started for display=\(displayID) \(Int(size.width))x\(Int(size.height))@\(fps)fps"
            )
            // A quality change requested while starting applies now.
            if Self.captureSize(for: displayID, quality: quality) != size {
                await applyQuality()
            }
        } catch {
            vdStreamLogger.error("VirtualDesktopStream start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func stop() async {
        startGeneration &+= 1
        let existing = stream
        stream = nil
        outputBridge = nil
        captureSize = .zero
        isStreaming = false
        latestSurface = nil
        currentDisplayID = nil
        if let existing {
            try? await existing.stopCapture()
        }
    }

    public func stopSync() {
        startGeneration &+= 1
        let existing = stream
        stream = nil
        outputBridge = nil
        captureSize = .zero
        quality = .preview
        reconfigureTask?.cancel()
        reconfigureTask = nil
        isStreaming = false
        latestSurface = nil
        currentDisplayID = nil
        if let existing {
            Task { try? await existing.stopCapture() }
        }
    }

    private func handleStreamStopped(id: ObjectIdentifier) {
        guard let stream, ObjectIdentifier(stream) == id else { return }
        self.stream = nil
        self.outputBridge = nil
        self.captureSize = .zero
        self.isStreaming = false
    }

    private func deliver(surface: IOSurfaceRef) {
        latestSurface = surface
        var deadKeys: [ObjectIdentifier] = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (key, box) in targets {
            if let layer = box.layer {
                layer.contents = surface
            } else {
                deadKeys.append(key)
            }
        }
        CATransaction.commit()
        for k in deadKeys { targets.removeValue(forKey: k) }
    }
}

@available(macOS 14.0, *)
private struct SendableSurface: @unchecked Sendable {
    let ref: IOSurfaceRef
}

@available(macOS 14.0, *)
private final class FrameOutputBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onSurface: @Sendable (SendableSurface) -> Void
    private let onStop: @Sendable (ObjectIdentifier) -> Void

    init(
        onSurface: @escaping @Sendable (SendableSurface) -> Void,
        onStop: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.onSurface = onSurface
        self.onStop = onStop
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else { return }
        onSurface(SendableSurface(ref: surface))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        vdStreamLogger.warning("VirtualDesktopStream stopped with error: \(error.localizedDescription, privacy: .public)")
        onStop(ObjectIdentifier(stream))
    }
}

/// Zero-copy `CALayer` view hosting the live `VirtualDesktopStream` IOSurface.
@available(macOS 14.0, *)
public struct VirtualDesktopSurfaceView: NSViewRepresentable {
    public let stream: VirtualDesktopStream

    public init(stream: VirtualDesktopStream) {
        self.stream = stream
    }

    public func makeNSView(context: Context) -> SurfaceHostNSView {
        let view = SurfaceHostNSView()
        view.attach(to: stream)
        return view
    }

    public func updateNSView(_ nsView: SurfaceHostNSView, context: Context) {
        nsView.attach(to: stream)
    }

    public static func dismantleNSView(_ nsView: SurfaceHostNSView, coordinator: ()) {
        nsView.detach()
    }
}

@available(macOS 14.0, *)
public final class SurfaceHostNSView: NSView {
    private weak var boundStream: VirtualDesktopStream?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        // The thumbnail shows a 1440–2880px frame in about 300px: filter the
        // downscale so fine UI text does not shimmer.
        layer?.minificationFilter = .trilinear
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func attach(to stream: VirtualDesktopStream) {
        if boundStream === stream { return }
        detach()
        boundStream = stream
        if let layer {
            stream.registerLayer(layer)
        }
    }

    @MainActor
    func detach() {
        if let layer, let boundStream {
            boundStream.unregisterLayer(layer)
        }
        boundStream = nil
    }
}
