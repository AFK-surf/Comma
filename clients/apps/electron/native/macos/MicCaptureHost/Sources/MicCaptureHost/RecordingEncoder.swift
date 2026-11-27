import AVFoundation
import AudioToolbox
import Foundation

/// Encode the completed mono mix in fixed-size buffers without capture or TCC access.
func encodeRecording(input: URL, output: URL) throws {
    let source = try AVAudioFile(forReading: input)
    let format = source.processingFormat
    var aac = AudioStreamBasicDescription()
    aac.mFormatID = kAudioFormatMPEG4AAC
    // AAC accepts only discrete rates. ExtAudioFile resamples from the client format.
    aac.mSampleRate = aacSampleRate(for: format.sampleRate)
    // Recordings may contain an unmixed stereo system track. The archive contract is mono.
    aac.mChannelsPerFrame = 1
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try checkEncodingStatus(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &aac))

    var outputFile: ExtAudioFileRef?
    try checkEncodingStatus(ExtAudioFileCreateWithURL(output as CFURL, kAudioFileM4AType, &aac, nil,
                                                     AudioFileFlags.eraseFile.rawValue, &outputFile))
    guard let file = outputFile else { throw encodingError(-1) }
    var closed = false
    defer { if !closed { ExtAudioFileDispose(file) } }
    try checkEncodingStatus(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                                    formatSize, format.streamDescription))
    var converter: AudioConverterRef?
    var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
    try checkEncodingStatus(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter,
                                                    &converterSize, &converter))
    guard let converter else { throw encodingError(-1) }
    // Set the actual converter bitrate. AVAudioFile's format settings alone do
    // not apply this bitrate at every source rate (44.1 kHz defaults to 128 kbps).
    var bitrate = aacBitRate(for: converter)
    try checkEncodingStatus(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                                      UInt32(MemoryLayout<UInt32>.size), &bitrate))
    var config: UnsafeRawPointer? = nil
    try checkEncodingStatus(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                                    UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
        throw encodingError(-1)
    }
    while source.framePosition < source.length {
        try source.read(into: buffer)
        if buffer.frameLength == 0 { break }
        try checkEncodingStatus(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList))
    }
    // A successful close includes the AAC tail and container metadata.
    let status = ExtAudioFileDispose(file)
    closed = true
    try checkEncodingStatus(status)
}

/// Apple's MPEG-4 AAC encoder rates for mono output.
private let aacSampleRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

func aacSampleRate(for sourceSampleRate: Double) -> Double {
    if aacSampleRates.contains(sourceSampleRate) { return sourceSampleRate }
    if sourceSampleRate > 48_000 {
        return sourceSampleRate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000
    }
    return aacSampleRates.first { $0 >= sourceSampleRate } ?? 48_000
}

/// Keep the target bitrate where the encoder accepts it; low rates cap below it.
func aacBitRate(for converter: AudioConverterRef, target: UInt32 = 48_000) -> UInt32 {
    var size: UInt32 = 0
    guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates,
                                        &size, nil) == noErr,
          size >= UInt32(MemoryLayout<AudioValueRange>.stride) else { return target }
    var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                   count: Int(size) / MemoryLayout<AudioValueRange>.stride)
    guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates,
                                    &size, &ranges) == noErr else { return target }
    let valid = ranges.prefix(Int(size) / MemoryLayout<AudioValueRange>.stride)
        .filter { $0.mMaximum > 0 }
    let wanted = Double(target)
    if valid.contains(where: { $0.mMinimum <= wanted && wanted <= $0.mMaximum }) { return target }
    if let below = valid.filter({ $0.mMaximum <= wanted }).map(\.mMaximum).max() {
        return UInt32(below)
    }
    if let above = valid.filter({ $0.mMinimum > 0 }).map(\.mMinimum).min() {
        return UInt32(above)
    }
    return target
}

private func checkEncodingStatus(_ status: OSStatus) throws {
    if status != noErr { throw encodingError(status) }
}

private func encodingError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
}
