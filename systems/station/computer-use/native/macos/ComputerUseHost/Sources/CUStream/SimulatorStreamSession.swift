// A view of an iOS Simulator, ported from still.fail (github.com/AFK-surf/still.fail, afk/main b928883a23)
// station/native/helper/Sources/StillfailHelper/SimulatorView.swift: a ScreenView (ScreenView.swift: its messages, its
// encoders, a picture only when one is asked for and new) whose pictures are serve-sim's capture
// (systems/station/vendor/serve-sim), which reads the booted device's framebuffer through CoreSimulator, each new
// picture scaled into the view's bounds; its HID injector posts the input as the device's own touches, keys and
// buttons. macOS grants nothing for this (no Screen Recording, no Accessibility), and Simulator.app need not run. A turn
// holds the picture until the device has turned (`settleTurn`), so its UI is not seen going round inside the case.
//
// Input, message 3, one JSON object each (screens/sim-input.ts says them):
//   {op:"touch", type:"begin"|"move"|"end", x, y, edge?}, {op:"scroll", x, y, dx, dy},
//   {op:"key", type:"down"|"up", usage} (a USB HID keyboard usage), {op:"paste", text} (the device's pasteboard set,
//   then ⌘V; an app iOS refuses that ⌘V is allowed to paste for as long as the view lasts, `allowPaste`),
//   {op:"button", name} ("home", "lock", "siri", "side_button", "app_switcher", "volume_up", "volume_down", "keyboard"),
//   {op:"pose", name} (an iPhone Duo's hinge: "closed", "open"), {op:"hinge", degrees, ms} (to any angle, swept),
//   {op:"orient", turn} (straight to a picture's way up, quarters clockwise), {op:"rotate"} (the device turned a quarter; its
//   picture follows the physical turn, even when the app locks its UI upright), {op:"memory_warning"},
//   {op:"hid", page, usage, down} (a button of the device's case by its HID usage, sim-chrome.ts: held from down to up);
//   x, y 0..1 of the picture, edge 0 none, 2 top, 3 bottom (a system gesture).
//
// Cue's own: message 65 ({orientation, pose?}) says how the device stands as that changes (the degrees clockwise the
// picture is turned, and a foldable's pose), where still.fail's message 10 says the turn alone; `fps` keeps a preview's
// pictures apart (ScreenView `pace`); a turn goes clockwise, as the client's stage turns its frame.
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import SimNative
import SimNativeSupport
import VideoToolbox

public final class SimulatorStreamSession: ScreenView, @unchecked Sendable {
    private static let simctl = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
    private static let devicectl = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"
    private static let duoHelperName = "comma-duo-hid"

    private let udid: String
    /// Which boot of the device this is, from a station that says (`simulator.ts`).
    private let boot: String?
    let allowInput: Bool
    private let capture = FrameCapture()
    private let injector = HIDInjector()

    // A foldable's: what follows its panels, the panel shown (its hinge is the device's: `KnownHinges`).
    private var panels: Process?
    private var followed: AsyncStream<PanelSaid>.Continuation?
    private var coverShown: Bool?
    /// The panel the pictures sent are of: the one in use, once a change to it has drawn and settled (settlePanel). How
    /// the device stands is said of it, so that a client never puts the old panel's held picture on the new one.
    private var pictured: Bool?
    /// When the case's button held now went down (`hid`): only `perform` reads and sets it, one op after another.
    private var buttonDown: ContinuousClock.Instant?
    private var ops: AsyncStream<[String: Any]>.Continuation?
    /// The apps let paste from other apps while this view drives the device (`allowPaste`), set back as it ends, and
    /// whether it has ended: `perform` adds, `stop` takes them, under `pasting`.
    private var pasteAllowed: [String] = []
    private var pasteEnded = false
    private let pasting = NSLock()
    /// The "pasted from" banner's log, followed while this view drives the device (PasteBanner.swift); `stop` ends it.
    private let banner = PasteBanner()

    /// Guards `turn`, `limits` and `held`, read on the capture's queue and set by the tasks that look.
    private let scaling = NSLock()
    /// How far the picture is turned to stand as its panel's UI does, clockwise in quarter turns. A finger is turned back by it.
    private var turn = 0
    /// The picture as the panel draws it, never turned (a client that draws the device turned, its 3D iPhone Duo): the
    /// UI's own turn plays on it live, as on the device, and a finger lands as the panel has it. Asked by `frames`.
    private var panelFrames = false
    /// The bounds as the capture reads them (still.fail's `limits`).
    private var limits = (0, 0)
    /// The picture held while the device turns (settleTurn), and when it last drew something meanwhile.
    private var held = false
    /// A turn not yet settled (settleTurn): a panel change's hold waits for it, not to show the UI before it turned.
    private var turnPending = false
    /// A turn told before a sweep of the cover's mirroring, for once the hinge is there (`orient`).
    private var turnAfterSweep: (Int, Bool?, Bool)?
    /// How many panel transitions SpringBoard has said it ended (`followPanels`): a turn told during one is taken back.
    private var transitionsEnded: UInt64 = 0
    private var heldAt = ContinuousClock.now
    /// How the panel held for a change settles: what it drew last, and since when it has drawn about the same.
    private var heldLook = PanelLook.Settling()
    /// Counts the panel changes this view has shown: a hold for a panel ends only for the newest one.
    private var panelChanges: UInt64 = 0
    /// The device's framebuffer as last captured, for a key frame or a turn of a still screen.
    private var source: CVPixelBuffer?
    /// The device's screen as captured, in its pixels.
    private var screen = (0, 0)

    // Scaling and turning, guarded by `transferring`: the capture's queue and this one's both make pictures.
    private let transferring = NSLock()
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var rotation: VTPixelRotationSession?
    private var rotationTurn = 0
    private var rotationPool: CVPixelBufferPool?
    private var rotationSize = (0, 0)
    private var isOpen = false
    private var lastStands: (Int, String?, Int?, Bool)?

    public init(channel: ScreenChannel, options: [String: Any]) {
        udid = options["udid"] as? String ?? ""
        boot = options["boot"] as? String
        allowInput = (options["control"] as? Bool) ?? false
        panelFrames = (options["panel"] as? Bool) ?? false
        super.init(channel: channel, options: options, label: "CommaComputerUse.SimulatorStream")
        limits = (maxWidth, maxHeight)
        // (Cue) A preview asks a few pictures a second.
        if fps < 60 { pace = 1_000_000_000 / UInt64(fps) }
    }

    public override func start() {
        let started = DispatchSemaphore(value: 0)
        Task {
            defer { started.signal() }
            do {
                try await self.open()
            } catch {
                self.channel.sendJSON(1, ["error": "\(error)", "code": "simulator"])
            }
        }
        started.wait()
    }

