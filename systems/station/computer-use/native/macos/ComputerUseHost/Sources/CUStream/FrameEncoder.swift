import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// A compression session as ScreenView uses it: VideoToolbox's in the helper, a stand-in in ScreenView's tests. A first
/// `VTCompressionSessionCreate` in a process enumerates the cameras, and on the CI's virtual Macs that enumeration can
/// wait forever on CoreMediaIO's extension service (`CMIOExtensionProviderHostContext pluginStates:`).
public protocol FrameEncoder: AnyObject {
    /// Sets a `kVTCompressionPropertyKey_…`.
    @discardableResult func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus
    /// Readies the encoder once its properties are set.
    func prepare()
    /// Whether VideoToolbox chose a hardware encoder (nil: unknown).
    var onHardware: Bool? { get }
    /// Encodes a picture, a key frame where `key`; `done` is called once, on the encoder's thread.
    func encode(_ picture: CVPixelBuffer, at ts: CMTime, key: Bool, done: @escaping @Sendable (OSStatus, CMSampleBuffer?) -> Void) -> OSStatus
    func invalidate()
}

/// What ScreenView asks of an encoder: its codec, size and `kVTVideoEncoderSpecification_…`; nil where none is made.
public typealias FrameEncoders = (_ codec: CMVideoCodecType, _ width: Int, _ height: Int, _ specification: [CFString: Any]) -> FrameEncoder?

/// VideoToolbox's compression session.
public final class VTFrameEncoder: FrameEncoder {
    let session: VTCompressionSession

    init(_ session: VTCompressionSession) { self.session = session }

    public static func make(_ codec: CMVideoCodecType, _ width: Int, _ height: Int, _ specification: [CFString: Any]) -> FrameEncoder? {
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let made else { return nil }
        return VTFrameEncoder(made)
    }

    public func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus { VTSessionSetProperty(session, key: key, value: value) }

    public func prepare() { VTCompressionSessionPrepareToEncodeFrames(session) }

    public var onHardware: Bool? {
        var value: CFBoolean?
        guard VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &value) == noErr,
              let value else { return nil }
        return CFBooleanGetValue(value)
    }

    public func encode(_ picture: CVPixelBuffer, at ts: CMTime, key: Bool, done: @escaping @Sendable (OSStatus, CMSampleBuffer?) -> Void) -> OSStatus {
        let properties = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary : nil
        return VTCompressionSessionEncodeFrame(
            session, imageBuffer: picture, presentationTimeStamp: ts, duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { status, _, sample in done(status, sample) }
    }

    public func invalidate() { VTCompressionSessionInvalidate(session) }
}
