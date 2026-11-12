import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Testing
import VideoToolbox
@testable import CUStream

/// A stand-in for VideoToolbox's session: the CI's virtual Macs can hang in the first `VTCompressionSessionCreate` of a
/// process (FrameEncoder.swift). It gives a frame for each picture, on another thread, as VideoToolbox does: a key frame
/// where asked, the session's first, and each `MaxKeyFrameInterval`-th (every 4th where none is set, as the software
/// H.264 encoder's). `CU_REAL_ENCODER=1` runs these tests on VideoToolbox instead, to compare the two on a Mac.
final class FakeEncoder: FrameEncoder, @unchecked Sendable {
    let codec: CMVideoCodecType
    let width: Int, height: Int
    let lock = NSLock()
    var interval = 4
    var sinceKey: Int?

    init(_ codec: CMVideoCodecType, _ width: Int, _ height: Int) {
        self.codec = codec
        self.width = width
        self.height = height
    }

    func set(_ key: CFString, _ value: CFTypeRef) -> OSStatus {
        if key == kVTCompressionPropertyKey_MaxKeyFrameInterval, let frames = value as? NSNumber, frames.intValue > 0 {
            lock.withLock { interval = frames.intValue }
        }
        return noErr
    }

    func prepare() {}

    var onHardware: Bool? { false }

    func encode(_ picture: CVPixelBuffer, at ts: CMTime, key: Bool, done: @escaping @Sendable (OSStatus, CMSampleBuffer?) -> Void) -> OSStatus {
        let sync = lock.withLock {
            let sync = key || sinceKey.map { $0 + 1 >= interval } ?? true
            sinceKey = sync ? 0 : sinceKey! + 1
            return sync
        }
        let sample = frame(at: ts, key: sync)
        DispatchQueue.global().async { done(noErr, sample) }
        return noErr
    }

    func invalidate() {}

    /// A sample as VideoToolbox gives one: the codec's configuration atom, `NotSync` on all but a key frame.
    func frame(at ts: CMTime, key: Bool) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        let atoms = [codec == kCMVideoCodecType_HEVC ? "hvcC" : "avcC": Data([1, 2, 3, 4])]
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: codec, width: Int32(width), height: Int32(height),
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: 16, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: 16, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: ts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true)! as NSArray
        (attachments[0] as! NSMutableDictionary)[kCMSampleAttachmentKey_NotSync] = !key
        return sample!
    }
}

private func encoders(_ codec: CMVideoCodecType, _ width: Int, _ height: Int, _ specification: [CFString: Any]) -> FrameEncoder? {
    if ProcessInfo.processInfo.environment["CU_REAL_ENCODER"] == "1" {
        return VTFrameEncoder.make(codec, width, height, specification)
    }
    return FakeEncoder(codec, width, height)
}

/// A view's two ends: the helper's channel, and the station's socket read here.
private func pair() -> (ScreenChannel, Int32) {
    var fds: [Int32] = [0, 0]
    socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    return (ScreenChannel(fd: fds[0]), fds[1])
}

/// The next message the station is sent within `ms`, or nil.
private func message(_ fd: Int32, within ms: Int32 = 3000) -> (UInt8, Data)? {
    var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, ms) > 0 else { return nil }
    return ScreenChannel(fd: fd).message(limit: 1 << 24)
}

/// The next frame (message 3), past an info or a config.
private func frame(_ fd: Int32) -> Data? {
    while let (kind, payload) = message(fd) {
        if kind == 3 { return payload }
    }
    return nil
}

