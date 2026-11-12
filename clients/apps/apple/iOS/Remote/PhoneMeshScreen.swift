import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
import os

/// A view of a computer's screen, or of one of its devices, over the mesh: the core's `devices.openScreenView` gives its
/// frames as the call's progress (core screen-views.ts), VideoToolbox decodes them on an `AVSampleBufferDisplayLayer`,
/// and each frame shown is acknowledged, which the station paces the next by. Touches go back as the station's input.
/// Where the mesh does not reach the screen (`unavailable`), the page says the computer is out of reach.
@MainActor @Observable
final class PhoneMeshScreenModel {
    enum Phase: Equatable { case connecting, live, unavailable, failed(String) }

    let core: any CoreAPI
    let workspace: String
    let device: String
    /// `display`, or a device the station lists (`simulator:<udid>`, `android:<serial>`).
    let target: String
    let instance: String?
    private(set) var phase: Phase = .connecting
    /// Whether this view drives the screen now.
    private(set) var control: Bool
    /// The picture's size in pixels, once its first config came.
    private(set) var size: CGSize?
    /// How the device stands, in degrees clockwise.
    private(set) var orientation = 0
    /// An agent leases the device; where its finger is, as a share of the picture.
    private(set) var agent = false
    private(set) var agentPointer: CGPoint?
    private(set) var refused: String?
    let sink = PhoneScreenSink()
    /// The open view, as the core numbers it.
    private(set) var view: Int?
    private var task: Task<Void, Never>?
    private var switches = false

    init(core: any CoreAPI, workspace: String, device: String, target: String, instance: String? = nil, control: Bool) {
        self.core = core; self.workspace = workspace; self.device = device; self.target = target
        self.instance = instance; self.control = control
    }

    var isDevice: Bool { target.hasPrefix("simulator:") || target.hasPrefix("android:") }

    /// The codes that say the mesh did not reach this screen, not that it cannot be shown (meshScreenStream.ts).
    static let notHere: Set<String> = ["unsupported", "unreachable", "unavailable", "timeout", "unknown_call"]

    /// Codes that end a view for good: trying again cannot help (screenFailure.ts `screenFailureRetries`).
    static let refusals: Set<String> = ["forbidden", "unauthorized", "screen_refused", "not_found", "invalid", "cancelled"]
    /// A view that went after it showed comes back after each of these (ms); one the mesh did not reach, after
    /// `unreachedAgainMs`. As the desktop's (meshScreenStream.ts, remoteScreenStream.ts).
    static let againAfterMs = [500, 1000, 2000, 4000, 8000]
    static let unreachedAgainMs = 30_000

    /// Opens the view and keeps it open until `stop`: it comes back by itself after it went, and a refusal ends it.
    func start() {
        guard task == nil else { return }
        phase = .connecting
        #if DEBUG
        watch()
        #endif
        task = Task { [weak self] in
            var tries = 0
            while !Task.isCancelled {
                guard let self, let ended = await self.once() else { return }
                if Self.refusals.contains(ended.code) { self.task = nil; return }
                let wait = Self.notHere.contains(ended.code) && !ended.wasLive
                    ? Self.unreachedAgainMs : Self.againAfterMs[min(tries, Self.againAfterMs.count - 1)]
                tries = ended.wasLive ? 0 : tries + 1
                try? await Task.sleep(for: .milliseconds(wait))
                if Task.isCancelled { return }
                self.phase = .connecting
            }
        }
    }

    private var watching: Task<Void, Never>?

    #if DEBUG
    /// A debug build's measured run: each second while it runs, how many pictures came and how many were drawn, in the
    /// log (`surf.comma.ios`, category `screen`). Started with `-CommaScreenBusy` it also keeps the core busy meanwhile
    /// (a listing of the computer's screens after another), to see whether pictures still come on time.
    private func watch() {
        let sink = self.sink, target = self.target
        let core = self.core, workspace = self.workspace, device = self.device
        watching = Task { [weak self] in
            let busy = ProcessInfo.processInfo.arguments.contains("-CommaScreenBusy")
            let json = ProcessInfo.processInfo.arguments.contains("-CommaScreenJSON")
            let load = busy ? Task {
                while !Task.isCancelled {
                    _ = try? await core.call("devices.listScreens", ["workspace": workspace, "device": device])
                }
            } : nil
            defer { load?.cancel() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled || self == nil { return }
                sink.queue.async {
                    let (received, drawn) = sink.takeCounts()
                    Self.log.info("screen-stats target=\(target, privacy: .public) received=\(received) drawn=\(drawn) busy=\(busy) json=\(json)")
                }
            }
        }
    }
    #endif

