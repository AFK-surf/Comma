// The Mac's system output for a view that asks for it (`screen.view` with `audio: true`, station/src/screens/helper.ts),
// never the microphone: for a display, a Core Audio process tap without the Comma apps (SystemAudioTap.swift, `tapped`);
// for an app's view, or where the tap cannot start, ScreenCaptureKit's audio of the view's sound-only stream
// (ScreenStreamSession `listen`). 48 kHz stereo, made into 20 ms packets of interleaved PCM16 as Windows'
// comma-desktop-screen makes them (native/desktop-screen/src/audio.rs).
//
// Pulled as the station's transport takes them: message 9 in asks for one packet, sent as message 9 out once one is
// there (8 bytes timestamp, µs of the capture clock the video's frames have, then 3840 bytes, or one Opus packet of
// those 20 ms for a view that asked `audioCodec: "opus"`: about 64 kbit/s, a twentieth of PCM's, by AudioToolbox's
// own encoder); at most 300 ms is kept, the oldest dropped first. Message 8 out says the format once the capture is
// set up.
//
// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 3d517e022e) station/native/helper/Sources/
// StillfailHelper/SystemAudio.swift as it is: `SystemAudio` (`said`, `next`, the sample handler, `flush`, `stereo`,
// `interleave`) and `AudioPackets`. What differs: its channel is Cue's ScreenChannel, its queue's label is Cue's, and
// it also takes the tap's sound (`tapped`).
@preconcurrency import ScreenCaptureKit
import AVFoundation
import CoreMedia
import Foundation

final class SystemAudio: NSObject, SCStreamOutput, @unchecked Sendable {
    static let rate = 48_000
    static let channels = 2

    let channel: ScreenChannel
    /// Everything below happens on this queue (ScreenCaptureKit's audio comes on it too).
    let queue = DispatchQueue(label: "CommaComputerUse.ScreenAudio", qos: .userInteractive)
    private var packets = AudioPackets()
    /// A packet asked for and not sent yet.
    private var wanted = false
    /// A format it cannot take was said (an error, message 8): nothing more.
    private var refused = false

    /// What makes each packet Opus, for a view that asked it; nil: PCM16 (not asked, or the Mac cannot encode it).
    private let encoder: OpusPackets?

    init(channel: ScreenChannel, opus: Bool = false) {
        self.channel = channel
        encoder = opus ? OpusPackets() : nil
    }

    /// The format the packets are in (message 8), said before the first.
    func said() {
        channel.sendJSON(8, ["codec": encoder == nil ? "pcm_s16le" : "opus", "sampleRate": SystemAudio.rate, "channels": SystemAudio.channels])
    }

    /// One packet asked for (message 9 in): sent now when one is kept, else as one is made.
    func next() {
        queue.async {
            self.wanted = true
            self.flush()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !refused, sample.isValid, let format = CMSampleBufferGetFormatDescription(sample),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return }
        guard Int(asbd.mSampleRate) == SystemAudio.rate, let pcm = SystemAudio.stereo(sample, asbd) else {
            refused = true
            channel.sendJSON(8, ["error": "system audio in a format not taken: \(asbd.mSampleRate) Hz, flags \(asbd.mFormatFlags), \(asbd.mBitsPerChannel) bits"])
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let at = pts.isValid ? HostClock.stamp(uptime: Int64(CMTimeGetSeconds(pts) * 1_000_000)) : HostClock.now()
        packets.add(pcm, at: at)
        flush()
    }

    /// The tap's sound (SystemAudioTap): interleaved stereo PCM16 captured from `at` (µs of the capture clock).
    func tapped(_ pcm: [Int16], at: Int64) {
        queue.async {
            self.packets.add(pcm, at: at)
            self.flush()
        }
    }

    private func flush() {
        guard wanted, let (ts, pcm) = packets.pop() else { return }
        var data = pcm
        if let encoder {
            // (one in, one out: a packet the encoder gives nothing for is none to send; the next is)
            guard let encoded = encoder.encode(pcm) else { return }
            data = encoded
        }
        wanted = false
        var payload = Data(count: 8)
        var be = UInt64(max(0, ts)).bigEndian
        payload.replaceSubrange(0..<8, with: Data(bytes: &be, count: 8))
        payload.append(data)
        channel.send(9, payload)
    }

    /// A sample buffer's PCM as interleaved stereo PCM16: 32-bit float or 16-bit integer samples, interleaved or not;
    /// one channel given to both sides, past two the first two. Nil in any other format.
    static func stereo(_ sample: CMSampleBuffer, _ asbd: AudioStreamBasicDescription) -> [Int16]? {
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(asbd.mChannelsPerFrame)
        guard frames > 0, channels > 0 else { return [] }
        let float = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        let int16 = asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && asbd.mBitsPerChannel == 16
            && asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        guard float || int16 else { return nil }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr
        else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list).map { UnsafeRawBufferPointer(start: $0.mData, count: Int($0.mDataByteSize)) }
        return interleave(buffers, frames: frames, channels: channels, planar: planar, float: float)
    }