    private func open() async throws {
        guard !udid.isEmpty else { throw ScreenStreamError("No simulator was named") }
        let helper = Bundle.main.resourceURL?.appendingPathComponent(Self.duoHelperName).path ?? ""
        try await injector.setup(deviceUDID: udid, duoHelper: helper)
        if let boot { KnownTurns.shared.update(udid, DeviceTurn()) { $0.booted(boot) } }
        DeviceOpenViews.shared.add(udid, self)
        if await injector.isFoldable() {
            if let boot { KnownHinges.shared.update(udid, DeviceHinge()) { $0.booted(boot) } }
            FoldingViews.shared.add(udid, self)
            await followPanels()
        } else if let said = await enumerated() {
            // A device left on its side by an earlier view stands so from the first picture.
            _ = setTurn(displayTurn(Self.turnOf(said, panel: "primary"), cover: nil))
        }
        let first = AsyncStream<(Int, Int)>.makeStream()
        await capture.setReemitsIdle(false)
        try await capture.start(deviceUDID: udid, pixelConsumers: PixelConsumerCount()) { [weak self] buffer, time, _ in
            guard let self else { return }
            let size = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
            first.continuation.yield(size)
            // (while it turns: what it draws is seen again once it has, as it stands: settleTurn)
            if self.heldForTurn(buffer) { return }
            // The framebuffer is the device's, used again for its next picture: scaled into one of ours now.
            guard let picture = self.scaled(buffer) else { return }
            let at = HostClock.stamp(uptime: Int64(CMTimeGetSeconds(time) * 1_000_000))
            self.queue.async {
                self.screen = size
                self.source = buffer
                self.sayDevice(); self.took(picture, at)
            }
        }
        // Its first picture says its size. A device asleep still has one: the black screen.
        let size = await withTaskGroup(of: (Int, Int)?.self) { group in
            group.addTask {
                for await size in first.stream { return size }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let size = await group.next() ?? nil
            group.cancelAll()
            first.continuation.finish()
            return size
        }
        guard let (width, height) = size else {
            throw ScreenStreamError("the simulator showed no picture")
        }
        let (stream, continuation) = AsyncStream<[String: Any]>.makeStream()
        ops = continuation
        // From the open, not the first paste: a device just booted is seconds slow to start following its log.
        if allowInput { banner.follow(PasteBanner.command(simctl: Self.simctl, udid: udid)) }
        Task { [weak self] in
            for await op in stream { await self?.perform(op) }
        }
        queue.sync {
            screen = (width, height)
            let turned = framesTurn() % 2 == 1
            let (w, h) = fitted(turned ? height : width, turned ? width : height)
            isOpen = true
            opened(w, h, ["capture": "CoreSimulator"])
        }
        tellDevice()
    }

    public override func stop() {
        panels?.terminate()
        followed?.finish()
        ops?.finish()
        banner.end()
        // What this view allowed goes back to what the device asks of the app: each app's own Paste prompt.
        pasting.lock()
        let allowed = pasteAllowed
        pasteAllowed = []
        pasteEnded = true
        pasting.unlock()
        for app in allowed { Self.disallowPaste(udid, app) }
        super.stop()
        queue.sync { source = nil }
        transferring.lock()
        if let rotation { VTPixelRotationSessionInvalidate(rotation) }
        rotation = nil
        transferring.unlock()
        let done = DispatchSemaphore(value: 0)
        let capture = capture, injector = injector
        Task {
            await capture.stop()
            await injector.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    public override func post(_ op: [String: Any]) {
        guard allowInput else { return }
        ops?.yield(op)
    }

    /// The bounds changed (still.fail SimulatorView.swift `bounds`): the capture's next picture is scaled into them,
    /// and a still screen's is made again now.
    public override func resized() {
        scaling.lock()
        limits = (maxWidth, maxHeight)
        scaling.unlock()
        if !isHeld(), let source, let picture = scaled(source) { took(picture, now()) }
    }

    // MARK: pictures

    /// The bounds' sides as `turn` has them against the framebuffer.
    private func scaled(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        scaling.lock()
        let (turn, limits) = (panelFrames ? 0 : self.turn, self.limits)
        scaling.unlock()
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let (limitW, limitH) = turn % 2 == 1 ? (limits.1, limits.0) : limits
        let scale = min(1.0, Double(limitW) / Double(width), Double(limitH) / Double(height))
        let even = { (v: Double) in max(2, Int(v.rounded()) & ~1) }
        guard let picture = transferred(source, to: (even(Double(width) * scale), even(Double(height) * scale))) else { return nil }
        return turn == 0 ? picture : rotated(picture, turn)
    }

    /// Copies a framebuffer into an NV12 buffer owned by this view.
    private func transferred(_ source: CVPixelBuffer, to size: (Int, Int)) -> CVPixelBuffer? {
        transferring.lock()
        defer { transferring.unlock() }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            if let transfer {
                VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
        }
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: size.0,
                kCVPixelBufferHeightKey: size.1,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = size
        }
        var made: CVPixelBuffer?
        guard let transfer, let pool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let picture = made,
              VTPixelTransferSessionTransferImage(transfer, from: source, to: picture) == noErr
        else { return nil }
        return picture
    }

    /// `picture` turned `turn` quarter turns clockwise, in a buffer of the view's own.
    private func rotated(_ picture: CVPixelBuffer, _ turn: Int) -> CVPixelBuffer? {
        transferring.lock()
        defer { transferring.unlock() }
        if rotation == nil || rotationTurn != turn {
            if let rotation { VTPixelRotationSessionInvalidate(rotation) }
            rotation = nil
            VTPixelRotationSessionCreate(nil, &rotation)
            guard let rotation else { return nil }
            let angle = turn == 1 ? kVTRotation_CW90 : turn == 2 ? kVTRotation_180 : kVTRotation_CCW90
            VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: angle)
            rotationTurn = turn
        }
        let w = CVPixelBufferGetWidth(picture), h = CVPixelBufferGetHeight(picture)
        let size = turn % 2 == 1 ? (h, w) : (w, h)
        if rotationPool == nil || rotationSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(picture),
                kCVPixelBufferWidthKey: size.0,
                kCVPixelBufferHeightKey: size.1,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            ]
            rotationPool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &rotationPool)
            rotationSize = size
        }
        guard let rotation, let rotationPool else { return nil }
        var made: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, rotationPool, &made) == kCVReturnSuccess, let turned = made,
              VTPixelRotationSessionRotateImage(rotation, picture, turned) == noErr
        else { return nil }
        return turned
    }

    /// A point of the picture as shown, as a point of the device's framebuffer.
    public static func unturned(_ x: Double, _ y: Double, _ turn: Int) -> (Double, Double) {
        switch turn {
        case 1: return (y, 1 - x)
        case 2: return (1 - x, 1 - y)
        case 3: return (1 - y, x)
        default: return (x, y)
        }
    }

    // MARK: input

    private func perform(_ op: [String: Any]) async {
        let (width, height) = queue.sync { screen }
        let turn = framesTurn()
        let unit = { (key: String) in min(1, max(0, (op[key] as? NSNumber)?.doubleValue ?? 0)) }
        switch op["op"] as? String {
        case "touch":
            guard let type = op["type"] as? String, ["begin", "move", "end"].contains(type) else { return }
            // An edge is the framebuffer's: a picture turned has its gestures by the device's own buttons.
            let edge = turn == 0 ? UInt32((op["edge"] as? NSNumber)?.intValue ?? 0) : 0
            let (x, y) = Self.unturned(unit("x"), unit("y"), turn)
            await injector.sendTouch(type: type, x: x, y: y, screenWidth: width, screenHeight: height, edge: [0, 2, 3].contains(edge) ? edge : 0)
        case "scroll":
            let dx = (op["dx"] as? NSNumber)?.doubleValue ?? 0, dy = (op["dy"] as? NSNumber)?.doubleValue ?? 0
            let (x, y) = Self.unturned(unit("x"), unit("y"), turn)
            // A wheel's way, turned as the point is about the picture's middle.
            let (ux, uy) = Self.unturned(0.5 + dx, 0.5 + dy, turn)
            // A wheel's burst is one drag the injector ends once it stops: not waited for, or each event would hold the next.
            let injector = injector
            Task { await injector.sendScroll(dx: ux - 0.5, dy: uy - 0.5, anchorX: x, anchorY: y, screenWidth: width, screenHeight: height) }
        case "key":
            guard let type = op["type"] as? String, ["down", "up"].contains(type),
                  let usage = (op["usage"] as? NSNumber)?.uint32Value, usage > 0, usage < 0x100 else { return }
            await injector.sendKey(type: type, usage: usage)
        case "button":
            switch op["name"] as? String {
            case "keyboard": await injector.toggleSoftwareKeyboard()
            case let name? where ["home", "lock", "siri", "side_button", "app_switcher", "volume_up", "volume_down"].contains(name):
                await injector.sendButton(button: name, deviceUDID: udid)
            default: return
            }
        case "hid":
            guard let page = (op["page"] as? NSNumber)?.uint32Value, let usage = (op["usage"] as? NSNumber)?.uint32Value,
                  page > 0, usage > 0, let down = op["down"] as? Bool else { return }
            // (still.fail SimulatorView.swift "hid": a press as short as a click's is not seen as one by the device, so it is
            // held at least as long as injector.sendButton holds its own)
            if down {
                buttonDown = .now
            } else if let at = buttonDown {
                buttonDown = nil
                try? await Task.sleep(until: at + .milliseconds(80), clock: .continuous)
            }
            await injector.sendHardwareButton(page: page, usage: usage, down: down)
        case "frames":
            // (from now on: the next picture already so)
            scaling.lock()
            panelFrames = (op["panel"] as? Bool) == true
            scaling.unlock()
            queue.async {
                if !self.isHeld(), let source = self.source, let picture = self.scaled(source) { self.took(picture, self.now()) }
            }
            tellDevice()
        case "memory_warning":
            await injector.simulateMemoryWarning()
        case "pose":
            guard let name = op["name"] as? String, let pose = DevicePose.preset(named: name) else { return }
            await sweep(to: pose.hingeDegrees, milliseconds: 800)
        case "hinge":
            // Any angle, swept over the time asked: what a posture between closed and open (a tent, a laptop) stands at.
            guard let degrees = (op["degrees"] as? NSNumber)?.doubleValue, degrees.isFinite, (0...180).contains(degrees)
            else { return }
            let ms = (op["ms"] as? NSNumber)?.intValue ?? 600
            await sweep(to: degrees, milliseconds: max(0, min(ms, 5000)))
        case "rotate":
            let cover = coverShown
            let known = KnownTurns.shared[udid] ?? DeviceTurn()
            await turnTo(known.next(displayed: turnNow(), cover: cover, folded: folded()), cover: cover)
        case "orient":
            // Straight to the picture's way up asked (quarters clockwise, as `stands.orientation` says it): one turn of
            // the device, not a quarter at a time round the long way. The inner panel's picture sits a quarter past the
            // device's turn (`DeviceTurn.next`).
            // A turn sent with a hinge move says the panel it is for, which may not be in use yet.
            guard let quarters = (op["turn"] as? NSNumber)?.intValue, (0...3).contains(quarters) else { return }
            let screen = op["screen"] as? String
            let cover = screen == "cover" ? true : screen == "inner" ? false : coverShown
            // The opening a hinge move after it goes to (`hinge`), else where it is: a tent's cover stands mirrored.
            let ahead = (op["hinge"] as? NSNumber)?.doubleValue
            let targetFolded = ahead.map { $0 > 0.5 } ?? folded()
            let physical = (quarters + 4 - DeviceTurn.offset(cover: cover, folded: targetFolded)) % 4
            // The cover staying, shut to partly open or back: the turn here and the half turn its UI makes by itself as it
            // folds come to nothing, so neither shows (held until the sweep that follows has settled). The turn goes once
            // the hinge is there: told before, the fold that follows at once takes it back.
            if cover == true, coverShown == true, targetFolded != folded() {
                for view in FoldingViews.shared.all(udid) where view.coverShown == true { view.setHeld(true) }
                setTurnAfterSweep((physical, cover, targetFolded))
                return
            }
            await turnTo(physical, cover: cover, folded: targetFolded)
        case "paste":
            guard let text = op["text"] as? String, !text.isEmpty, await pasteboard(text) else { return }
            await banner.ready()
            var mark = banner.mark()
            await commandV()
            // The text another app put on the pasteboard goes into the field only where iOS lets that app paste it.
            if let app = await pasteRefused(), !pasteAllowedNow(app), await allowPaste(app) {
                pasting.lock()
                let ended = pasteEnded
                if !ended { pasteAllowed.append(app) }
                pasting.unlock()
                // (the view ended while it was allowed: nothing more goes, and it is set back now)
                if ended { return Self.disallowPaste(udid, app) }
                mark = banner.mark()
                await commandV()
            }
            // While iOS says the app pasted from another one (its banner at the top), the banner has the keys: what
            // comes next waits until it gives them back, not dropped (PasteBanner).
            _ = await banner.passed(mark)
        default:
            return
        }
    }

    // MARK: a foldable's panels, and how a panel stands

    /// A foldable's picture is of the panel in use, not the smallest one capture would pick by itself. SpringBoard says which
    /// as it changes (a pose from here, or from Device Hub), and what it last said since the boot says which it is now.
    private func followPanels() async {
        let udid = udid
        let predicate = "subsystem == \"com.apple.SpringBoard\" AND category == \"DisplayContentMode\""
        let run = { (arguments: [String], ended: (() -> Void)?, line: @escaping (String) -> Void) -> Process in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.simctl)
            process.arguments = ["spawn", udid, "log"] + arguments + ["--style", "compact", "--predicate", predicate]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            var pending = ""
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    ended?()
                    return
                }
                pending += String(decoding: data, as: UTF8.self)
                var parts = pending.components(separatedBy: "\n")
                pending = parts.removeLast()
                parts.forEach(line)
            }
            try? process.run()
            return process
        }
        // Only how a change ended: opening from shut, SpringBoard starts moving to the inner panel at once and takes it
        // back if the hinge stops short (a tent's 60: `CANCELLED: .cover:pri`), the inner panel never in use.
        let said = { (text: String) -> Bool? in
            guard text.contains("COMPLETED:") || text.contains("CANCELLED:") else { return nil }
            return text.contains(".cover:pri") ? true : text.contains(".inner:pri") ? false : nil
        }
        // The hinge's angle it ended at (`| 61.6° (`), the last said since the boot first.
        let observe = { (text: String) in
            guard let angle = Self.hingeAngle(text) else { return }
            KnownHinges.shared.update(udid, DeviceHinge()) { $0.observed(angle) }
        }
        // One after another: each its own task, a quick few could end in another order than they came, the capture left at
        // the size of the panel not in use (its picture stretched to that).
        let (changes, change) = AsyncStream<PanelSaid>.makeStream()
        followed = change
        Task { [weak self] in
            for await said in changes { await self?.showPanel(cover: said.cover, initial: said.initial) }
        }
        let boot = BootPanel()
        panels = run(["stream"], nil) { [weak self] text in
            guard let cover = said(text) else { return }
            observe(text)
            self?.transitionEnded()
            boot.overtaken()
            change.yield(PanelSaid(cover: cover, initial: false))
        }
        // Only the last the boot's log says is what shows now: of the hinge too, and only when it is newer than what is
        // known of it since (a sweep from here, a change another view saw), which the log says nothing of when the panel
        // in use stays. Each line's angle told one by one went to every view open on the device.
        _ = run(["show", "--last", "boot"], { [weak self] in
            boot.read()
            guard let self, let (angle, at) = boot.angle else { return }
            KnownHinges.shared.update(self.udid, DeviceHinge()) { $0.observed(angle, at: at) }
            self.tellDevice()
        }) { text in
            if let cover = said(text) {
                boot.said(cover)
                if let angle = Self.hingeAngle(text), let at = Self.logTime(text) { boot.said(angle: angle, at: at) }
            }
        }
        // The panel an earlier view here left it on, at once: the boot's log is read whole, longer the longer the device has
        // been up. The log still says, as it comes, a fold made with no view following it.
        if let cover = KnownPanels.shared[udid] {
            await showPanel(cover: cover, opening: true)
            Task {
                while !boot.done { try? await Task.sleep(for: .milliseconds(100)) }
                if let cover = boot.taken() { change.yield(PanelSaid(cover: cover, initial: true)) }
            }
            return
        }
        for _ in 0..<150 where !boot.done {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if boot.done {
            if let cover = boot.taken() { await showPanel(cover: cover, opening: true) }
        } else {
            Task {
                while !boot.done { try? await Task.sleep(for: .milliseconds(100)) }
                if let cover = boot.taken() { change.yield(PanelSaid(cover: cover, initial: true)) }
            }
        }
    }

    /// The picture to be of the cover or the inner panel; the hinge where a next pose sweeps from.
    private func showPanel(cover: Bool, opening: Bool = false, initial: Bool = false) async {
        guard coverShown != cover else { return }
        // A fold or an unfold made while the view is open: iOS draws the new panel black, then fades and zooms its UI in.
        // The last picture of the old panel is held until the new panel has drawn and settled (settlePanel).
        // (a panel's own picture is not held: the new panel's black and its UI's fade in show live, as on the device)
        let live = coverShown != nil && !opening && !initial && !isPanelFrames()
        setHeld(live)
        let change = nextPanelChange()
        coverShown = cover
        if !live { setPictured(cover) }
        KnownPanels.shared[udid] = cover
        KnownHinges.shared.update(udid, DeviceHinge()) { $0.panelShown(cover: cover, initial: opening || initial) }
        tellDevice()
        let size = cover ? (DevicePose.coverWidth, DevicePose.coverHeight) : (DevicePose.innerWidth, DevicePose.innerHeight)
        await capture.setPreferredScreenSize(width: size.0, height: size.1)
        if opening, let said = await enumerated() {
            _ = setTurn(displayTurn(Self.turnOf(said, panel: cover ? "primary" : "primary-1"), cover: cover))
        }
        // Not waited for: the next press would wait for all of it, seconds, behind it.
        Task { [weak self] in
            if live { await self?.settlePanel(change: change, cover: cover) }
            await self?.lookTurn(cover: cover)
        }
    }

    /// Lets go of the picture held for a panel change once the new panel has drawn something and settled
    /// (PanelLook.Settling), at most `SimulatorPanelHold.longest` after the change. A newer change or turn takes over the
    /// hold. The panel's turn is read first, so its first picture shown already stands as the panel does.
    private func settlePanel(change: UInt64, cover: Bool) async {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < SimulatorPanelHold.longest {
            try? await Task.sleep(for: SimulatorPanelHold.step)
            guard panelChangeNow() == change else { return }
            // (a panel's own picture goes once the panel shows: its UI's turn after plays on it live)
            if heldSettled(.now) && (!isTurnPending() || isPanelFrames()) { break }
        }
        guard panelChangeNow() == change, coverShown == cover else { return }
        if let said = await enumerated(), panelChangeNow() == change {
            if setTurn(displayTurn(Self.turnOf(said, panel: cover ? "primary" : "primary-1"), cover: cover)) { tellDevice() }
        }
        guard panelChangeNow() == change else { return }
        setHeld(false)
        queue.async {
            if !self.isHeld(), let source = self.source, let picture = self.scaled(source) {
                self.took(picture, self.now())
            }
            self.sayDevice()
        }
    }

    private func nextPanelChange() -> UInt64 {
        scaling.lock()
        defer { scaling.unlock() }
        panelChanges += 1
        return panelChanges
    }

    private func panelChangeNow() -> UInt64 {
        scaling.lock()
        defer { scaling.unlock() }
        return panelChanges
    }

    /// CoreSimulator's UI direction initializes a view before any physical turn is known. A requested physical turn
    /// takes precedence thereafter: an app that locks its interface upright must not turn the case back.
    private func lookTurn(cover: Bool?, waits: [Int] = [0, 1, 2]) async {
        for wait in waits {
            try? await Task.sleep(for: .seconds(wait))
            // (not while another turn is held: what it shows is the picture from before that turn)
            guard coverShown == cover, !isTurnPending(), let said = await enumerated(), coverShown == cover,
                  !isTurnPending() else { continue }
            let now = displayTurn(Self.turnOf(said, panel: cover == false ? "primary-1" : "primary"), cover: cover)
            guard setTurn(now) else { continue }
            tellDevice()
            // A still screen brings no picture: what it shows now, turned.
            queue.async {
                if !self.isHeld(), let source = self.source, let picture = self.scaled(source) {
                    self.took(picture, self.now())
                }
            }
        }
    }

    /// A device told to turn draws its UI going round inside its framebuffer, a turned picture of which would go round
    /// inside the case, which has turned at once. The picture is held as it is for that long: the next one is of the
    /// device turned, the case with it. An app may keep its interface upright; the physical turn still applies when
    /// that wait expires. Ported from still.fail SimulatorView.swift `settleTurn`.
    private func settleTurn(cover: Bool?, before was: Int, revision: UInt64, views: [SimulatorStreamSession], changes: [UInt64]) async {
        let panel = cover == false ? "primary-1" : "primary"
        var now = was
        let start = ContinuousClock.now
        // The way its UI stands once turned, the physical turn known: it may be the way it stood (a tent shut flat, its
        // UI kept by the turn that goes with it), then only its drawing is waited for.
        let expected = (KnownTurns.shared[udid] ?? DeviceTurn()).physical.map {
            ($0 + DeviceTurn.offset(cover: cover, folded: cover == true && folded())) % 4
        }
        let turned = { (now: Int) in expected.map { now == $0 } ?? (now != was) }
        for _ in 0..<15 where !turned(now) {
            guard KnownTurns.shared[udid]?.revision == revision else { return }
            // (a panel's own picture: said as soon as it turns, so looked at as often as `simctl` answers)
            try? await Task.sleep(for: .milliseconds(isPanelFrames() ? 20 : 100))
            if let said = await enumerated() { now = Self.turnOf(said, panel: panel) }
            // An app that keeps its interface as it was (or a panel not in use yet) draws nothing going round: no need to
            // wait the whole while for a turn it does not show.
            if !turned(now), ContinuousClock.now - start > .milliseconds(500),
               ContinuousClock.now - heldLast() > .milliseconds(300) { break }
        }
        // (a panel's own picture not held is said as soon as its UI turns, its turn playing live; one held, while the
        // cover's UI turns by itself as it folds, only once that has played)
        if turned(now) && (!isPanelFrames() || isHeld()) {
            // until it has drawn nothing new for a moment, or about the same (an app that moves on: PanelLook.Settling)
            for _ in 0..<30 {
                guard KnownTurns.shared[udid]?.revision == revision else { return }
                try? await Task.sleep(for: SimulatorPanelHold.step)
                if ContinuousClock.now - heldLast() > SimulatorPanelHold.quiet || heldSettled(.now) { break }
            }
        }
        guard KnownTurns.shared[udid]?.revision == revision else { return }
        // A portrait-locked app does not undo a physical turn. Each view uses its panel's mounting axis. A view whose
        // panel changed meanwhile is let go of by that change's hold (settlePanel), which waited for this.
        for view in views {
            view.setTurnPending(false)
            guard view.coverShown != nil || cover == nil else { continue }
            if view.setTurn(view.displayTurn(now, cover: view.coverShown)) { view.tellDevice() }
        }
        for (view, change) in zip(views, changes) where view.panelChangeNow() == change {
            view.tellDevice()
            view.setHeld(false)
            view.queue.async {
                if !view.isHeld(), let source = view.source, let picture = view.scaled(source) {
                    view.took(picture, view.now())
                }
            }
        }
    }

    private func displayTurn(_ observed: Int, cover: Bool?) -> Int {
        (KnownTurns.shared[udid] ?? DeviceTurn()).displayed(observed: observed, cover: cover, folded: folded())
    }

    /// Whether the hinge is off shut: the cover's picture then stands a half turn from the device (DeviceTurn).
    private func folded() -> Bool { (KnownHinges.shared[udid] ?? DeviceHinge()).degrees > 0.5 }

    private func isHeld() -> Bool {
        scaling.lock()
        defer { scaling.unlock() }
        return held
    }

    private func transitionEnded() {
        scaling.lock()
        defer { scaling.unlock() }
        transitionsEnded += 1
    }

    private func transitionsEndedNow() -> UInt64 {
        scaling.lock()
        defer { scaling.unlock() }
        return transitionsEnded
    }

    private func setTurnAfterSweep(_ turn: (Int, Bool?, Bool)?) {
        scaling.lock()
        defer { scaling.unlock() }
        turnAfterSweep = turn
    }

    private func takeTurnAfterSweep() -> (Int, Bool?, Bool)? {
        scaling.lock()
        defer { scaling.unlock() }
        let turn = turnAfterSweep
        turnAfterSweep = nil
        return turn
    }

    private func setTurnPending(_ on: Bool) {
        scaling.lock()
        defer { scaling.unlock() }
        turnPending = on
    }

    private func isTurnPending() -> Bool {
        scaling.lock()
        defer { scaling.unlock() }
        return turnPending
    }

    private func setPictured(_ cover: Bool?) {
        scaling.lock()
        defer { scaling.unlock() }
        pictured = cover
    }

    private func picturedNow() -> Bool? {
        scaling.lock()
        defer { scaling.unlock() }
        return pictured
    }

    /// Holds the picture sent, or lets it go: the next one is of the panel in use, said so (`pictured`).
    private func setHeld(_ on: Bool) {
        let cover = coverShown
        scaling.lock()
        defer {
            scaling.unlock()
            if !on { tellDevice() }
        }
        if !on { pictured = cover }
        held = on
        heldAt = .now
        heldLook = PanelLook.Settling()
    }

    /// Whether the panel held for a change has settled by `now` (PanelLook.Settling).
    private func heldSettled(_ now: ContinuousClock.Instant) -> Bool {
        scaling.lock()
        defer { scaling.unlock() }
        return heldLook.settled(now, quiet: SimulatorPanelHold.quiet)
    }

    /// When the device last drew something while its picture is held.
    private func heldLast() -> ContinuousClock.Instant {
        scaling.lock()
        defer { scaling.unlock() }
        return heldAt
    }

    /// Whether the picture is held for a turn: what the device drew kept for when it is let go of. On the capture's queue.
    private func heldForTurn(_ buffer: CVPixelBuffer) -> Bool {
        scaling.lock()
        defer { scaling.unlock() }
        guard held else { return false }
        heldAt = .now
        heldLook.drew(PanelLook.sample(buffer), at: heldAt)
        queue.async { self.source = buffer }
        return true
    }

    /// How far the picture sent is turned: the UI's turn, or none for a panel's own (`panelFrames`).
    private func framesTurn() -> Int {
        scaling.lock()
        defer { scaling.unlock() }
        return panelFrames ? 0 : turn
    }

    private func turnNow() -> Int {
        scaling.lock()
        defer { scaling.unlock() }
        return turn
    }

    /// Whether that was a change.
    private func setTurn(_ now: Int) -> Bool {
        scaling.lock()
        defer { scaling.unlock() }
        let changed = turn != now
        turn = now
        return changed
    }

    /// Turns the device to `turned` quarters clockwise, its picture held until it has turned and then looked at again.
    private func turnTo(_ turned: Int, cover: Bool?, folded targetFolded: Bool? = nil) async {
        // Already so: nothing goes round, and nothing is held.
        if KnownTurns.shared[udid]?.physical == turned { return }
        let was = KnownTurns.shared[udid]?.physical
        // Clockwise, as the client's stage turns its frame on a press and an Android device goes: `turnOf` says
        // Landscape Left is a quarter turn clockwise.
        let orientation = [
            HIDInjector.orientationPortrait, HIDInjector.orientationLandscapeLeft,
            HIDInjector.orientationPortraitUpsideDown, HIDInjector.orientationLandscapeRight,
        ][turned]
        guard await injector.sendOrientation(orientation: orientation) else { return }
        let revision = KnownTurns.shared.update(udid, DeviceTurn()) { $0.turned(turned) }
        // A panel's own picture: the device has turned, said at once, and the model turns with its UI's own turn, which
        // starts now, instead of after it has looked. (Its UI's way up before, from the turn known, or as it stood.)
        let before = was.map { ($0 + DeviceTurn.offset(cover: cover, folded: cover == true && folded())) % 4 } ?? turnNow()
        for view in DeviceOpenViews.shared.all(udid) where view.isPanelFrames() {
            let shown = view.coverShown
            let mirrored = shown == true && (targetFolded ?? view.folded())
            if view.setTurn((turned + DeviceTurn.offset(cover: shown, folded: mirrored)) % 4) { view.tellDevice() }
        }
        // still.fail SimulatorView.swift "rotate": the picture held until the device has turned (settleTurn), then
        // looked at again (a device under load is seconds behind the turn it was told of). Every view of the device turns
        // with it, not only the one that asked: another one open on it would go on drawing the turned device's pictures
        // as it stood before, on their side in the frame.
        holdForTurn(cover: cover, before: before, revision: revision, views: DeviceOpenViews.shared.all(udid))
    }

    /// Holds the views' pictures until the device's UI has turned (settleTurn), then looks again.
    private func holdForTurn(cover: Bool?, before: Int, revision: UInt64, views: [SimulatorStreamSession]) {
        settleHeld(cover: cover, before: before, revision: revision, views: views, changes: Self.holdTurning(views))
    }

    /// Holds the views' pictures for a turn on its way: the changes a later panel change supersedes.
    private static func holdTurning(_ views: [SimulatorStreamSession], always: Bool = false) -> [UInt64] {
        views.map { view in
            let change = view.nextPanelChange()
            // (a panel's own picture is not held: its UI turns on it as on the device. Unless it already is, for a turn
            // that comes to nothing: `sweep`.)
            if always || !view.isPanelFrames() || view.isHeld() { view.setHeld(true) }
            view.setTurnPending(true)
            return change
        }
    }

    private func isPanelFrames() -> Bool {
        scaling.lock()
        defer { scaling.unlock() }
        return panelFrames
    }

    private func settleHeld(cover: Bool?, before: Int, revision: UInt64, views: [SimulatorStreamSession], changes: [UInt64]) {
        Task {
            await self.settleTurn(cover: cover, before: before, revision: revision, views: views, changes: changes)
            await withTaskGroup(of: Void.self) { group in
                for view in views {
                    group.addTask { await view.lookTurn(cover: view.coverShown, waits: Array(repeating: 1, count: 12)) }
                }
            }
        }
    }

    /// Moves the device's hinge to `degrees` over `milliseconds`, the panel shown following it (the cover below 90).
    /// Sweeps the hinge to `degrees`; a turn sent with it (`orient`) goes once it is there where the panel or the cover's
    /// mirroring changes: the simulator reads a turn told while shut as the cover's own, and one told while partly open as
    /// the device's (`DeviceTurn`). Otherwise, and for a hinge already there, the turn goes at once.
    private func sweep(to degrees: Double, milliseconds: Int) async {
        // Known before it sweeps: the panel comes up during the sweep, and must not read as the device opened flat.
        let ask = KnownHinges.shared.update(udid, DeviceHinge()) { $0.asked(degrees) }
        // A hinge already there is not touched: told again, SpringBoard starts a fold that takes back the turn just told.
        // (One left half open before this view opened is known from SpringBoard's last word, `followPanels`.)
        guard abs(ask.from - degrees) >= 0.5 else {
            KnownHinges.shared.update(udid, DeviceHinge()) { $0.settled(ask.id) }
            return
        }
        // The cover staying, shut to partly open or back: its UI turns a half turn by itself (DeviceTurn), and the turn
        // that keeps the picture so (`orient`) another half: held, even a panel's own picture, from now, before that turn
        // comes, so that neither shows.
        let mirroring = degrees < 90 && coverShown == true && (ask.from > 0.5) != (degrees > 0.5)
        let views = mirroring ? FoldingViews.shared.all(udid).filter { $0.coverShown == true } : []
        let mirror = Mirror(views: views, changes: Self.holdTurning(views, always: true))
        // A move on one panel that keeps how its UI stands (an inner panel's, flat to a laptop) sweeps while the turn sent
        // with it goes at once, as a hand turns the device while it folds it.
        let panelChanges = coverShown != nil && coverShown != (degrees < 90)
        guard panelChanges || mirroring else {
            Task { await self.moveHinge(ask, to: degrees, milliseconds: milliseconds, mirror: nil) }
            return
        }
        await moveHinge(ask, to: degrees, milliseconds: milliseconds, mirror: mirroring ? mirror : nil)
    }

    /// The views held while the cover's UI turns by itself (`sweep`).
    private struct Mirror {
        let views: [SimulatorStreamSession]
        let changes: [UInt64]
    }

    private func moveHinge(_ ask: DeviceHinge.Ask, to degrees: Double, milliseconds: Int, mirror: Mirror?) async {
        let endedBefore = transitionsEndedNow()
        // Hold before the sweep: the old panel fades out before SpringBoard reports the new one.
        let cover = degrees < 90
        let switching = FoldingViews.shared.all(udid).filter { $0.coverShown != nil && $0.coverShown != cover }
        let changes = switching.map { view in
            let change = view.nextPanelChange()
            if !view.isPanelFrames() { view.setHeld(true) }
            return change
        }
        // SpringBoard changes panels with some hysteresis: from 60 open to 110 it may keep the cover, from 110 to 60 the
        // inner panel. A move that changes panels so goes by the far end (flat open, or shut) and back, which it always
        // follows, the whole within the time asked.
        let end = cover ? 0.0 : 180.0
        let crossing = coverShown != nil && coverShown != cover && degrees != end && milliseconds > 0
        let mirroring = mirror != nil
        let mirrorViews = mirror?.views ?? [], mirrorChanges = mirror?.changes ?? []
        // A panel's own picture is of the new panel from now: SpringBoard keeps drawing the panel not in use (aux), so
        // its UI is there as the device opens or shuts, as Device Hub shows it, not once the sweep is over.
        for view in switching where view.isPanelFrames() { await view.showPanel(cover: cover) }
        let mirrorFrom = mirroring ? await enumerated().map { Self.turnOf($0, panel: "primary") } ?? turnNow() : 0
        let swept: Bool
        if crossing {
            let first = milliseconds * 3 / 5
            swept = await injector.sweepHinge(fromDegrees: ask.from, toDegrees: end, milliseconds: first)
            if swept {
                try? await Task.sleep(for: .milliseconds(first + 50))
                // At the far end SpringBoard always uses that panel: its picture is taken from now, not once SpringBoard
                // says so at the end of its transition (seconds); held until it has drawn (settlePanel).
                for view in switching { await view.showPanel(cover: cover) }
            }
        } else {
            swept = true
        }
        guard swept, await injector.sweepHinge(fromDegrees: crossing ? end : ask.from, toDegrees: degrees,
                                                milliseconds: crossing ? milliseconds * 2 / 5 : milliseconds) else {
            KnownHinges.shared.update(udid, DeviceHinge()) { $0.failed(ask.id) }
            // (the turn told for once the hinge got there goes with it: a later sweep must not take it)
            _ = takeTurnAfterSweep()
            for (view, change) in zip(switching, changes) where view.panelChangeNow() == change { view.setHeld(false) }
            for (view, change) in zip(mirrorViews, mirrorChanges) {
                view.setTurnPending(false)
                if view.panelChangeNow() == change { view.setHeld(false) }
            }
            tellFoldingViews()
            return
        }
        KnownHinges.shared.update(udid, DeviceHinge()) { $0.settled(ask.id) }
        // Swept shut or flat open from the other panel: the same, once there.
        if !crossing && !switching.isEmpty && degrees == end {
            let views = switching
            Task {
                try? await Task.sleep(for: .milliseconds(milliseconds + 50))
                for view in views { await view.showPanel(cover: cover) }
            }
        }
        if mirroring {
            let physical = KnownTurns.shared[udid]?.physical
                ?? (mirrorFrom + 4 - DeviceTurn.offset(cover: true, folded: ask.from > 0.5)) % 4
            let revision = KnownTurns.shared.update(udid, DeviceTurn()) { $0.turned(physical) }
            settleHeld(cover: true, before: mirrorFrom, revision: revision, views: mirrorViews, changes: mirrorChanges)
        }
        // (the turn told before it, once the hinge is there and SpringBoard has ended the transition the sweep started,
        // which would take it back; at most a while)
        if let (physical, cover, folded) = takeTurnAfterSweep() {
            let start = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(milliseconds + 50))
            while transitionsEndedNow() == endedBefore, ContinuousClock.now - start < .seconds(2) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            await turnTo(physical, cover: cover, folded: folded)
        }
        tellFoldingViews()
        // SpringBoard says when the panel has changed (`followPanels`): a panel not yet drawn is black. In case it
        // never says, the picture goes there anyway, long after even a just-booted device's slow first pose.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, ((KnownHinges.shared[self.udid] ?? DeviceHinge()).degrees < 90) == cover else { return }
            await self.showPanel(cover: cover)
        }
    }

    /// Every open view receives the latest screen switch request.
    private func tellFoldingViews() {
        for view in FoldingViews.shared.all(udid) {
            view.tellDevice()
        }
    }

    /// Says how the device stands, once a view is open and when that is new.
    private func tellDevice() { queue.async { self.sayDevice() } }

    private func sayDevice() {
        guard self.isOpen, !self.ended else { return }
        // (while the old panel's picture is held for a change: said once the new one shows, settlePanel)
        guard self.picturedNow() == self.coverShown else { return }
        var stands: [String: Any] = ["orientation": self.turnNow() * 90]
        if self.isPanelFrames() { stands["panel"] = true }
        if let cover = self.coverShown {
            stands["pose"] = cover ? "closed" : "open"
            stands["hinge"] = Int((KnownHinges.shared[self.udid] ?? DeviceHinge()).degrees.rounded())
        }
        let said = (stands["orientation"] as? Int ?? 0, stands["pose"] as? String, stands["hinge"] as? Int, stands["panel"] != nil)
        guard self.lastStands == nil || self.lastStands! != said else { return }
        self.lastStands = said
        self.channel.sendJSON(65, stands)
    }

    /// The hinge's angle in SpringBoard's words of a panel change (`| 61.6° (0.34 fold:0.00)`).
    /// When a line of `log`'s compact style was said (`2026-11-12 13:04:41.809 …`, the Mac's own time zone).
    public static func logTime(_ said: String) -> Date? {
        guard said.count >= 23 else { return nil }
        return logTimes.date(from: String(said.prefix(23)))
    }

    private static let logTimes: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return format
    }()

    public static func hingeAngle(_ said: String) -> Double? {
        guard let bar = said.range(of: "| "), let degree = said.range(of: "°", range: bar.upperBound..<said.endIndex)
        else { return nil }
        return Double(said[bar.upperBound..<degree.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    /// The quarter turns clockwise a panel's picture is shown at, from `simctl io enumerate`'s words of it.
    public static func turnOf(_ said: String, panel: String) -> Int {
        // A device of one panel is "primary" on the newer runtimes, "PurpleMain" on the older.
        for block in said.components(separatedBy: "Device Name: ").dropFirst()
        where block.hasPrefix(panel + "\n") || (panel == "primary" && block.hasPrefix("PurpleMain\n")) {
            guard let line = block.split(separator: "\n").first(where: { $0.contains("UI Orientation:") }) else { return 0 }
            if line.hasSuffix("Landscape Left") { return 1 }
            if line.hasSuffix("Landscape Right") { return 3 }
            if line.hasSuffix("Portrait Upside Down") { return 2 }
            return 0
        }
        return 0
    }

    private func enumerated() async -> String? {
        let udid = udid
        return await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.simctl)
            process.arguments = ["io", udid, "enumerate"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return done.resume(returning: nil) }
            DispatchQueue.global().async {
                // All of it once the pipe ends. Not `waitUntilExit`: on a worker with no run loop to speak of, it can wait
                // for good on a process already gone, and a view then never opens.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                done.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// What `file` printed, once it has ended (null: it did not run, or failed). Ended after a while: a person's next keys
    /// wait on it.
    private func output(_ file: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: file)
            process.arguments = arguments
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return done.resume(returning: nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if process.isRunning { process.terminate() } }
            DispatchQueue.global().async {
                // All of it once the pipe ends, then how it ended (not `waitUntilExit`, as `enumerated` says).
                let data = out.fileHandleForReading.readDataToEndOfFile()
                while process.isRunning { usleep(10_000) }
                done.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }

    /// `file` started, not waited for (a view that ends does not wait on what it sets back).
    private static func start(_ file: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: file)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// ⌘V: the left GUI key held round V.
    private func commandV() async {
        await injector.sendKey(type: "down", usage: 0xE3)
        await injector.sendKey(type: "down", usage: 0x19)
        await injector.sendKey(type: "up", usage: 0x19)
        await injector.sendKey(type: "up", usage: 0xE3)
    }

    /// The app whose paste of the pasteboard iOS just refused, if one did (`pasteAsked`). An iOS 27 simulator's
    /// keyboards (dtuhidd's, Indigo's) are not authenticated, so `pasted` takes their ⌘V as an app's own read of what
    /// another app copied. Unless the app may paste from other apps, `pasted` asks the person with a prompt that a
    /// simulator never shows, and refuses at once. Nothing else says so: the app's field just stays as it was. still.fail
    /// has no way past this yet (afk/main SimulatorView.swift sends the same ⌘V; its docs/remote-screens.md "The keys on
    /// Xcode 27": the text went in only with a Device Hub window open on the device, or from the field's own Paste).
    private func pasteRefused() async -> String? {
        for wait in [400, 800] {
            try? await Task.sleep(for: .milliseconds(wait))
            let said = await output(Self.simctl, ["spawn", udid, "log", "show", "--last", "3s", "--style", "compact", "--predicate", "process == \"pasted\""])
            guard let said else { return nil }
            // (none asked yet: the app may still be taking the keys)
            if let asked = Self.pasteAsked(said) { return asked.refused ? asked.app : nil }
        }
        return nil
    }

    /// What `pasted`'s log says of the last app that asked for the pasteboard, and whether it was refused (null: none
    /// asked). Each request is a line `Bundle ID <app> from team <team> is requesting item …`; CoreDevice's own, as it
    /// writes the pasteboard, name no app (`(null)`). When the app may not paste it, `Paste requires user authorization.
    /// Prompting...` follows.
    public static func pasteAsked(_ log: String) -> (app: String, refused: Bool)? {
        var last: (app: String, refused: Bool)?
        for line in log.split(separator: "\n") {
            if let at = line.range(of: "Bundle ID "), let end = line.range(of: " from team ", range: at.upperBound..<line.endIndex),
               line.contains("is requesting item") {
                let app = String(line[at.upperBound..<end.lowerBound])
                if app != "(null)" { last = (app, false) }
            } else if line.contains("Paste requires user authorization"), let asked = last {
                last = (asked.app, true)
            }
        }
        return last
    }

    /// `app` allowed to paste from other apps, as a person who answered its Paste prompt with Allow, for as long as this
    /// view lasts (`stop` resets it). A person typing through the view means the text for the field the app has.
    private func allowPaste(_ app: String) async -> Bool {
        await output(Self.simctl, ["privacy", udid, "grant", "pasteboard", app]) != nil
    }

    private func pasteAllowedNow(_ app: String) -> Bool {
        pasting.lock()
        defer { pasting.unlock() }
        return pasteAllowed.contains(app)
    }

    /// `app` back to asking, as it was before this view allowed it (it asked: `pasteRefused`).
    private static func disallowPaste(_ udid: String, _ app: String) {
        start(simctl, ["privacy", udid, "reset", "pasteboard", app])
    }

    /// The device's pasteboard set to `text`: through CoreDevice from Xcode 27, whose guest takes no legacy snapshots while
    /// Device Hub's stack is in use, else `simctl pbcopy`. Each is CoreSimulator's or CoreDevice's own tool: Xcode's are scripts
    /// that may first run `xcodebuild -runFirstLaunch`, which waits for an administrator's password nobody here can give.
    private func pasteboard(_ text: String) async -> Bool {
        if HIDInjector.usesDTUHID {
            let copied = await piped(text, Self.devicectl, ["device", "pasteboard", "copy", "--device", udid, "--timeout", "5", "--quiet"])
            if copied { return true }
        }
        return await piped(text, Self.simctl, ["pbcopy", udid])
    }

    /// `file` run with `text` on its stdin; whether it succeeded. Ended after a while: a person's next keys wait on it.
    private func piped(_ text: String, _ file: String, _ arguments: [String]) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: file)
        process.arguments = arguments
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus == 0) }
            do {
                try process.run()
                input.fileHandleForWriting.write(Data(text.utf8))
                try? input.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if process.isRunning { process.terminate() } }
            } catch {
                process.terminationHandler = nil
                done.resume(returning: false)
            }
        }
    }
}

