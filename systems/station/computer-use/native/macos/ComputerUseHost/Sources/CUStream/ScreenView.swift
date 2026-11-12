// A view of a screen on one daemon connection, ported from still.fail (github.com/AFK-surf/still.fail, afk/main
// b928883a23) station/native/helper/Sources/StillfailHelper/ScreenView.swift: its messages (`run`), its encoders
// (`makeSession`: H.265 where asked and this Mac's hardware encodes it, else H.264; a JPEG a picture for `codec: "jpeg"`),
// a picture encoded only once one is asked for and only a new one unless a key frame is asked for (`pump`, `encoded`,
// `next`, `keyframe`: a frame the encoder dropped is still owed, from a key frame if one was asked), a still screen's key
// frame encoded finer (`setFiner`), the bit rate and the bounds asked as it runs (`rate`, `bounds`), the colours tagged
// sRGB or Display P3 (`colors`), and the display woken and kept on (`wake`). What captures the pictures and posts the
// input is a subclass's, as still.fail's SimulatorView is a ScreenView: ScreenStreamSession (an app's windows or a
// display) and SimulatorStreamSession (an iOS Simulator).
//
// After the request line (CommaComputerUseSocketServer.swift: `{control: "screen.view", view, auth_token}`) the
// connection carries still.fail's messages (ScreenChannel), its numbers and layouts:
//   in   1 next      (empty)  the next new picture, encoded
//        2 keyframe  (empty)  the next one a key frame, the screen changed or not
//        3 input     JSON     the subclass's form (RemoteInputInjector.swift, SimulatorStreamSession.swift)
//        4 clipboard 1 byte flags (bit 0: paste with ⌘V), 1 byte type (1 text, 2 PNG), the bytes: set (ScreenClipboard.swift)
//        5 watch     1 byte   1: say each copy made on the Mac from now on (message 5 out), 0: stop
//        7 rate      4 bytes  bits a second (big-endian) to encode at from the next frame on
//        8 bounds    JSON     {maxWidth, maxHeight}: the pictures from now on fitted into these (a config first)
//        9 audio     (empty)  the next 20 ms packet of the system output (a view opened with `audio: true`:
//                             SystemAudio.swift), sent once there is one
//   out  1 info      JSON     first: {width, height, encoder, codec, …}, or {error, code: "capture"|"restart"|"display"|
//                             "app"|"encoder"|"simulator"}; (Cue) again, before a config, when a session made anew
//                             encodes with another codec or encoder (a fallback): {width, height, encoder, codec}
//        2 config    4 bytes width, 4 bytes height, then the avcC or hvcC (none for JPEG): before the first frame and
//                             whenever it changes
//        3 frame     1 byte flags (bit 0: key frame), 8 bytes timestamp (µs), then the frame (AVCC or HVCC, or a JPEG)
//        4 event     JSON     what went wrong as it runs ({stopped}, {bounds}, {audio})
//        5 clipboard 1 byte type (1 text, 2 PNG), the bytes: what was copied, while watched
//        6 cursor    JSON     {x, y, shape} (0..1 of the picture; a CSS cursor's name) as it moves or changes
//        8 audio config JSON  {codec: "pcm_s16le" | "opus", sampleRate: 48000, channels: 2} after the info, or {error}
//                             (no more audio); `opus` (Cue's) to a view opened with `audioCodec: "opus"`
//        9 audio     8 bytes timestamp (µs, the frames' clock), then 3840 bytes: 960 frames of stereo PCM16 little-endian;
//                             or one Opus packet of those 960 frames
// Cue's own, beside them (no kind still.fail has; station/src/screens/screen-pipe.ts reads them):
//   out  64 target   JSON     an app's view as its windows move: {target, apps, windows, x, y, width, height, control}
//        65 device   JSON     a simulator's: {orientation, pose?} (degrees clockwise; a foldable's pose)
//        66 timing   32 bytes a view opened `timing: true`, just before each frame: its timestamp, when the encoder took
//                             it, gave it out, and when it is sent (4 × 8 bytes µs on HostClock, big-endian)
// Deviations from still.fail's (station/docs/desktop-screen.md, "The Mac's helper"): no part of the display (`region`, 7
// out) and no reveal (6) yet; their messages are let be. The clipboard and the system output are an app's or a display's
// view's (ScreenStreamSession); a simulator's lets their messages be. No synthetic
// pictures. A low-latency session that fails every frame (a virtual machine's) is made again without low latency, and
// the software encoder is named by what VideoToolbox says it chose, as Cue's H264Encoder did. `pace` keeps a preview's
// pictures apart (Cue's simulator previews ask 2 a second). A key frame comes only when asked, not each 10 s.
import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import IOKit.pwr_mgt
import VideoToolbox

