import AVFoundation
import Foundation
import Testing

@testable import QuickChatHost

@Test func clipsRespectBothAudioEdges() async throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 62 * 16_000))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData?[0])
    samples.initialize(repeating: 0, count: Int(buffer.frameLength))
    let recording = Recording(format: format)
    recording.write(buffer)

    let encoded = await recording.m4a(from: 1, through: 61)
    let data = try #require(encoded)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuickChat-test-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let audio = try AVAudioFile(forReading: url)
    let duration = Double(audio.length) / audio.processingFormat.sampleRate
    // Allow one AAC frame of encoder padding, not an entire microphone buffer.
    #expect(abs(duration - 60) < 0.07)
}

@Test func adjacentClipsKeepEveryPCMFrameExactlyOnce() throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let recording = Recording(format: format)
    var original: [Float] = []
    for block in 0..<3 {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<1024 {
            let sample = Float(block * 1024 + index) / 4096
            samples[index] = sample
            original.append(sample)
        }
        recording.write(buffer)
    }
    let boundary = 0.0731234567
    let adjacent = recording.audio(from: 0, through: boundary) +
        recording.audio(from: boundary, through: recording.duration)
    let actual = adjacent.flatMap { buffer in
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    #expect(actual == original)
}
