import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

enum BackgroundWindowCapture {
    static func captureWindowScreenshot(windowID: Int) -> (url: URL, size: CGSize)? {
        if let screenCaptureKitResult = captureWithScreenCaptureKit(windowID: windowID) {
            return screenCaptureKitResult
        }
        return captureWithCGWindowList(windowID: windowID)
    }

    @available(macOS 14.0, *)
    private static func captureWithScreenCaptureKit(windowID: Int) -> (url: URL, size: CGSize)? {
        let box = CaptureResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached {
            let result: (url: URL, size: CGSize)? = if let image = await captureWindowImage(windowID: CGWindowID(windowID)),
                                                       let url = writePNG(image, prefix: "sckit-capture")
            {
                (url: url, size: CGSize(width: image.width, height: image.height))
            } else {
                nil
            }
            box.set(result)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 3) == .success else {
            return nil
        }
        return box.get()
    }

    private static func captureWithCGWindowList(windowID: Int) -> (url: URL, size: CGSize)? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            return nil
        }

        return writePNG(image, prefix: "capture").map {
            (url: $0, size: CGSize(width: image.width, height: image.height))
        }
    }

    @available(macOS 14.0, *)
    private static func captureWindowImage(windowID: CGWindowID) async -> CGImage? {
        do {
            let content = try await SCShareableContent.current
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = scaleFactor(for: window.frame)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((window.frame.width * scale).rounded()))
            config.height = max(1, Int((window.frame.height * scale).rounded()))
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            return nil
        }
    }

    private static func writePNG(_ image: CGImage, prefix: String) -> URL? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        do {
            try ComputerUseSnapshotStore.ensureRootDirectory()
            let url = ComputerUseSnapshotStore.rootURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString.lowercased()).png"
            )
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func scaleFactor(for frame: CGRect) -> CGFloat {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0

        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(frame)
            guard !intersection.isNull else {
                continue
            }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }

        return (bestScreen ?? NSScreen.main)?.backingScaleFactor ?? 1
    }
}

private final class CaptureResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (url: URL, size: CGSize)?

    func set(_ value: (url: URL, size: CGSize)?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> (url: URL, size: CGSize)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
