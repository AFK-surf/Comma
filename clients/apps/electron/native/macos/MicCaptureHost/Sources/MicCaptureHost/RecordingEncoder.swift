import AVFoundation
import AudioToolbox
import Foundation

/// Encode the completed mono mix in fixed-size buffers without capture or TCC access.
func encodeRecording(input: URL, output: URL) throws {
    let source = try AVAudioFile(forReading: input)
    let format = source.processingFormat
    var aac = AudioStreamBasicDescription()
    aac.mFormatID = kAudioFormatMPEG4AAC
    aac.mSampleRate = format.sampleRate
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
    var bitrate: UInt32 = 48_000
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
        try checkEncodingStatus(ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList))
    }
    // A successful close includes the AAC tail and container metadata.
    let status = ExtAudioFileDispose(file)
    closed = true
    try checkEncodingStatus(status)
}

private func checkEncodingStatus(_ status: OSStatus) throws {
    if status != noErr { throw encodingError(status) }
}

private func encodingError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
}