/// What the boot's log says of the panel in use, as it is read: its last, once all of it has been, unless the live log has
/// said one since.
private final class BootPanel: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Bool?
    private var finished = false

    var done: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func said(_ cover: Bool) {
        lock.lock()
        defer { lock.unlock() }
        last = cover
    }

    /// The hinge's angle the last change said ended at, and when.
    private var lastAngle: (Double, Date)?

    func said(angle: Double, at: Date) {
        lock.lock()
        defer { lock.unlock() }
        lastAngle = (angle, at)
    }

    var angle: (Double, Date)? {
        lock.lock()
        defer { lock.unlock() }
        return lastAngle
    }

    func read() {
        lock.lock()
        defer { lock.unlock() }
        finished = true
    }

    func overtaken() {
        lock.lock()
        defer { lock.unlock() }
        last = nil
    }

    func taken() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        defer { last = nil }
        return last
    }
}

/// A panel the device was said to be on: as it happens, or (`initial`) read when a view opened.
private struct PanelSaid: Sendable {
    let cover: Bool
    let initial: Bool
}

/// How long a view holds its picture through a foldable's panel change. iOS 27.2's Duo fades the new panel in from black
/// over about half a second.
enum SimulatorPanelHold {
    static let step = Duration.milliseconds(50)
    static let quiet = Duration.milliseconds(150)
    static let longest = Duration.milliseconds(1500)
}