    nonisolated static let log = Logger(subsystem: "surf.comma.ios", category: "screen")

    /// One view, until it ends: its code and whether it had shown, or nil when it was stopped.
    private func once() async -> (code: String, wasLive: Bool)? {
        var params: [String: Any] = ["workspace": workspace, "device": device, "target": target,
                                     "codecs": ["h265", "h264"], "control": control]
        if let instance { params["instance"] = instance }
        let sink = self.sink
        let box = PhoneScreenEvents(model: self)
        // Pictures straight from the core where it hands them over (no JSON, no base64); else as progress.
        #if DEBUG
        // A measured run started with `-CommaScreenJSON` takes the pictures as progress, as before the core handed them over.
        let asProgress = ProcessInfo.processInfo.arguments.contains("-CommaScreenJSON")
        #else
        let asProgress = false
        #endif
        let token = asProgress ? nil : core.screenSink { frame in box.native(frame) }
        defer { token?.close() }
        if let token { params["sink"] = token.id }
        var code = "screen_ended"
        do {
            _ = try await core.call("devices.openScreenView", params) { progress in
                // Frames go to the layer off the main thread, in the order they came; the rest to the page.
                let type = progress.object?.string("type")
                if type == "video" || type == "config" {
                    sink.queue.async { box.frame(progress) }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { box.page(progress) } }
                }
            }
            let wasLive = phase == .live
            ended(nil)
            return (code, wasLive)
        } catch is CancellationError {
            return nil
        } catch let error as CoreError {
            if error.code == "cancelled" { return nil }
            code = error.code
            let wasLive = phase == .live
            ended(error)
            return (code, wasLive)
        } catch {
            code = "failed"
            ended(CoreError(code: code, message: error.localizedDescription))
        }
        return (code, false)
    }

    func stop() {
        watching?.cancel(); watching = nil
        task?.cancel(); task = nil; view = nil
        sink.reset()
    }

    private func ended(_ error: CoreError?) {
        view = nil
        sink.reset()
        guard let error else { phase = .failed(String(localized: "The screen stopped.")); return }
        phase = Self.notHere.contains(error.code) && phase != .live ? .unavailable : .failed(error.errorDescription ?? error.code)
    }

    fileprivate func opened(_ view: Int) { self.view = view }

    fileprivate func configured(_ size: CGSize) { self.size = size }

    fileprivate func shown(_ ts: Int64) {
        if phase != .live { phase = .live }
        send(["ack": NSNumber(value: ts)])
    }

    fileprivate func keyframe() { send(["keyframe": true]) }

    fileprivate func state(_ state: NSDictionary) {
        if state["switches"] != nil { switches = state.bool("switches") }
        if state["control"] != nil { control = state.bool("control") }
        refused = state.string("refused")
        if let turn = state.int("orientation") { orientation = turn }
        if state["agent"] != nil {
            let leased = state.bool("agent")
            if leased != agent {
                agent = leased
                // As the desktop's panel does: Watch while an agent drives, so its input reaches the device.
                setControl(!leased)
            }
            if !leased { agentPointer = nil }
        }
        if let pointer = state.object("agentPointer"), let x = pointer.double("x"), let y = pointer.double("y") {
            agentPointer = pointer.bool("down") ? CGPoint(x: x, y: y) : nil
        }
    }

    /// Watch or Control, on the open view where the station switches it there.
    func setControl(_ on: Bool) {
        guard on != control else { return }
        if switches, view != nil { send(["control": on]) } else { control = on }
    }

    /// A touch at `point` (0...1 of the picture): a finger on a device, the mouse's left button on a computer.
    func touch(_ kind: String, at point: CGPoint) {
        guard control, phase == .live else { return }
        let x = Double(min(1, max(0, point.x))), y = Double(min(1, max(0, point.y)))
        if isDevice {
            send(["input": ["t": "pointer", "kind": kind, "x": x, "y": y, "buttons": kind == "up" ? 0 : 1]])
        } else {
            send(["input": ["type": kind, "x": x, "y": y, "button": 0, "clicks": 1, "mods": [String]()]])
        }
    }

    /// A simulator's Home: Simulator.app's ⌘⇧H (sim-input.ts).
    func home() {
        guard control, target.hasPrefix("simulator:") else { return }
        for kind in ["down", "up"] {
            send(["input": ["t": "key", "kind": kind, "key": "h", "code": "KeyH", "mods": 4 | 8]])
        }
    }

    private func send(_ fields: [String: Any]) {
        guard let view else { return }
        var params = fields
        params["view"] = view
        Task { [core] in _ = try? await core.call("devices.sendToScreenView", params) }
    }
}

