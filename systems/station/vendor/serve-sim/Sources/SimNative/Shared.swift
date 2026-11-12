// ember: what FrameCapture.swift takes from upstream's files left out here (CaptureEngine.swift's PixelConsumerCount,
// EncoderDiagnostics.swift's isoTimestamp and jsonString), as they are there; PixelConsumerCount public.
import Foundation

/// Lock-protected count shared by CaptureEngine (writer) and FrameCapture
/// (reader on its capture queue).
public final class PixelConsumerCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    public init() {}
    public func increment() { lock.lock(); count += 1; lock.unlock() }
    public func decrement() { lock.lock(); count = max(0, count - 1); lock.unlock() }
    public func reset() { lock.lock(); count = 0; lock.unlock() }
    public var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return count == 0 }
}

func isoTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}