    /// `frames` frames of `channels` channels (each a buffer of its own when `planar`, else together in the first) as
    /// interleaved stereo PCM16; a buffer too short is silence where it ends.
    static func interleave(_ buffers: [UnsafeRawBufferPointer], frames: Int, channels: Int, planar: Bool, float: Bool) -> [Int16] {
        let width = float ? 4 : 2
        func value(_ channel: Int, _ frame: Int) -> Int16 {
            let (buffer, index) = planar ? (channel < buffers.count ? buffers[channel] : nil, frame) : (buffers.first, frame * channels + channel)
            guard let buffer, let base = buffer.baseAddress, (index + 1) * width <= buffer.count else { return 0 }
            if !float { return base.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) }
            let v = base.loadUnaligned(fromByteOffset: index * 4, as: Float32.self)
            return v.isFinite ? Int16((min(1, max(-1, v)) * 32767).rounded()) : 0
        }
        var out = [Int16](repeating: 0, count: frames * 2)
        let right = min(1, channels - 1)
        for frame in 0..<frames {
            out[frame * 2] = value(0, frame)
            out[frame * 2 + 1] = value(right, frame)
        }
        return out
    }
}

/// Interleaved stereo PCM16 as it comes, made into packets of exactly 960 frames (20 ms), each with the capture time of
/// its first frame; at most 15 kept (300 ms), the oldest dropped first. Sound that does not follow on from the last (a
/// gap, as ScreenCaptureKit, or the tap, sends nothing while nothing plays) starts a packet of its own: the part made before it is
/// dropped, not joined to it under a time it was not captured at.
struct AudioPackets {
    static let frames = 960
    static let bytes = frames * 4
    static let kept = 15
    /// How far from where the last sound ended new sound may start and still follow on (µs).
    static let slack: Int64 = 5_000

    private var building: [Int16] = []
    private var buildingAt: Int64 = 0
    /// Where the last sound added ends (µs); nil before any.
    private var end: Int64?
    private(set) var queued: [(Int64, Data)] = []

    /// `pcm` (interleaved stereo) captured from `at` (µs) on.
    mutating func add(_ pcm: [Int16], at: Int64) {
        let count = pcm.count / 2
        if let end, abs(at - end) > AudioPackets.slack { building.removeAll(keepingCapacity: true) }
        end = at + Int64(count) * 1_000_000 / Int64(SystemAudio.rate)
        var frame = 0
        while frame < count {
            if building.isEmpty { buildingAt = at + Int64(frame) * 1_000_000 / Int64(SystemAudio.rate) }
            let take = min(count - frame, AudioPackets.frames - building.count / 2)
            building.append(contentsOf: pcm[(frame * 2)..<((frame + take) * 2)])
            frame += take
            if building.count == AudioPackets.frames * 2 {
                let data = building.withUnsafeBufferPointer { b in Data(buffer: UnsafeBufferPointer(start: b.baseAddress, count: b.count)) }
                // Little-endian on every Mac this runs on (arm64, x86_64): the bytes as they are.
                if queued.count == AudioPackets.kept { queued.removeFirst() }
                queued.append((buildingAt, data))
                building.removeAll(keepingCapacity: true)
            }
        }
    }

    mutating func pop() -> (Int64, Data)? {
        queued.isEmpty ? nil : queued.removeFirst()
    }
}

/// 20 ms packets of interleaved stereo PCM16 at 48 kHz made into Opus packets of the same 20 ms (RFC 6716), one for
/// one, by AudioToolbox's encoder at BITRATE. Nil where the Mac has no such encoder.
/// Used on SystemAudio's queue alone.
final class OpusPackets: @unchecked Sendable {
    static let bitrate = 64_000

    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let format: AVAudioFormat

    init?() {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(SystemAudio.rate), channels: AVAudioChannelCount(SystemAudio.channels), interleaved: true),
            let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(AudioPackets.frames))
        else { return nil }
        var opus = AudioStreamBasicDescription(
            mSampleRate: Double(SystemAudio.rate), mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(AudioPackets.frames), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(SystemAudio.channels),
            mBitsPerChannel: 0, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &opus), let converter = AVAudioConverter(from: pcm, to: format) else { return nil }
        converter.bitRate = OpusPackets.bitrate
        self.converter = converter
        self.input = input
        self.format = format
    }

    /// One packet's PCM (3840 bytes) as one Opus packet; nil when the encoder gave none for it.
    func encode(_ pcm: Data) -> Data? {
        guard pcm.count == AudioPackets.bytes, let samples = input.int16ChannelData?[0] else { return nil }
        pcm.withUnsafeBytes { raw in _ = raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: AudioPackets.bytes)) }
        input.frameLength = AVAudioFrameCount(AudioPackets.frames)
        let out = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: max(1, converter.maximumOutputPacketSize))
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, said in
            if given {
                said.pointee = .noDataNow
                return nil
            }
            given = true
            said.pointee = .haveData
            return self.input
        }
        guard status != .error, error == nil, out.packetCount == 1, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }
}