/// What a held panel draws, looked at coarsely: a grid of its brightness, enough to tell black, a fade and a still UI.
public enum PanelLook {
    static let across = 12

    /// The brightness (0...255) at `across`×`across` points of a captured picture: its luma plane, or BGRA's luminance.
    static func sample(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return [] }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let row = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let step = planar ? 1 : 4
        let channel = planar ? 0 : 1
        guard width > 0, height > 0 else { return [] }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity(across * across)
        for j in 0..<across {
            let y = (2 * j + 1) * height / (2 * across)
            for i in 0..<across {
                let x = (2 * i + 1) * width / (2 * across)
                let at = y * row + x * step + channel
                let value = planar ? Int(bytes[at])
                    : (54 * Int(bytes[at + 1]) + 183 * Int(bytes[at]) + 19 * Int(bytes[at - 1])) / 256
                out.append(UInt8(value))
            }
        }
        return out
    }

    /// Nothing lit: a panel not yet drawn.
    static func black(_ look: [UInt8]) -> Bool { (look.max() ?? 0) < 12 }

    /// About the same picture: a fade or a zoom moves the mean difference well past this, a clock's tick does not.
    static func alike(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var sum = 0
        for (x, y) in zip(a, b) { sum += abs(Int(x) - Int(y)) }
        return sum <= 2 * a.count
    }

    /// A held panel settles once it has drawn something that is not black, then either drawn nothing new or drawn about
    /// the same for `quiet`.
    public struct Settling: Sendable {
        var last: [UInt8]?
        var lastAt: ContinuousClock.Instant?
        var steadySince: ContinuousClock.Instant?
        var steadyLook: [UInt8]?

        public init() {}

        public mutating func drew(_ look: [UInt8], at: ContinuousClock.Instant) {
            if let last, !PanelLook.black(look), PanelLook.alike(steadyLook ?? last, look) {
                steadySince = steadySince ?? lastAt
            } else {
                steadySince = nil
                steadyLook = look
            }
            last = look
            lastAt = at
        }

        public func settled(_ now: ContinuousClock.Instant, quiet: Duration) -> Bool {
            guard let last, let lastAt, !PanelLook.black(last) else { return false }
            return now - lastAt >= quiet || steadySince.map { now - $0 >= quiet } == true
        }
    }
}

