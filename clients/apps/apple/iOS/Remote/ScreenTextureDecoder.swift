import CoreMedia
import CoreVideo
import Metal
import VideoToolbox

/// Decodes a screen view's frames, as `ScreenVideoRenderer` takes them (its `config`, then length-prefixed NAL units),
/// into Metal textures for a 3D stage to draw on its model's screens. VideoToolbox decodes each frame as it comes, on
/// its own threads, into a BGRA pixel buffer; a `CVMetalTextureCache` gives Metal that buffer's memory without a copy.
/// A frame that cannot be decoded asks for a key frame, as the renderer's do.
@MainActor final class ScreenTextureDecoder {
    let device: MTLDevice?
    /// Called on the main queue with each decoded picture.
    var onFrame: ((MTLTexture) -> Void)?
    /// The last picture decoded, for a stage that comes after it.
    private(set) var latest: MTLTexture?
    /// A key frame is due before any other frame can be decoded.
    private(set) var needsKeyframe = true

    private var cache: CVMetalTextureCache?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// The textures in flight: each keeps its pixel buffer's memory while Metal may still read it.
    private var held: [CVMetalTexture] = []
    /// Bumped by each config: a frame of the one before that decodes late is dropped.
    private var generation = 0
    private var failed = false

    init() {
        device = MTLCreateSystemDefaultDevice()
        if let device { CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) }
    }

    /// Takes a view's `config`. False when it is none VideoToolbox knows.
    @discardableResult
    func configure(codec: String, description: String, width: Int, height: Int) -> Bool {
        guard let bytes = Data(base64Encoded: description), width > 0, height > 0 else { return fail() }
        let hevc = codec == "h265"
        let extensions = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [hevc ? "hvcC" : "avcC": bytes],
        ] as CFDictionary
        var made: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: Int32(width), height: Int32(height), extensions: extensions, formatDescriptionOut: &made)
        guard status == noErr, let made else { return fail() }
        invalidate()
        format = made
        generation += 1
        needsKeyframe = true
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var made2: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: made, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &made2) == noErr, let made2 else { return fail() }
        VTSessionSetProperty(made2, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = made2
        return true
    }

    /// Decodes one frame. False when it was not taken: a key frame is then asked for.
    func show(_ data: Data, key: Bool) -> Bool {
        if failed {
            failed = false
            needsKeyframe = true
        }
        guard let session, let format, !data.isEmpty, !needsKeyframe || key else { return false }
        guard let sample = ScreenVideoRenderer.sample(data, format: format, key: key) else { return fail() }
        let generation = generation
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
                // A pixel buffer is safe to hand over: nothing else writes it after its decode.
                nonisolated(unsafe) let image = image
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.decoded(status: status, image: image, generation: generation) }
                }
            }
        guard status == noErr else { return fail() }
        needsKeyframe = false
        return true
    }

    /// The view went: the last picture stays until another view's config comes.
    func reset() {
        invalidate()
        format = nil
        needsKeyframe = true
    }

    private func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }

    private func decoded(status: OSStatus, image: CVImageBuffer?, generation: Int) {
        guard generation == self.generation else { return }
        guard status == noErr, let image, let cache else {
            failed = true
            return
        }
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        var made: CVMetalTexture?
        // sRGB: the picture's values are gamma-encoded, and SceneKit lights in linear values.
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, image, nil, .bgra8Unorm_srgb,
                                                        width, height, 0, &made) == kCVReturnSuccess,
              let made, let texture = CVMetalTextureGetTexture(made) else { return }
        held.append(made)
        if held.count > 3 { held.removeFirst(held.count - 3) }
        latest = texture
        onFrame?(texture)
    }

    private func fail() -> Bool {
        needsKeyframe = true
        return false
    }
}
