import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

/// Shows a screen view's frames as the station sends them: its `config` (H.264's avcC or H.265's hvcC, in base64) and
/// then length-prefixed NAL units, which is what VideoToolbox decodes as they are. A frame that cannot be shown asks
/// for a key frame (`needsKeyframe`); nothing shows until one comes after each new config or failure.
@MainActor final class ScreenVideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    /// A key frame is due before any other frame can be shown.
    private(set) var needsKeyframe = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.preventsDisplaySleepDuringVideoPlayback = false
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
        format = made
        needsKeyframe = true
        layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        return true
    }

    /// Shows one frame. False when it was not shown: a key frame is then asked for.
    func show(_ data: Data, key: Bool) -> Bool {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            needsKeyframe = true
        }
        guard let format, !data.isEmpty, !needsKeyframe || key else { return false }
        guard let sample = Self.sample(data, format: format, key: key) else { return fail() }
        renderer.enqueue(sample)
        needsKeyframe = false
        return true
    }

    /// The view went: the last picture stays until another view's config comes.
    func reset() {
        format = nil
        needsKeyframe = true
    }

    private func fail() -> Bool {
        needsKeyframe = true
        return false
    }

    nonisolated static func sample(_ data: Data, format: CMVideoFormatDescription, key: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

/// The layer a renderer draws into, sized to its view.
struct ScreenVideoLayerView: UIViewRepresentable {
    let renderer: ScreenVideoRenderer

    func makeUIView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.layer.addSublayer(renderer.layer)
        return view
    }

    func updateUIView(_ view: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