/// A frame's block on its way to the sink's queue, which alone touches it from then on.
private struct SendableBlock: @unchecked Sendable {
    let value: CMBlockBuffer?
    init(_ value: CMBlockBuffer?) { self.value = value }
}

/// What the core's progress hands over, to the model on the main thread and to the sink on its queue.
private final class PhoneScreenEvents: @unchecked Sendable {
    private weak var model: PhoneMeshScreenModel?
    private let sink: PhoneScreenSink
    @MainActor init(model: PhoneMeshScreenModel) { self.model = model; sink = model.sink }

    @MainActor func page(_ progress: CoreJSON) {
        guard let model, let event = progress.object else { return }
        switch event.string("type") {
        case "open": if let view = event.int("view") { model.opened(view) }
        case "state": if let state = event.object("state") { model.state(state) }
        default: break
        }
    }

    /// A picture straight from the core (`ScreenFrame`, no JSON), on the core's thread: copied once, then drawn on the
    /// sink's queue as `frame` draws one.
    func native(_ frame: ScreenFrame) {
        switch frame.kind {
        case 1, 2:
            let description = Data(frame.bytes)
            let codec = frame.kind == 2 ? "h265" : "h264"
            let width = frame.width, height = frame.height
            sink.queue.async { [self] in
                guard sink.configure(codec: codec, width: width, height: height, description: description) else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.model?.keyframe() } }
                    return
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.model?.configured(CGSize(width: width, height: height)) } }
            }
        case 3, 4:
            let ts = Int64(frame.ts)
            let block = SendableBlock(PhoneScreenSink.block(copying: frame.bytes))
            sink.queue.async { [self] in
                let drawn = block.value.map { sink.enqueue($0) } ?? false
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.model?.shown(ts)
                        if !drawn { self.model?.keyframe() }
                    }
                }
            }
        default:
            break
        }
    }

    /// On the sink's queue: a config makes the decoder's format, a frame is drawn and then acknowledged. A frame that
    /// could not be drawn is acknowledged too (the station would wait for it), and a key frame asked for.
    func frame(_ progress: CoreJSON) {
        guard let event = progress.object else { return }
        if event.string("type") == "config" {
            guard let codec = event.string("codec"), let width = event.int("width"), let height = event.int("height"),
                  let text = event.string("description"), let description = Data(base64Encoded: text),
                  sink.configure(codec: codec, width: width, height: height, description: description) else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.model?.keyframe() } }
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model?.configured(CGSize(width: width, height: height)) } }
            return
        }
        guard let ts = (event["ts"] as? NSNumber)?.int64Value else { return }
        let bytes = (event["data"] as? NSDictionary)?.string("$bytes").flatMap { Data(base64Encoded: $0) }
        let drawn = bytes.map { sink.enqueue($0) } ?? false
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.model?.shown(ts)
                if !drawn { self.model?.keyframe() }
            }
        }
    }
}