/// Physical turns requested here, separate from the foreground app's interface orientation.
/// Duo's inner framebuffer mounts one quarter turn clockwise from its cover. The cover's UI stands a half turn from the
/// device while it is partly open (a tent): SpringBoard says so, `61.6° closed [device:Lr cover:Ll]`, where shut it says
/// `fullyClosed [device:Ll]`.
/// CoreSimulator exposes UI direction, not physical direction. After a turn here, a turn made in Device Hub cannot
/// reliably replace this value: a locked app reports the same UI direction for every physical direction.
public struct DeviceTurn: Sendable {
    public private(set) var physical: Int?
    public private(set) var revision: UInt64 = 0
    private var boot: String?

    public init() {}

    public mutating func booted(_ id: String) {
        if let boot, boot != id {
            physical = nil
            revision += 1
        }
        boot = id
    }

    /// Quarter turns a panel's picture stands from the device's physical turn.
    public static func offset(cover: Bool?, folded: Bool = false) -> Int {
        cover == false ? 1 : cover == true && folded ? 2 : 0
    }

    public func next(displayed: Int, cover: Bool?, folded: Bool = false) -> Int {
        let was = physical ?? (displayed + 4 - Self.offset(cover: cover, folded: folded)) % 4
        return (was + 1) % 4
    }

