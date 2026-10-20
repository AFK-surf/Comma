import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// One encoded H.264 access unit in Annex-B form.
struct H264AccessUnit {
    let data: Data
    let isKeyframe: Bool
    let ptsMicros: UInt64
}

/// Real-time H.264 encoder for screen content. The session is rebuilt when the
/// frame size changes, which happens when the streamed app's windows move or resize.
final class H264Encoder {
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var forceKeyframe = true
    private var createStatus: OSStatus = noErr
    private var useLowLatency = true
    private var needsRebuild = false
    /// The most recent VideoToolbox failure, for stream diagnostics.
    private(set) var lastStatus: OSStatus = noErr
    private let bitrate: Int
    private let fps: Int
    private let onAccessUnit: (H264AccessUnit) -> Void

    init(bitrate: Int, fps: Int, onAccessUnit: @escaping (H264AccessUnit) -> Void) {
        self.bitrate = bitrate
        self.fps = fps
        self.onAccessUnit = onAccessUnit
    }

    func requestKeyframe() {
        forceKeyframe = true
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let frameWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if session == nil || needsRebuild || frameWidth != width || frameHeight != height {
            rebuild(width: frameWidth, height: frameHeight)
        }
        guard let session else {
            lastStatus = createStatus
            return
        }

        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        let onAccessUnit = onAccessUnit
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let unit = Self.accessUnit(from: sampleBuffer) else {
                self?.lastStatus = status
                // A low-latency session can be created where no hardware encoder exists
                // (virtual machines) and then fails every frame. Use the default encoder.
                if status != noErr, self?.useLowLatency == true {
                    self?.useLowLatency = false
                    self?.needsRebuild = true
                }
                return
            }
            onAccessUnit(unit)
        }
        if status != noErr {
            lastStatus = status
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func rebuild(width: Int32, height: Int32) {
        invalidate()
        self.width = width
        self.height = height
        forceKeyframe = true
        needsRebuild = false

        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        for specification in (useLowLatency ? [lowLatency, nil] : [nil]) as [CFDictionary?] {
            var created: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil,
                width: width,
                height: height,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
            createStatus = status
            if status == noErr, let created {
                session = created
                break
            }
        }
        guard let session else { return }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // The software encoder has no constrained baseline profile.
        for profile in [kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, kVTProfileLevel_H264_Baseline_AutoLevel] {
            if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile) == noErr {
                break
            }
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            value: 4 as CFNumber
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private static func accessUnit(from sampleBuffer: CMSampleBuffer) -> H264AccessUnit? {
        guard
            let block = CMSampleBufferGetDataBuffer(sampleBuffer),
            let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let startCode: [UInt8] = [0, 0, 0, 1]
        var output = Data()

        if isKeyframe {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: nil
            )
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard status == noErr, let pointer else { return nil }
                output.append(contentsOf: startCode)
                output.append(pointer, count: size)
            }
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard
            CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            ) == kCMBlockBufferNoErr,
            let dataPointer
        else { return nil }

        // VideoToolbox emits AVCC: each NAL unit follows a 4-byte big-endian length.
        let bytes = UnsafeRawPointer(dataPointer)
        var offset = 0
        while offset + 4 <= totalLength {
            let length = Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            offset += 4
            guard length > 0, offset + length <= totalLength else { break }
            output.append(contentsOf: startCode)
            output.append(bytes.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: length)
            offset += length
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000) : 0
        return H264AccessUnit(data: output, isKeyframe: isKeyframe, ptsMicros: micros)
    }
}
