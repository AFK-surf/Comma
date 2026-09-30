import AppKit
import CoreGraphics
import CUShared
import Foundation
import ScreenCaptureKit

/// Anthropic computer-use vision-API limits that the agent's screenshots
/// must fit inside: long edge ≤ 1568 px, total area ≤ 0.6 megapixels.
/// Slim port keeps these as public constants so tests + other tools can
/// reason about the shape. Numeric values mirror legacy ComputerUse's
/// `MAX_LONG_EDGE` / `MAX_PIXELS` exactly — the 0.6 MP budget is measured
/// against 0.6 × 1024² (629_145.6), NOT a flat 600_000; the Anthropic
/// spec is written in binary megapixels and using the decimal value
/// would quietly downscale edge cases that legacy kept at native size.
public enum AnthropicImageLimits {
    public static let maxLongEdgePixels: Int = 1568
    public static let maxPixelArea: Int = 629_145
}

/// Screenshot + zoom helpers for foreground mode. Uses ScreenCaptureKit
/// (via `DisplayCaptureProvider`) so the daemon's own overlay windows
/// (colorful border, dim mask, cursor sprite) are excluded from the
/// captured image. Falls back to `CGDisplayCreateImage` on pre-macOS-14
/// systems and on any ScreenCaptureKit failure.
@available(macOS 14.0, *)
public enum ScreenCapture {
    /// Delay before capture so the GUI has a chance to settle after a
    /// prior agent action. Matches the legacy 1.0s default, tunable via
    /// env.
    public static var settleDelay: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["CUNEXT_SCREENSHOT_DELAY_MS"],
           let ms = Double(raw)
        {
            return ms / 1000.0
        }
        return 1.0
    }

    /// Capture the primary display as a PNG file on disk. Returns the
    /// file URL + pixel dimensions after Anthropic-spec clamping.
    @MainActor
    public static func captureToPNG() async throws -> (url: URL, width: Int, height: Int) {
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        let raw = try await captureMainDisplay()
        let scaled = scaleToAnthropicLimits(raw)
        // Paint a red crosshair at the current cursor's image-space
        // coordinates BEFORE recording dims / writing the file — legacy
        // ComputerUse does the same, and without it the model has no way
        // to tell where its mouse currently sits vs where it wants to
        // click. Falls back to the raw scaled image if cursor location
        // is unavailable.
        let annotated = drawCursorCrosshair(on: scaled)
        try DaemonPaths.ensureRuntimeDirectory()
        let url = DaemonPaths.runtimeDirectory.appendingPathComponent(
            "foreground-screenshot-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        )
        try writePNG(annotated, to: url)
        // Record the dimensions of what the agent actually sees so
        // subsequent clicks/moves can be mapped back to display points.
        // Zoom crops don't update this — they're a secondary read, not
        // the canonical reference the agent clicks against.
        ForegroundCoordinateMap.recordLastImage(width: annotated.width, height: annotated.height)
        return (url, annotated.width, annotated.height)
    }

    /// Capture a cropped region (in pixel-space coordinates) and scale
    /// it to Anthropic limits. Used by the `zoom` action.
    @MainActor
    public static func captureCropToPNG(region: CGRect) async throws -> (url: URL, width: Int, height: Int) {
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        let raw = try await captureMainDisplay()
        guard
            let cropped = cropToPixelRect(raw, region: region)
        else {
            throw ComputerUseForegroundError.screenshotFailed("crop region \(region) does not intersect image")
        }
        let scaled = scaleToAnthropicLimits(cropped)
        try DaemonPaths.ensureRuntimeDirectory()
        let url = DaemonPaths.runtimeDirectory.appendingPathComponent(
            "foreground-zoom-\(Int(Date().timeIntervalSince1970 * 1000)).png"
        )
        try writePNG(scaled, to: url)
        return (url, scaled.width, scaled.height)
    }

    // MARK: - Internals

    @MainActor
    private static func captureMainDisplay() async throws -> CGImage {
        let displayID = CGMainDisplayID()
        let displayBounds = CGDisplayBounds(displayID)

        do {
            return try await captureWithSCKit(
                displayID: displayID,
                displayBounds: displayBounds
            )
        } catch {
            // Fall back to the older CG path if ScreenCaptureKit refuses
            // (happens when Screen Recording permission is missing, which
            // should have been caught by the permission probe — but a
            // belt-and-suspenders fallback here is cheaper than letting
            // the agent fail a screenshot during a session).
            if let cgImage = CGDisplayCreateImage(displayID) {
                return cgImage
            }
            throw ComputerUseForegroundError.screenshotFailed("\(error)")
        }
    }

    @MainActor
    private static func captureWithSCKit(
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    ) async throws -> CGImage {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
            throw ComputerUseForegroundError.screenshotFailed("no matching display for \(displayID)")
        }

        // Exclude any window owned by our own pid (border, dim mask,
        // cursor sprite) so they don't show up in the screenshot.
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let excludedWindows = shareableContent.windows.filter { Int($0.owningApplication?.processID ?? 0) == selfPID }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.sourceRect = CGRect(
            x: 0,
            y: 0,
            width: displayBounds.width,
            height: displayBounds.height
        )
        let scale = displayPixelScale(displayID: displayID, displayBounds: displayBounds)
        config.width = max(1, Int((displayBounds.width * scale.x).rounded()))
        config.height = max(1, Int((displayBounds.height * scale.y).rounded()))

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    private static func displayPixelScale(
        displayID: CGDirectDisplayID,
        displayBounds: CGRect
    ) -> (x: CGFloat, y: CGFloat) {
        let mode = CGDisplayCopyDisplayMode(displayID)
        let pixelWidth = CGFloat(mode?.pixelWidth ?? Int(displayBounds.width))
        let pixelHeight = CGFloat(mode?.pixelHeight ?? Int(displayBounds.height))
        let logicalWidth = max(displayBounds.width, 1)
        let logicalHeight = max(displayBounds.height, 1)
        return (pixelWidth / logicalWidth, pixelHeight / logicalHeight)
    }

    /// Downscale so (a) the long edge fits `maxLongEdgePixels` and
    /// (b) total pixel area fits `maxPixelArea`, whichever is tighter.
    /// Returns the original image if it already fits.
    private static func scaleToAnthropicLimits(_ image: CGImage) -> CGImage {
        let srcW = image.width
        let srcH = image.height
        let longEdge = max(srcW, srcH)
        let area = srcW * srcH

        let longEdgeScale = CGFloat(AnthropicImageLimits.maxLongEdgePixels) / CGFloat(longEdge)
        let areaScale = sqrt(CGFloat(AnthropicImageLimits.maxPixelArea) / CGFloat(max(area, 1)))
        let scale = min(1.0, min(longEdgeScale, areaScale))
        if scale >= 1.0 { return image }

        let dstW = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let dstH = max(1, Int((CGFloat(srcH) * scale).rounded()))
        return redraw(image, width: dstW, height: dstH) ?? image
    }

    private static func cropToPixelRect(_ image: CGImage, region: CGRect) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = region.intersection(imageBounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            return nil
        }
        return image.cropping(to: clipped)
    }

    private static func redraw(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Ported from legacy `ScreenCapture.drawCursorCrosshair`: paints a
    /// red '+' at the current system cursor position so the model can see
    /// exactly where the mouse already is. Input + output are in the
    /// scaled screenshot's image space (top-left origin). Silently
    /// returns the input image if cursor position or display bounds are
    /// unavailable.
    @MainActor
    private static func drawCursorCrosshair(on image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let displayID = CGMainDisplayID()
        let bounds = CGDisplayBounds(displayID)
        guard
            bounds.width > 0,
            bounds.height > 0,
            let cursor = CGEvent(source: nil)?.location
        else { return image }

        let localX = cursor.x - bounds.origin.x
        let localY = cursor.y - bounds.origin.y
        guard localX >= 0, localX <= bounds.width,
              localY >= 0, localY <= bounds.height
        else { return image }

        let cursorX = Int((localX * CGFloat(width) / bounds.width).rounded())
        let cursorY = Int((localY * CGFloat(height) / bounds.height).rounded())

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CGContext is bottom-left origin, so flip y for drawing.
        let drawY = CGFloat(height - cursorY)
        context.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(3)

        let radius: CGFloat = 20
        let hStart = max(0, CGFloat(cursorX) - radius)
        let hEnd = min(CGFloat(width - 1), CGFloat(cursorX) + radius)
        context.move(to: CGPoint(x: hStart, y: drawY))
        context.addLine(to: CGPoint(x: hEnd, y: drawY))
        context.strokePath()

        let vStart = max(0, drawY - radius)
        let vEnd = min(CGFloat(height - 1), drawY + radius)
        context.move(to: CGPoint(x: CGFloat(cursorX), y: vStart))
        context.addLine(to: CGPoint(x: CGFloat(cursorX), y: vEnd))
        context.strokePath()

        return context.makeImage() ?? image
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ComputerUseForegroundError.screenshotFailed("PNG encode failed")
        }
        try data.write(to: url, options: .atomic)
    }
}

public enum ComputerUseForegroundError: Error, CustomStringConvertible {
    case screenshotFailed(String)

    public var description: String {
        switch self {
        case let .screenshotFailed(msg): "Screenshot failed: \(msg)"
        }
    }
}
