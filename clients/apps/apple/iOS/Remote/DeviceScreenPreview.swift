#if DEBUG
import CoreMedia
import MetalKit
import SwiftUI
import VideoToolbox

/// A device's live page without a station, for looking at it in a simulator: launched with
/// `-DeviceScreenPreview <posture id>` (an iPhone Duo in that posture) or `-DeviceScreenPreview plain` (a device drawn
/// flat). Its pictures are a test pattern that says each corner and the picture's top, encoded as H.264 and decoded as a
/// station's frames are; a finger on it marks where it lands. `-DeviceScreenPreviewSlow YES` moves between postures
/// over 6 s; `-DeviceScreenPreviewThen <posture id>` moves to another posture after a moment.
struct DeviceScreenPreviewPage: View {
    @State private var preview: DeviceScreenPreview

    static var requested: String? { UserDefaults.standard.string(forKey: "DeviceScreenPreview") }

    init(_ request: String) {
        _preview = State(initialValue: DeviceScreenPreview(request))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CommaTheme.bgPrimary.ignoresSafeArea()
                DeviceScreenPanel(session: preview.session, screen: preview.screen, via: "direct", close: {}, retry: {},
                                  postureDuration: UserDefaults.standard.bool(forKey: "DeviceScreenPreviewSlow") ? 6 : 0.6)
            }
            // As the device's page shows (`PhoneDeviceScreenView`).
            .navigationTitle(Text(verbatim: preview.screen.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .persistentSystemOverlays(.hidden)
        }
    }
}

@MainActor final class DeviceScreenPreview {
    let session: DeviceScreenSession
    let screen: ListedDeviceScreen
    private var standing: DuoPosture?
    private var finger: CGPoint?
    private var frame = 0

    init(_ request: String) {
        let duo = request != "plain"
        let row: NSDictionary = [
            "id": "simulator:preview", "instance": "preview", "title": duo ? "iPhone Duo" : "iPhone",
            "capabilities": ["buttons": ["home", "lock", "volume", "rotate"], "poses": duo ? ["closed", "open"] : [],
                             // (a phone's panel, its corners a share of its width: drawn in a plain body)
                             "panels": duo ? [] : [["width": 700, "height": 1018, "corners": [0.12, 0.12, 0.12, 0.12]]]],
            "postures": duo ? DuoPosture.all.map { posture -> NSDictionary in
                ["id": posture.id, "screen": posture.screen.rawValue, "opening": posture.opening,
                 "stand": posture.stand.rawValue, "orientation": posture.orientation, "pose": posture.pose]
            } : [],
        ]
        screen = ListedDeviceScreen(row)!
        session = DeviceScreenSession(scope: nil, device: "preview", screen: screen.id, instance: screen.instance,
                                      postures: screen.postures)
        session.previewSink = { [weak self] message in self?.take(message) }
        session.take(["type": "open", "view": 1])
        session.take(["type": "state", "state": ["control": true, "switches": true]])
        let first = DuoPosture.all.first { $0.id == request }
        session.choose(posture: first ?? DuoPosture.all[0])
        stand(first ?? DuoPosture.all[5])
        // `-DeviceScreenPreviewThen <posture id>`: moves to it after a moment, as a person choosing it would.
        if let then = UserDefaults.standard.string(forKey: "DeviceScreenPreviewThen"),
           let next = DuoPosture.all.first(where: { $0.id == then }) {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                session.choose(posture: next)
            }
        }
    }

    /// What the page sends, as a station would take it: a posture after a moment, a finger at once.
    private func take(_ message: [String: Any]) {
        if let id = message["posture"] as? String, let next = DuoPosture.all.first(where: { $0.id == id }) {
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                stand(next)
            }
        }
        if let input = message["input"] as? [String: Any], input["t"] as? String == "pointer",
           let x = (input["x"] as? NSNumber)?.doubleValue, let y = (input["y"] as? NSNumber)?.doubleValue {
            finger = CGPoint(x: x, y: y)
            draw()
        }
    }

    private func stand(_ posture: DuoPosture) {
        standing = posture
        session.take(["type": "state", "state": ["pose": posture.pose, "orientation": posture.orientation]])
        draw()
    }

    /// One picture of the screen that is on, turned as the station turns it, through the station's codec.
    private func draw() {
        let posture = standing ?? DuoPosture.all[5]
        let screenOn = screen.postures.isEmpty ? DuoPosture.Screen.cover : posture.screen
        let base = screenOn == .cover ? CGSize(width: 700, height: 1018) : CGSize(width: 1004, height: 1426)
        let size = posture.landscape ? CGSize(width: base.height, height: base.width) : base
        let image = Self.pattern(size: size, label: "\(screenOn.rawValue) \(posture.orientation)°", finger: finger)
        guard let (config, data) = Self.encode(image) else { return }
        if frame == 0 || session.picture != size {
            session.take(["type": "config", "codec": "h264", "description": config.base64EncodedString(),
                          "width": Int(size.width), "height": Int(size.height)])
        }
        frame += 1
        session.take(["type": "video", "ts": Double(frame), "key": true, "data": data])
    }

    static func pattern(size: CGSize, label: String, finger: CGPoint?) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            UIColor(red: 0.12, green: 0.16, blue: 0.28, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 1, alpha: 0.18).setStroke()
            cg.setLineWidth(2)
            for x in stride(from: 0, through: size.width, by: size.width / 8) { cg.stroke(CGRect(x: x, y: 0, width: 0, height: size.height)) }
            for y in stride(from: 0, through: size.height, by: size.height / 8) { cg.stroke(CGRect(x: 0, y: y, width: size.width, height: 0)) }
            let corner = min(size.width, size.height) / 6
            for (color, x, y) in [(UIColor.systemRed, 0.0, 0.0), (.systemGreen, size.width - corner, 0.0),
                                  (.systemBlue, 0.0, size.height - corner), (.systemYellow, size.width - corner, size.height - corner)] {
                color.setFill()
                cg.fill(CGRect(x: x, y: y, width: corner, height: corner))
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: min(size.width, size.height) / 9, weight: .bold), .foregroundColor: UIColor.white,
            ]
            let top = NSAttributedString(string: "▲ TOP", attributes: attributes)
            top.draw(at: CGPoint(x: (size.width - top.size().width) / 2, y: corner * 0.3))
            let name = NSAttributedString(string: label, attributes: attributes)
            name.draw(at: CGPoint(x: (size.width - name.size().width) / 2, y: (size.height - name.size().height) / 2))
            if let finger {
                UIColor.systemPink.setFill()
                let r = min(size.width, size.height) / 24
                cg.fillEllipse(in: CGRect(x: finger.x * size.width - r, y: finger.y * size.height - r, width: 2 * r, height: 2 * r))
            }
        }.cgImage!
    }

    /// One key frame of `image` as H.264: its avcC and its length-prefixed NAL units, as a station sends them.
    static func encode(_ image: CGImage) -> (Data, Data)? {
        let width = image.width, height = image.height
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixels) == kCVReturnSuccess,
              let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                         compressionSessionOut: &made) == noErr, let session = made else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        nonisolated(unsafe) var out: (Data, Data)?
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary,
                                        infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let format = CMSampleBufferGetFormatDescription(sample),
                  let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? NSDictionary,
                  let avcC = atoms["avcC"] as? Data, let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            out = (avcC, data)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return out
    }
}
#endif