open class ScreenView: NSObject, @unchecked Sendable {
    public let channel: ScreenChannel
    /// The view's bounds: as it opened, then as the station asks (`bounds`).
    var maxWidth: Int
    var maxHeight: Int
    /// The most frames a second: the encoder's rate control expects no more than 60 of them.
    let fps: Int
    /// The bit rate asked when the view opened, then as the station asks (`rate`); none: the picture's size's.
    var bitrate: Int?
    /// "h264", "h265" (H.264 where this Mac has no hardware encoder of it), or "jpeg".
    let jpeg: Bool
    let hevc: Bool
    /// The pictures in Display P3 (`gamut: "p3"`, a video's only), else in sRGB: never the display's own space (a
    /// wide-gamut display's colours, shown as sRGB, come out washed out).
    let p3: Bool
    /// The pictures' colours as the stream says them (its VUI), and the same as a picture's attachments.
    var colors: [(CFString, CFString)] {
        [
            (kVTCompressionPropertyKey_ColorPrimaries, p3 ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_sRGB),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
    }
    var colorTags: [(CFString, CFString)] {
        zip([kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey], colors.map(\.1)).map { ($0, $1) }
    }
    /// What the session encodes: "h264", "h265", or "jpeg".
    var codec = "h264"
    lazy var images = CIContext(options: [.useSoftwareRenderer: false])
    /// Everything below happens on this queue.
    public let queue: DispatchQueue
    /// Makes the encoder: VideoToolbox's, or a test's stand-in (FrameEncoder.swift).
    let encoders: FrameEncoders
    var session: FrameEncoder?
    var size = (0, 0)
    var encoder = ""
    /// The latest picture, whether it was encoded yet, and when it was captured (µs).
    var latest: CVPixelBuffer?
    var latestAt: Int64 = 0
    var fresh = false
    /// Frames asked for and not given yet; one is being encoded.
    var wanted = 0
    var encoding = false
    var forceKey = true
    /// The key frame asked is of the picture last encoded (the screen at rest, sent again sharper), and whether the
    /// session encodes finer now: its QP at most `stillQP`, at twice the bit rate, where that is `stillFrom` or more.
    var still = false
    var finer = false
    let stillQP = 28
    let stillFrom = 4_000_000
    var lastTs: Int64 = 0
    var lastConfig = Data()
    /// (Cue) The codec and encoder the last info said: a session made anew with another (a fallback) says it again.
    var toldCodec = ""
    var toldEncoder = ""
    var ended = false
    /// Keeps the display on while the view is open (0: none held).
    var awake: IOPMAssertionID = 0
    /// Cue: low-latency rate control tried first, until a session of it fails every frame; whether this session is one,
    /// and whether it has given a frame yet.
    var lowLatency = true
    var sessionLowLatency = false
    var sessionEncoded = false
    /// Cue: the least time between two pictures (ns; 0: none), and when the last went, and a pump armed for then.
    var pace: UInt64 = 0
    var encodedAt: UInt64 = 0
    var pumpArmed = false
    /// Cue: each frame's times said (message 66), and when the encoder took the one it encodes (µs, HostClock).
    let timing: Bool
    var encodeStart: Int64 = 0

    public init(channel: ScreenChannel, options: [String: Any], label: String, encoders: @escaping FrameEncoders = VTFrameEncoder.make) {
        self.channel = channel
        self.encoders = encoders
        queue = DispatchQueue(label: label, qos: .userInteractive)
        maxWidth = min(8192, max(16, (options["maxWidth"] as? NSNumber)?.intValue ?? 1920))
        maxHeight = min(8192, max(16, (options["maxHeight"] as? NSNumber)?.intValue ?? 1080))
        fps = min(120, max(1, (options["fps"] as? NSNumber)?.intValue ?? 60))
        bitrate = (options["bitrate"] as? NSNumber).map { min(maxBitrate, max(100_000, $0.intValue)) }
        jpeg = (options["codec"] as? String) == "jpeg"
        hevc = (options["codec"] as? String) == "h265"
        p3 = !jpeg && (options["gamut"] as? String) == "p3"
        timing = (options["timing"] as? Bool) == true
    }

    /// Until the connection ends: the capture started, the station's asks answered.
    public func run() {
        start()
        // A picture on the clipboard is the largest message.
        while let (kind, payload) = channel.message(limit: 2 + ScreenClipboard.pngMax) {
            switch kind {
            case 1: next()
            case 2: keyframe()
            case 3:
                if let op = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] { post(op) }
            case 7:
                if payload.count == 4 { rate(Int(payload.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })) }
            case 8:
                if let b = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                   let w = (b["maxWidth"] as? NSNumber)?.intValue, let h = (b["maxHeight"] as? NSNumber)?.intValue {
                    bounds(w, h)
                }
            case 4: setClipboard(payload)
            case 5: watchClipboard(payload)
            case 9: nextAudio()
            default: break
            }
        }
        stop()
    }

    // MARK: what a subclass does

    /// Starts capturing; says the info (`opened`) or an error as message 1. Returns once either is said.
    open func start() {}

    /// A person's input, posted.
    open func post(_ op: [String: Any]) {}

    /// The bounds changed (on `queue`): the capture asked for the size they take, where it can.
    open func resized() {}

    /// Message 4: the clipboard set, and pasted (ScreenClipboard `set`); none where the view has no clipboard.
    open func setClipboard(_ payload: Data) {}

    /// Message 5: the clipboard watched or not (ScreenClipboard `watch`).
    open func watchClipboard(_ payload: Data) {}

    /// Message 9: the next packet of the system output (SystemAudio `next`); none where it is not captured.
    open func nextAudio() {}

    open func stop() {
        queue.sync {
            ended = true
            session?.invalidate()
            session = nil
            latest = nil
        }
        if awake != 0 {
            IOPMAssertionRelease(awake)
            awake = 0
        }
    }

    // MARK: capture

    /// The source's size fitted into the view's bounds, never larger, in even pixels (what 4:2:0 encodes).
    func fitted(_ width: Int, _ height: Int) -> (Int, Int) {
        let scale = min(1.0, Double(maxWidth) / Double(width), Double(maxHeight) / Double(height))
        let even = { (v: Double) in max(2, Int(v.rounded()) & ~1) }
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// The first picture's size known, on `queue`: the encoder made, the info said (`more` beside what still.fail says).
    func opened(_ width: Int, _ height: Int, _ more: [String: Any] = [:]) {
        if jpeg {
            encoder = "JPEG, quality 0.8"
            codec = "jpeg"
            channel.sendJSON(1, info(width, height).merging(more) { a, _ in a })
            return pump()
        }
        if !makeSession(width, height) {
            channel.sendJSON(1, ["error": "no H.264 encoder", "code": "encoder"])
            return
        }
        channel.sendJSON(1, info(width, height).merging(more) { a, _ in a })
        pump()
    }

    /// What the view's first message says it is.
    func info(_ width: Int, _ height: Int) -> [String: Any] {
        toldCodec = codec
        toldEncoder = encoder
        return ["width": width, "height": height, "encoder": encoder, "codec": codec]
    }

    /// The display woken (as a person touching the Mac does) and kept on until the view ends: a display asleep is
    /// captured black.
    func wake() {
        let reason = "A Comma view of this screen is open" as CFString
        var activity: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity(reason, kIOPMUserActiveLocal, &activity)
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &awake)
    }

    /// A new picture, on `queue`: kept as the latest, encoded once one is wanted.
    func took(_ buffer: CVPixelBuffer, _ at: Int64) {
        if ended { return }
        latest = buffer
        latestAt = at
        fresh = true
        still = false
        pump()
    }

    /// A picture's stamp: µs on the station's clock (HostClock).
    func now() -> Int64 { HostClock.now() }

    // MARK: encoding

    func makeSession(_ width: Int, _ height: Int) -> Bool {
        session?.invalidate()
        session = nil
        // Hardware with low-latency rate control first (frames come out as they go in), then hardware, then any; H.265
        // (asked for) on the hardware only, H.264 where it is not had (a codec's settings once it is kept: one size's
        // session made anew keeps the codec it had).
        let low: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true, kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let hardware: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let h265 = hevc && (encoder.isEmpty || codec == "h265")
        var tries: [(String, String, [CFString: Any])] = []
        if h265 {
            if lowLatency { tries.append(("h265", "hardware, low latency", low)) }
            tries.append(("h265", "hardware", hardware))
        }
        if lowLatency { tries.append(("h264", "hardware, low latency", low)) }
        tries += [("h264", "hardware", hardware), ("h264", "", [:])]
        for (kind, name, specification) in tries {
            guard let made = encoders(kind == "h265" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, width, height, specification) else { continue }
            let set = { (key: CFString, value: Any) in made.set(key, value as CFTypeRef) }
            _ = set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
            _ = set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
            // H.264: Baseline, as every decoder takes it (constrained where the system has it); Main if neither is taken.
            // H.265: Main.
            var profile = "default"
            let profiles = kind == "h265" ? [kVTProfileLevel_HEVC_Main_AutoLevel] : [kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, kVTProfileLevel_H264_Baseline_AutoLevel, kVTProfileLevel_H264_Main_AutoLevel]
            for p in profiles where set(kVTCompressionPropertyKey_ProfileLevel, p) == noErr {
                profile = p as String
                break
            }
            let rate = bitrate ?? max(1_000_000, width * height * 3)
            _ = set(kVTCompressionPropertyKey_AverageBitRate, rate)
            _ = set(kVTCompressionPropertyKey_ExpectedFrameRate, min(fps, 60))
            // (Cue) A key frame only when asked for, not each 10 s: the stream is reliable and in order, so one repairs
            // nothing, and on a still screen it was the only large frame (127 to 195 KB at 1920×1080) and went 1 to 5 s
            // late. An hour apart at most: 0 is the encoder's own interval (the software H.264 one's is 4 frames).
            _ = set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600)
            _ = set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 3600 * 60)
            // The pictures' colours in the stream's VUI (as each picture is tagged: `colors`).
            for (key, value) in colors { _ = set(key, value) }
            made.prepare()
            // (Cue) The last try names no hardware: VideoToolbox says which it chose.
            var used = name
            if used.isEmpty {
                used = made.onHardware == true ? "hardware" : "software"
            }
            finer = false
            session = made
            sessionLowLatency = specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] != nil
            sessionEncoded = false
            size = (width, height)
            codec = kind
            encoder = "\(used), \(profile), \(rate) bps"
            return true
        }
        return false
    }

    /// Encodes the latest picture when one is wanted and it is new (or a key frame was asked for).
    func pump() {
        if jpeg { return pumpJPEG() }
        guard !ended, wanted > 0, !encoding, fresh, let picture = latest else { return }
        if paced() { return }
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        if session == nil || (width, height) != size {
            if !makeSession(width, height) { return }
            forceKey = true
            return pump()
        }
        guard let current = session else { return }
        wanted -= 1
        encoding = true
        fresh = false
        let key = forceKey
        forceKey = false
        setFiner(key && still && (bitrate ?? 0) >= stillFrom, current)
        still = false
        let ts = max(lastTs + 1, latestAt)
        lastTs = ts
        // The encoder writes the VUI from the picture's own tags over the session's: each the same.
        for (key, value) in colorTags { CVBufferSetAttachment(picture, key, value, .shouldPropagate) }
        if timing { encodeStart = now() }
        let status = current.encode(picture, at: CMTime(value: ts, timescale: 1_000_000), key: key) { status, sample in
            let done = self.timing ? self.now() : 0
            self.queue.async { self.encoded(status, sample, ts, key, done) }
        }
        if status != noErr {
            encoding = false
            wanted += 1
            forceKey = forceKey || key
        }
    }

    /// (Cue) Whether the next picture waits for `pace`: a pump is armed for when it may go.
    func paced() -> Bool {
        guard pace > 0 else { return false }
        let now = DispatchTime.now().uptimeNanoseconds
        if encodedAt > 0, now < encodedAt + pace {
            if !pumpArmed {
                pumpArmed = true
                queue.asyncAfter(deadline: .now() + .nanoseconds(Int(encodedAt + pace - now))) {
                    self.pumpArmed = false
                    self.pump()
                }
            }
            return true
        }
        encodedAt = now
        return false
    }

    func encoded(_ status: OSStatus, _ sample: CMSampleBuffer?, _ ts: Int64, _ asked: Bool, _ done: Int64 = 0) {
        encoding = false
        if ended { return }
        guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else {
            // (Cue, after its H264Encoder) A low-latency session can be made where no hardware encoder is (a virtual
            // machine) and then fails every frame: made again without it.
            if sessionLowLatency, !sessionEncoded, let session {
                lowLatency = false
                session.invalidate()
                self.session = nil
            }
            // Dropped: still owed, and from a key frame if one was asked for.
            wanted += 1
            forceKey = forceKey || asked
            fresh = latest != nil
            return pump()
        }
        sessionEncoded = true
        // (Cue) A session made anew with another codec or encoder than the info said (the low-latency one fell back):
        // an info again before its config and frame, as the viewer's statistics go by the info. The first info's
        // geometry is not said again.
        if codec != toldCodec || encoder != toldEncoder, let format = CMSampleBufferGetFormatDescription(sample) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            channel.sendJSON(1, info(Int(dimensions.width), Int(dimensions.height)))
        }
        if let format = CMSampleBufferGetFormatDescription(sample),
           let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let avcC = atoms[codec == "h265" ? "hvcC" : "avcC"] as? Data, avcC != lastConfig {
            lastConfig = avcC
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            var config = Data()
            var w = UInt32(dimensions.width).bigEndian, h = UInt32(dimensions.height).bigEndian
            config.append(Data(bytes: &w, count: 4))
            config.append(Data(bytes: &h, count: 4))
            config.append(avcC)
            channel.send(2, config)
        }
        var key = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            key = !notSync
        }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: 9 + length)
        payload[0] = key ? 1 : 0
        var be = UInt64(ts).bigEndian
        payload.replaceSubrange(1..<9, with: Data(bytes: &be, count: 8))
        payload.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress! + 9)
        }
        if timing { channel.send(66, timingPayload(ts, encodeStart, done, now())) }
        channel.send(3, payload)
        pump()
    }

    /// The latest picture as one JPEG, when one is wanted and it is new (or a key frame was asked for: every one is).
    func pumpJPEG() {
        guard !ended, wanted > 0, fresh, let picture = latest else { return }
        if paced() { return }
        wanted -= 1
        fresh = false
        forceKey = false
        let width = CVPixelBufferGetWidth(picture), height = CVPixelBufferGetHeight(picture)
        if (width, height) != size {
            size = (width, height)
            var config = Data()
            var w = UInt32(width).bigEndian, h = UInt32(height).bigEndian
            config.append(Data(bytes: &w, count: 4))
            config.append(Data(bytes: &h, count: 4))
            channel.send(2, config)
        }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let data = images.jpegRepresentation(of: CIImage(cvPixelBuffer: picture), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [quality: 0.8]) else {
            wanted += 1
            return
        }
        let ts = max(lastTs + 1, latestAt)
        lastTs = ts
        var payload = Data([1])
        var be = UInt64(ts).bigEndian
        payload.append(Data(bytes: &be, count: 8))
        payload.append(data)
        channel.send(3, payload)
        pumpJPEG()
    }

    // MARK: asks

    public func next() {
        queue.async {
            self.wanted += 1
            self.pump()
        }
    }

    /// The pictures from now on fitted into `width`×`height`: the capture asked for the size that takes (its next
    /// picture is that size, and the encoder is made anew for it, from a key frame).
    public func bounds(_ width: Int, _ height: Int) {
        queue.async {
            defer { self.pump() }
            let w = min(8192, max(16, width)), h = min(8192, max(16, height))
            if (w, h) == (self.maxWidth, self.maxHeight) { return }
            self.maxWidth = w
            self.maxHeight = h
            self.resized()
        }
    }

    /// From the next frame on, about this many bits a second.
    public func rate(_ bits: Int) {
        queue.async {
            self.bitrate = min(maxBitrate, max(100_000, bits))
            if let session = self.session {
                session.set(kVTCompressionPropertyKey_AverageBitRate, (self.finer ? self.bitrate! * 2 : self.bitrate!) as CFTypeRef)
            }
        }
    }

    /// The pictures from the next on encoded finer (a still one's key frame) or as the moving ones are. An encoder that
    /// takes no QP bound keeps its own (the bit rate's rise alone).
    func setFiner(_ on: Bool, _ session: FrameEncoder) {
        if on == finer { return }
        finer = on
        session.set(kVTCompressionPropertyKey_MaxAllowedFrameQP, (on ? stillQP : 51) as CFTypeRef)
        if let bitrate {
            session.set(kVTCompressionPropertyKey_AverageBitRate, (on ? bitrate * 2 : bitrate) as CFTypeRef)
        }
    }

    public func keyframe() {
        queue.async {
            self.forceKey = true
            // The same picture again, as a key frame, when the screen does not change: encoded finer.
            if self.latest != nil {
                self.still = !self.fresh
                self.fresh = true
            }
            self.pump()
        }
    }
}

/// Message 66's payload: each stamp 8 bytes big-endian.
func timingPayload(_ stamps: Int64...) -> Data {
    var data = Data(capacity: 8 * stamps.count)
    for stamp in stamps {
        var be = UInt64(max(0, stamp)).bigEndian
        data.append(Data(bytes: &be, count: 8))
    }
    return data
}

/// The most a stream is asked to encode at: the station's pace goes no higher (screen-pace.ts MAX_RATE).
let maxBitrate = 60_000_000

public struct ScreenStreamError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public var errorDescription: String? { description }
    init(_ description: String) { self.description = description }
}
