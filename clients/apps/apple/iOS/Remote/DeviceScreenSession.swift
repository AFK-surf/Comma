import CoreGraphics
import Foundation
import Observation
import UIKit

/// One view of a device a computer's station lists (an iOS Simulator, an Android emulator) over the mesh, as the
/// desktop's `meshScreenStream.ts` keeps one: `devices.openScreenView` runs for as long as the view does and says its
/// frames as progress; each frame shown is acknowledged, which is what the station paces the next by. A view that
/// went after it showed opens again by itself; one refused, or never shown, fails.
///
/// It opens on Watch. When the station says no agent holds the device, it drives (Control) and offers no choice; while
/// an agent's lease lasts, it watches so the agent's input reaches the device, and offers the choice. A station from
/// before says nothing of agents: the view then stays on Watch and offers the choice once a picture shows.
@MainActor @Observable final class DeviceScreenSession {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
    }

    struct AgentPointer: Equatable {
        let x: Double
        let y: Double
        let down: Bool
    }

    let renderer = ScreenVideoRenderer()
    /// A device drawn as a 3D model (an iPhone Duo) takes its frames as Metal textures instead of the renderer's layer.
    let textures: ScreenTextureDecoder?
    /// The ways the device can be shown and held (`DuoPosture`); none for one that does not both close and open.
    let postures: [DuoPosture]
    /// How it is drawn flat: its panels, and its case where its computer has Xcode's (`DeviceFrame`).
    let look: DeviceLook
    private(set) var phase = Phase.connecting
    /// The picture's size in pixels, from its config: the shape the touch area takes.
    private(set) var picture = CGSize.zero
    /// Whether this view drives the device now.
    private(set) var control = false
    /// Watch and Control are offered (an agent's lease lasts, or the station says nothing of agents).
    private(set) var offersChoice = false
    private(set) var agent = false
    private(set) var agentPointer: AgentPointer?
    /// How a foldable stands now (`closed`, `book`, `open`), as its station says; nil until it says.
    private(set) var pose: String?
    /// How far the device is turned, clockwise, as its station says; nil until it says.
    private(set) var orientation: Int?
    /// A foldable's hinge angle, 0 closed to 180 flat, where its station says: what tells a tent or a laptop apart.
    private(set) var hinge: Int?
    /// Its picture is its panel's own, never turned (the station says `panel`): its UI's turn plays on it live.
    private(set) var panel = false
    /// The posture the device shows in: the one chosen while the station brings the device to it, else the one that
    /// shows how it stands.
    private(set) var posture: DuoPosture?
    /// Why the station did not let this view drive.
    private(set) var refused: String?

    private let scope: WorkspaceSettingsScope?
    private let device: String
    private let screen: String
    private let instance: String
    private var view: Int?
    private var shown = false
    private var saysAgent = false
    private var switches = false
    private var outgoing: AsyncStream<Outgoing>.Continuation?
    private var tries = 0
    /// The station ended the view with a capture refusal: a person retries it.
    private var endedRefused = false
    /// When a posture was chosen: it stays while the station brings the device to it, at most `postureWait`.
    private var chosenAt: Date?
    /// The screen shown when a posture was chosen: a choice on that screen only turns the device (`follows`).
    private var chosenFrom: DuoPosture.Screen?
    private static let postureWait: TimeInterval = 10
    #if DEBUG
    /// A preview without a station takes what the view would send.
    var previewSink: (([String: Any]) -> Void)?
    #endif

    // A view that went after it showed comes back after each of these; the picture stays meanwhile.
    private static let againAfterMs = [500, 1000, 2000, 4000, 8000]
    /// The open view, kept while a page runs it and this long after the last one stops: a page SwiftUI builds again
    /// (as a turn of the phone can) takes it up as it is, rather than opening the view again.
    private static let keptFor: Duration = .seconds(3)
    private var link: Task<Void, Never>?
    private var runners = 0
    private var letGo: Task<Void, Never>?
    /// The open views by what they show, while they are open: a page built again for the same device takes its own.
    private static var open: [String: Weak] = [:]
    private struct Weak { weak var session: DeviceScreenSession? }
    /// The picture's greatest side: about what the phone shows of it. A 3D device shows its screen at about half the
    /// phone's display; a flat picture fills it.
    private let maxSide: Int

    init(scope: WorkspaceSettingsScope?, device: String, screen: String, instance: String, postures: [DuoPosture] = [],
         look: DeviceLook = .none) {
        self.scope = scope; self.device = device; self.screen = screen; self.instance = instance
        self.postures = postures
        self.look = look
        textures = postures.isEmpty ? nil : ScreenTextureDecoder()
        posture = postures.first
        let display = UIScreen.main.nativeBounds.size
        maxSide = postures.isEmpty ? Int(max(display.width, display.height)) : 1200
    }

    /// The session open for this device now, or a new one.
    static func reusing(scope: WorkspaceSettingsScope, device: String, screen: String, instance: String,
                        postures: [DuoPosture], look: DeviceLook) -> DeviceScreenSession {
        let key = [scope.workspace.id, device, screen, instance].joined(separator: "\u{1F}")
        if let kept = open[key]?.session, kept.link != nil { return kept }
        let made = DeviceScreenSession(scope: scope, device: device, screen: screen, instance: instance, postures: postures,
                                       look: look)
        open = open.filter { $0.value.session != nil }
        open[key] = Weak(session: made)
        return made
    }

    /// The shape the device is drawn flat at: its picture's, and before one comes its first panel's, so that its body
    /// shows while it connects (as the desktop's stage draws a listed device's first shape).
    var frameSize: CGSize {
        if picture.width > 0, picture.height > 0 { return picture }
        if let first = look.cases.first { return CGSize(width: first.width, height: first.height) }
        if let first = look.panels.first { return CGSize(width: first.width, height: first.height) }
        return .zero
    }

    /// The case it stands in now, as its picture's shape and its turn say; none without one.
    var caseLayout: DeviceCaseLayout? {
        let size = frameSize
        guard textures == nil, size.width > 0, size.height > 0 else { return nil }
        return DeviceCaseLayout.of(look.cases, ratio: Double(size.width / size.height), orientation: orientation)
    }

    /// The case's pictures as it stands, once they have come; `askCase` asks the computer for them.
    func casePictures(_ layout: DeviceCaseLayout) -> DeviceCasePictures? {
        scope.flatMap { DeviceCasePictureStore.came(DeviceCasePictureStore.key($0, device, layout)) }
    }

    func askCase(_ layout: DeviceCaseLayout) async {
        guard let scope else { return }
        await DeviceCasePictureStore.ask(scope, device: device, screen: screen, layout: layout)
    }

    /// The picture's turn from its screen's framebuffer (`DuoPicture.turn`): none for its panel's own picture.
    var turn: Int { panel ? 0 : DuoPicture.turn(orientation: orientation, picture: picture) }

    /// Whether the model turns as the device says, with its UI's turn playing live on its panel's own picture: a turn on
    /// the screen it shows. A change of screen turns it at once: the new panel's way up is said only after it shows.
    var follows: Bool { panel && (chosenFrom == nil || chosenFrom == posture?.screen) }

    /// How the device's UI stands, which the model stands by: as the station says it, with its panel's own picture.
    var standing: Int { panel ? ((orientation ?? 0) % 360 + 360) % 360 : turn }

    /// The screen that shows: the cover while the device is closed, the inner one while it opens.
    var screenOn: DuoPosture.Screen {
        guard let pose else { return posture?.screen ?? .cover }
        return pose == "closed" ? .cover : .inner
    }

    /// Runs the view until the calling task is cancelled or it fails for good. The view stays open `keptFor` after
    /// the last caller goes, for one that comes back.
    func run() async {
        runners += 1
        letGo?.cancel()
        letGo = nil
        if link == nil {
            let made = Task { await self.keep() }
            link = made
            Task {
                await made.value
                if self.link == made { self.link = nil }
            }
        }
        while !Task.isCancelled, link != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        runners -= 1
        guard runners == 0, let running = link else { return }
        letGo = Task {
            try? await Task.sleep(for: Self.keptFor)
            guard !Task.isCancelled, self.runners == 0, self.link == running else { return }
            running.cancel()
            self.link = nil
        }
    }

    private func keep() async {
        let (messages, continuation) = AsyncStream<Outgoing>.makeStream(bufferingPolicy: .bufferingNewest(256))
        outgoing = continuation
        guard let core = scope?.store.core else { return }
        // What goes to the view goes in order (a finger's press, moves and lift), one call after another.
        let sender = Task {
            for await message in messages {
                _ = try? await core.call("devices.sendToScreenView", message.params)
            }
        }
        defer {
            continuation.finish()
            sender.cancel()
            outgoing = nil
        }
        while !Task.isCancelled {
            var failure: Error = CoreError(code: "ended", message: String(localized: "The screen stopped."))
            endedRefused = false
            do {
                try await open()
            } catch {
                failure = error
            }
            if Task.isCancelled { return }
            view = nil
            renderer.reset()
            textures?.reset()
            // Never shown, or refused: trying again by itself cannot help. A view that showed and went comes back.
            guard shown, !endedRefused, (failure as? CoreError)?.code != "forbidden", tries < Self.againAfterMs.count else {
                phase = .failed(failure.localizedDescription)
                return
            }
            phase = .connecting
            try? await Task.sleep(for: .milliseconds(Self.againAfterMs[tries]))
            tries += 1
        }
    }

    /// Asks Watch (false) or Control (true) of the open view.
    func choose(control on: Bool) {
        refused = nil
        control = on
        guard let view, switches else { return }
        outgoing?.yield(Outgoing(params: ["view": view, "control": on]))
    }

    /// One input event (`screenStreamInput.ts`'s device events), while this view drives.
    func send(_ input: [String: Any]) {
        guard control else { return }
        #if DEBUG
        if let previewSink { previewSink(["input": input]); return }
        #endif
        guard let view else { return }
        outgoing?.yield(Outgoing(params: ["view": view, "input": input]))
    }

    /// Moves the device to `next`, while this view drives: the core sends the fold and the quarter turns it needs
    /// (`screen-postures.ts`), and the model shows `next` meanwhile.
    func choose(posture next: DuoPosture) {
        guard control, postures.contains(next) else { return }
        chosenFrom = screenOn
        posture = next
        chosenAt = Date()
        #if DEBUG
        if let previewSink { previewSink(["posture": next.id]); return }
        #endif
        guard let view else { return }
        outgoing?.yield(Outgoing(params: ["view": view, "posture": next.id]))
    }

    /// Keeps the posture shown in step with how the device stands: a chosen one while the device gets there (or
    /// once it stands so), else the one its station's state says.
    private func followPosture() {
        guard !postures.isEmpty else { return }
        let shown = DuoPosture.standing(pose: pose, turn: standing, hinge: hinge, of: postures)
        // Still so: its fold and picture, and its hinge where the station says it (another person may have moved it).
        if let posture, posture.matches(pose: pose, turn: standing), hinge == nil || shown == posture {
            chosenAt = nil
            return
        }
        if let chosenAt, Date().timeIntervalSince(chosenAt) < Self.postureWait { return }
        chosenAt = nil
        if let shown { posture = shown }
    }

    /// What goes to the open view, made once and never changed after.
    struct Outgoing: @unchecked Sendable {
        let params: [String: Any]
    }

    private func open() async throws {
        guard let scope, scope.current else { throw CancellationError() }
        let params: [String: Any] = [
            "workspace": scope.workspace.id, "device": device, "target": screen, "instance": instance,
            "codecs": ["h265", "h264"], "control": control, "maxWidth": maxSide, "maxHeight": maxSide,
            // 流畅: a phone keeps cool. 自动 lets the bit rate go to the picture's pixels × 16 a second (a Duo's panel at
            // 1600: 29 Mbit/s), which a phone receives, decrypts and decodes all the while the page shows.
            "quality": "smooth",
            // A device with postures is drawn in 3D, turned: its panel's own picture, its UI turning on it live.
            "panel": !postures.isEmpty,
        ]
        switches = false
        var asked = params
        // Pictures straight from the core where it hands them over (no JSON, no base64), on the core's thread: each
        // copied once and taken on the main queue as a progress event would be, in the order they came.
        let token = scope.store.core.screenSink { [weak self] frame in
            guard let event = Self.event(of: frame) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.take(event.value) } }
        }
        defer { token?.close() }
        if let token { asked["sink"] = token.id }
        _ = try await scope.store.core.call("devices.openScreenView", asked) { [weak self] event in
            // On the client's queue, in order: the main queue keeps that order.
            DispatchQueue.main.async { MainActor.assumeIsolated { if let object = event.object { self?.take(object) } } }
        }
    }

    /// A frame from the core's sink as the view's progress says one (`config`, `video`), its bytes copied.
    private nonisolated static func event(of frame: ScreenFrame) -> SendableEvent? {
        switch frame.kind {
        case 1, 2:
            return SendableEvent([
                "type": "config", "codec": frame.kind == 2 ? "h265" : "h264", "width": frame.width, "height": frame.height,
                "description": Data(frame.bytes).base64EncodedString(),
            ])
        case 3, 4:
            return SendableEvent(["type": "video", "ts": frame.ts, "key": frame.kind == 4, "data": Data(frame.bytes)])
        default:
            return nil
        }
    }

    /// An event made on the core's thread, handed to the main queue whole and never changed after.
    private struct SendableEvent: @unchecked Sendable {
        let value: NSDictionary
        init(_ value: [String: Any]) { self.value = value as NSDictionary }
    }

    /// One of the view's events (`open`, `config`, `video`, `state`).
    func take(_ object: NSDictionary) {
        guard let type = object.string("type") else { return }
        switch type {
        case "open":
            view = object.int("view")
        case "config":
            let width = object.int("width") ?? 0, height = object.int("height") ?? 0
            picture = CGSize(width: width, height: height)
            let codec = object.string("codec") ?? "h264", description = object.text("description") ?? ""
            if let textures {
                textures.configure(codec: codec, description: description, width: width, height: height)
            } else {
                renderer.configure(codec: codec, description: description, width: width, height: height)
            }
            followPosture()
        case "video":
            guard let ts = object.double("ts") else { return }
            let data = object["data"] as? Data ?? Data()
            let key = object.bool("key")
            if !(textures?.show(data, key: key) ?? renderer.show(data, key: key)), let view {
                outgoing?.yield(Outgoing(params: ["view": view, "keyframe": true]))
            } else if !shown || phase != .live {
                shown = true
                tries = 0
                phase = .live
                // A station from before says nothing of agents: the person chooses.
                if !saysAgent { offersChoice = true }
            }
            if let view { outgoing?.yield(Outgoing(params: ["view": view, "ack": ts])) }
        case "state":
            if let state = object.object("state") { take(state: state) }
        default:
            break
        }
    }

    private func take(state: NSDictionary) {
        if state["control"] != nil {
            if state["switches"] != nil { switches = state.bool("switches") }
            control = state.bool("control")
        }
        if let why = state.string("refused") {
            refused = why
            control = false
        }
        if state["agent"] != nil {
            saysAgent = true
            let on = state.bool("agent")
            agent = on
            offersChoice = on
            if !on { agentPointer = nil }
            // No agent: this view drives. An agent: it watches, so the agent's input reaches the device.
            if control == on { choose(control: !on) }
        }
        if state.string("endedCode") == "screen_refused" { endedRefused = true }
        if let pose = state.string("pose") { self.pose = pose }
        if let orientation = state.int("orientation") { self.orientation = orientation }
        if let hinge = state.int("hinge") { self.hinge = hinge }
        if state["pose"] != nil || state["orientation"] != nil { panel = state.bool("panel") }
        if state["pose"] != nil || state["orientation"] != nil || state["hinge"] != nil { followPosture() }
        if let at = state.object("agentPointer"), let x = at.double("x"), let y = at.double("y") {
            agentPointer = AgentPointer(x: x, y: y, down: at.bool("down"))
        }
    }
}