    @discardableResult
    public mutating func turned(_ physical: Int) -> UInt64 {
        self.physical = physical
        revision += 1
        return revision
    }

    public func displayed(observed: Int, cover: Bool?, folded: Bool = false) -> Int {
        guard let physical else { return observed }
        return (physical + Self.offset(cover: cover, folded: folded)) % 4
    }
}

/// The last requested hinge position, shared by the device's views, for the next screen switch's sweep and rollback.
/// The panel in use determines whether the view shows the outer or inner screen.
public struct DeviceHinge: Sendable {
    /// One request to move the hinge: `from` is where a failure of it goes back to.
    public struct Ask: Sendable {
        public let id: UInt64
        public fileprivate(set) var from: Double
    }

    /// The cover's, until told.
    public private(set) var degrees = 0.0
    private var told = false
    /// When what is known of it was last learnt (a sweep asked, a change seen as it came): an older word of it says nothing.
    private var learnt: Date?
    private var boot: String?
    private var nextAsk: UInt64 = 0
    /// Those still sweeping, the oldest first.
    private var asking: [Ask] = []

    public init() {}

    /// A view opened on this boot of the device: what was known of an earlier boot says nothing of it.
    public mutating func booted(_ id: String) {
        if let known = boot, known != id { self = DeviceHinge() }
        boot = id
    }