/// The layer the frames are drawn on, and the state of its stream: touched only on `queue`, but for the layer the view
/// shows.
final class PhoneScreenSink: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    let queue = DispatchQueue(label: "comma-screen-frames")
    private var format: CMVideoFormatDescription?

    init() { layer.videoGravity = .resizeAspect }

    /// A stream's config: its codec and its avcC or hvcC. Nil when VideoToolbox cannot take it.
    func configure(codec: String, width: Int, height: Int, description: Data) -> Bool {
        let atom = codec == "h265" ? "hvcC" : "avcC"
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: description]] as CFDictionary
        var made: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec == "h265" ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            width: Int32(width), height: Int32(height), extensions: extensions, formatDescriptionOut: &made)
        guard status == noErr, let made else { format = nil; return false }
        format = made
        layer.sampleBufferRenderer.flush()
        return true
    }

    /// A frame's bytes in a block of their own: the one copy a picture is made of, on whatever thread has them.
    static func block(copying bytes: UnsafeRawBufferPointer) -> CMBlockBuffer? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { return nil }
        return block
    }

    /// One frame, length-prefixed as its config says, shown as soon as it is decoded. False: it could not be.
    func enqueue(_ data: Data) -> Bool {
        guard let block = data.withUnsafeBytes({ Self.block(copying: $0) }) else { return false }
        return enqueue(block)
    }

    /// Pictures that came and were drawn since the last `takeCounts` (on `queue`).
    private var received = 0
    private var drawn = 0

    func takeCounts() -> (Int, Int) {
        defer { received = 0; drawn = 0 }
        return (received, drawn)
    }

    /// One frame already in its block (`block(copying:)`), shown as soon as it is decoded. False: it could not be.
    func enqueue(_ block: CMBlockBuffer) -> Bool {
        received += 1
        let done = draw(block)
        if done { drawn += 1 }
        return done
    }

    private func draw(_ block: CMBlockBuffer) -> Bool {
        guard let format else { return false }
        if layer.sampleBufferRenderer.status == .failed { layer.sampleBufferRenderer.flush(); return false }
        var sample: CMSampleBuffer?
        var size = CMBlockBufferGetDataLength(block)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.sampleBufferRenderer.enqueue(sample)
        return true
    }

    func reset() {
        queue.async { [self] in format = nil; layer.sampleBufferRenderer.flush(removingDisplayedImage: true) }
    }
}

/// The picture with what it says around it: the agent's finger while one drives, and a simulator's Home.
struct PhoneMeshScreenView: View {
    let model: PhoneMeshScreenModel

    var body: some View {
        GeometryReader { geometry in
            let picture = Self.fitted(model.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                PhoneScreenLayer(model: model).frame(width: geometry.size.width, height: geometry.size.height)
                if let pointer = model.agentPointer, let picture {
                    Circle().fill(CommaTheme.textPrimary.opacity(0.35)).frame(width: 28, height: 28)
                        .position(x: picture.minX + pointer.x * picture.width, y: picture.minY + pointer.y * picture.height)
                        .allowsHitTesting(false)
                }
                if model.agent, let picture {
                    RoundedRectangle(cornerRadius: 8).stroke(CommaTheme.textPrimary.opacity(0.5), lineWidth: 2)
                        .frame(width: picture.width, height: picture.height).offset(x: picture.minX, y: picture.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel("Remote screen viewport")
    }

    /// Where a picture of `size` is drawn in `bounds`, as the layer's aspect fit puts it.
    static func fitted(_ size: CGSize?, in bounds: CGSize) -> CGRect? {
        guard let size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
}

/// The sink's layer in a view that turns its touches into the picture's shares.
private struct PhoneScreenLayer: UIViewRepresentable {
    let model: PhoneMeshScreenModel

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.model = model
        view.layer.addSublayer(model.sink.layer)
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) { view.model = model }

    final class TouchView: UIView {
        weak var model: PhoneMeshScreenModel?

        override func layoutSubviews() {
            super.layoutSubviews()
            model?.sink.layer.frame = bounds
        }

        private func share(_ touches: Set<UITouch>) -> CGPoint? {
            guard let touch = touches.first, let model,
                  let picture = PhoneMeshScreenView.fitted(model.size, in: bounds.size) else { return nil }
            let at = touch.location(in: self)
            return CGPoint(x: (at.x - picture.minX) / picture.width, y: (at.y - picture.minY) / picture.height)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let point = share(touches) { model?.touch("down", at: point) }
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let point = share(touches) { model?.touch("move", at: point) }
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let point = share(touches) { model?.touch("up", at: point) }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            if let point = share(touches) { model?.touch("up", at: point) }
        }
    }
}