private func picture(_ shade: UInt8) -> CVPixelBuffer {
    var made: CVPixelBuffer?
    CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
    let buffer = made!
    CVPixelBufferLockBaseAddress(buffer, [])
    memset(CVPixelBufferGetBaseAddress(buffer), Int32(shade), CVPixelBufferGetDataSize(buffer))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

/// A picture is encoded only once the station asks for one (still.fail's `next`): a screen that changes while the
/// view does not ask sends nothing, and the asked frame is of the latest picture.
@Test
func framesGoOnlyWhenAsked() throws {
    let (channel, station) = pair()
    defer { close(station); close(channel.fd) }
    let view = ScreenView(channel: channel, options: ["maxWidth": 64, "maxHeight": 64, "codec": "h264"], label: "test", encoders: encoders)
    view.queue.sync { view.opened(64, 64) }
    #expect(message(station)?.0 == 1)
    view.queue.sync {
        view.took(picture(10), 1)
        view.took(picture(200), 2)
    }
    #expect(message(station, within: 300) == nil)
    view.next()
    let first = try #require(frame(station))
    #expect(first[0] & 1 == 1)
    #expect(message(station, within: 300) == nil)
    view.stop()
}

/// A frame the encoder dropped is still owed, and from a key frame if one was asked for (still.fail
/// ScreenView.swift `encoded`: "Dropped: still owed…"): a decoder that asked for one gets it.
@Test
func aDroppedKeyFrameIsStillOwed() throws {
    let (channel, station) = pair()
    defer { close(station); close(channel.fd) }
    let view = ScreenView(channel: channel, options: ["maxWidth": 64, "maxHeight": 64, "codec": "h264"], label: "test", encoders: encoders)
    view.queue.sync { view.opened(64, 64) }
    view.queue.sync { view.took(picture(10), 1) }
    view.next()
    _ = try #require(frame(station))
    view.next()
    view.queue.sync { view.took(picture(90), 2) }
    _ = try #require(frame(station))
    // The station asks a key frame; the encoder drops it.
    view.queue.sync {
        view.forceKey = false
        view.encoding = true
        view.encoded(-12902, nil, 3, true)
    }
    let owed = try #require(frame(station))
    #expect(owed[0] & 1 == 1)
    view.stop()
}

/// A low-latency session that fails its first frame is made again without low latency: the viewer is told the encoder
/// it has now (a new info) before that session's config and frame, as its statistics go by the info. After astra's
/// review probe of #4981.
@Test
func aFallbackEncoderIsSaidBeforeItsFrames() throws {
    let (channel, station) = pair()
    defer { close(station); close(channel.fd) }
    let view = ScreenView(channel: channel, options: ["maxWidth": 64, "maxHeight": 64, "codec": "h264"], label: "test", encoders: encoders)
    view.queue.sync { view.opened(64, 64) }
    let first = try #require(message(station))
    #expect(first.0 == 1)
    let opened = try #require(JSONSerialization.jsonObject(with: first.1) as? [String: Any])
    view.queue.sync {
        view.latest = picture(10)
        // As a virtual machine's: a low-latency session that has given no frame fails one.
        view.sessionLowLatency = true
        view.sessionEncoded = false
        view.encoding = true
        view.encoded(-12902, nil, 1, true)
    }
    let next = try #require(message(station))
    #expect(next.0 == 1, "an info before the new session's config and frame")
    let said = try #require(JSONSerialization.jsonObject(with: next.1) as? [String: Any])
    #expect(said["codec"] as? String == "h264")
    #expect((said["encoder"] as? String)?.contains("low latency") == false)
    #expect(said["encoder"] as? String != opened["encoder"] as? String)
    #expect(message(station)?.0 == 2)
    #expect(message(station)?.0 == 3)
    view.stop()
}

/// A screen that changes little for longer than 10 s gets no key frame of its own accord: only the first, and those the
/// station asks. The stream is reliable and in order, so a periodic key frame repairs nothing; on a still screen it is the
/// only large frame (127–195 KB at 1920×1080), and the link took 1–5 s for each (Cue, 2026-11-08).
@Test
func noKeyFrameUnasked() throws {
    let (channel, station) = pair()
    defer { close(station); close(channel.fd) }
    let view = ScreenView(channel: channel, options: ["maxWidth": 64, "maxHeight": 64, "codec": "h264", "bitrate": 1_000_000], label: "test", encoders: encoders)
    view.queue.sync { view.opened(64, 64) }
    var keys: [Bool] = []
    // A small change each half second for 15 s (capture times in µs).
    for i in 0..<31 {
        view.queue.sync { view.took(picture(UInt8(10 + i % 2)), Int64(i) * 500_000) }
        view.next()
        let got = try #require(frame(station))
        keys.append(got[0] & 1 == 1)
    }
    #expect(keys.first == true)
    #expect(keys.dropFirst().allSatisfy { !$0 }, "key frames at \(keys.indices.filter { keys[$0] })")
    // One the station asks still comes.
    view.keyframe()
    view.next()
    let asked = try #require(frame(station))
    #expect(asked[0] & 1 == 1)
    view.stop()
}

/// A view opened `timing` says each frame's times just before it (message 66): its timestamp, when the encoder took it
/// and gave it out, when it is sent, in order on HostClock. One opened without says none. Both views and their sockets
/// last to the end, so a late write of one never lands on a socket the other reuses.
@Test(.timeLimit(.minutes(1)))
func timingComesBeforeEachFrameWhenAsked() throws {
    let stamp = { (data: Data, at: Int) in
        Int64(data.subdata(in: at..<(at + 8)).withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) })
    }
    var opened: [(ScreenView, ScreenChannel, Int32)] = []
    defer {
        for (view, channel, station) in opened {
            view.stop()
            close(station)
            close(channel.fd)
        }
    }
    for asked in [true, false] {
        let (channel, station) = pair()
        let view = ScreenView(channel: channel, options: ["maxWidth": 64, "maxHeight": 64, "codec": "h264", "timing": asked], label: "test", encoders: encoders)
        opened.append((view, channel, station))
        view.queue.sync { view.opened(64, 64) }
        let captured = HostClock.now()
        view.queue.sync { view.took(picture(10), captured) }
        view.next()
        var stamps: [Int64]?
        var sent: Int64?
        // (an info, a second info and a config where the encoder fell back, then the frame: a few messages at most)
        for _ in 0..<8 {
            guard let (kind, payload) = message(station) else { break }
            if kind == 66 { stamps = (0..<4).map { stamp(payload, $0 * 8) } }
            if kind == 3 {
                sent = stamp(payload, 1)
                break
            }
        }
        let ts = try #require(sent, "no frame (timing \(asked))")
        if !asked {
            #expect(stamps == nil)
        } else {
            // The frame it names is the one after it. Its timestamp is the capture's, or one more where the encoder
            // dropped the first try (a VM's low-latency session, made again without it): `lastTs + 1`.
            let said = try #require(stamps)
            #expect(said[0] == ts, "\(said) before frame \(ts)")
            #expect(ts >= captured && ts <= captured + 2, "frame \(ts), captured \(captured)")
            #expect(said[1] >= captured && said[2] >= said[1] && said[3] >= said[2], "\(said)")
        }
    }
}