    /// Told to go there, known from the start of its sweep. Says where it was, for the sweep to start from.
    public mutating func asked(_ degrees: Double) -> Ask {
        let ask = Ask(id: nextAsk, from: self.degrees)
        nextAsk += 1
        asking.append(ask)
        learnt = Date()
        self.degrees = degrees
        told = true
        return ask
    }

    /// Its sweep ended: nothing asked before it can say anything of the hinge now.
    public mutating func settled(_ id: UInt64) {
        guard let at = asking.firstIndex(where: { $0.id == id }) else { return }
        asking.removeSubrange(...at)
    }

    /// Its sweep failed. Only the newest puts the hinge back: an older one left a newer one's place alone, and leaves it
    /// where that one goes back to.
    public mutating func failed(_ id: UInt64) {
        guard let at = asking.firstIndex(where: { $0.id == id }) else { return }
        let ask = asking.remove(at: at)
        if at == asking.count { degrees = ask.from } else { asking[at].from = ask.from }
    }

    /// The panel in use changed: what that says of a hinge not told otherwise. A sweep under way says where the hinge goes
    /// (a panel comes up during it), and what a view read as it opened is older than what the hinge was told since.
    public mutating func panelShown(cover: Bool, initial: Bool = false) {
        guard asking.isEmpty, !(initial && cover && told && degrees >= 90) else { return }
        // (a cover shown partly open, as SpringBoard said it, `observed`, stays so)
        if cover { if degrees >= 90 { degrees = 0 } } else if degrees < 90 { degrees = 180 }
    }

    /// The angle SpringBoard says a panel change ended at, while nothing here sweeps it: where a view opened on a device
    /// left half open (a tent) finds it, instead of shut.
    public mutating func observed(_ degrees: Double) {
        observed(degrees, at: Date())
    }

    /// The angle SpringBoard said a panel change ended at, `at`: nothing when something newer is known of the hinge (a
    /// view opening reads the boot's log, older than a sweep made since that changed no panel and so said nothing there).
    public mutating func observed(_ degrees: Double, at: Date) {
        guard asking.isEmpty, (0...180).contains(degrees), learnt.map({ at > $0 }) ?? true else { return }
        self.degrees = degrees
        learnt = at
    }
}

/// The views open now of each device, held weakly: a view that ended is gone from it.
public final class DeviceViews<View: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var views: [String: NSHashTable<View>] = [:]

    public init() {}

    public func add(_ udid: String, _ view: View) {
        lock.lock()
        defer { lock.unlock() }
        if views[udid] == nil { views[udid] = NSHashTable<View>.weakObjects() }
        views[udid]!.add(view)
    }

    public func all(_ udid: String) -> [View] {
        lock.lock()
        defer { lock.unlock() }
        return views[udid]?.allObjects ?? []
    }
}

/// A value by UDID, for the views after this one.
private final class Known<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]

    subscript(udid: String) -> Value? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return values[udid]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            values[udid] = newValue
        }
    }

    /// Changes a device's value in one step: views of one device change it from their own tasks.
    @discardableResult
    func update<Result>(_ udid: String, _ initial: Value, _ change: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        var value = values[udid] ?? initial
        defer { values[udid] = value }
        return change(&value)
    }
}

/// How many quarter turns from upright a device was last turned from here.
private enum KnownTurns { static let shared = Known<DeviceTurn>() }
/// The panel each device was last shown on by a view here (true: the cover).
private enum KnownPanels { static let shared = Known<Bool>() }
/// Each device's hinge, shared by its views.
private enum KnownHinges { static let shared = Known<DeviceHinge>() }
/// Each foldable's open views.
private enum FoldingViews { static let shared = DeviceViews<SimulatorStreamSession>() }
/// Every open view of a device, which all turn with it.
private enum DeviceOpenViews { static let shared = DeviceViews<SimulatorStreamSession>() }
