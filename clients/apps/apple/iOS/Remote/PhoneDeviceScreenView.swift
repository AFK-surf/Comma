import SwiftUI

/// One device a computer's station lists, as `devices.listScreens` gives it.
struct ListedDeviceScreen: Identifiable, Hashable, Sendable {
    let id: String
    let instance: String
    let title: String
    let width: Int
    let height: Int
    let buttons: [String]
    /// The ways a foldable can stand (`closed`, `book`, `open`); none for a device that does not fold.
    let poses: [String]
    /// How a device that both closes and opens (an iPhone Duo) can be shown and held; none for others.
    let postures: [DuoPosture]
    /// How it looks flat: its panels, and its case where its computer has Xcode's.
    let look: DeviceLook
    let simulator: Bool

    init?(_ row: NSDictionary) {
        guard let id = row.string("id"), let instance = row.string("instance") else { return nil }
        self.id = id; self.instance = instance
        title = row.string("title") ?? row.string("name") ?? id
        width = row.int("width") ?? 0; height = row.int("height") ?? 0
        buttons = row.object("capabilities")?.strings("buttons") ?? []
        poses = row.object("capabilities")?.strings("poses") ?? []
        postures = row.objects("postures").compactMap(DuoPosture.init)
        look = DeviceLook(row.object("capabilities"))
        simulator = id.hasPrefix("simulator:")
    }
}

/// A live view of one device on a computer, full screen: its picture fills the page, a finger on it is the device's
/// finger while this view drives, and the device's buttons sit in a toolbar beside it. The view ends a moment after the
/// page goes or the app goes to the background (`DeviceScreenSession.keptFor`), and opens again when it comes back.
struct PhoneDeviceScreenView: View {
    let scope: WorkspaceSettingsScope
    let device: String
    let station: String?
    let screen: ListedDeviceScreen
    @State private var session: DeviceScreenSession?
    /// How this phone reaches the computer now: `direct` (on the same network, or a punched path), `relay` or `salix`.
    @State private var via: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            CommaTheme.bgPrimary.ignoresSafeArea()
            if let session {
                DeviceScreenPanel(session: session, screen: screen, via: via, close: { dismiss() },
                                  retry: { restart(fresh: true) })
            }
        }
        // The system's bar, clear and over the device: the page's way back and what it shows (`DeviceScreenPanel`).
        .navigationTitle(Text(verbatim: screen.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        // Only the background ends the view: a screenshot's preview, Control Center or a banner only makes the app
        // inactive a while, and the picture goes on meanwhile.
        .task(id: TaskKey(active: scenePhase != .background, session: session.map(ObjectIdentifier.init))) {
            guard scenePhase != .background else { return }
            if session == nil { restart(); return }
            await session?.run()
        }
        // Keeps the computer's station linked while the page shows, and says how it is reached as that changes: the
        // mesh moves to a direct path (the same network) by itself when one answers sooner than a relay.
        .task(id: station) {
            let workspace = scope.workspace.id, station = station
            for await value in scope.store.core.subscribe(["topic": "stations", "workspace": workspace], read: { value in
                ((value as? NSDictionary)?.objects("ownComputers").first { $0.string("id") == station })?.object("link")?.string("via")
            }) {
                if case .value(let next) = value { via = next }
            }
        }
    }

    private struct TaskKey: Hashable {
        let active: Bool
        let session: ObjectIdentifier?
    }

    /// Takes up the view open for this device (this page built again), or opens one: always a new one to retry.
    private func restart(fresh: Bool = false) {
        session = fresh
            ? DeviceScreenSession(scope: scope, device: device, screen: screen.id, instance: screen.instance,
                                  postures: screen.postures, look: screen.look)
            : DeviceScreenSession.reusing(scope: scope, device: device, screen: screen.id, instance: screen.instance,
                                          postures: screen.postures, look: screen.look)
    }
}

/// The page's content: the device's stage, and its toolbar under it in a tall layout or down its left in a wide one.
/// The system's bar carries the way back, what the device is and how it is reached, and in a wide layout the device's
/// postures: an iPhone Duo puts them in its side bar, under its status. The stage uses the whole page, under that bar
/// too; the toolbar stays in the safe area, but for a side status column, which it is centred across.
struct DeviceScreenPanel: View {
    let session: DeviceScreenSession
    let screen: ListedDeviceScreen
    let via: String?
    let close: () -> Void
    let retry: () -> Void
    /// How long a 3D device takes to move between postures.
    var postureDuration: TimeInterval = 0.6
    @State private var typing = false
    @State private var text = ""
    @Environment(\.usesVerticalToolbar) private var verticalBar

    var body: some View {
        GeometryReader { geometry in
            // Wide by its shape: a tall page keeps its toolbar at the bottom, whatever its size class.
            let wide = geometry.size.width > geometry.size.height
            // A status column down the trailing side (an iPhone Duo open in landscape) keeps more room there than
            // anywhere; a notched phone in landscape keeps the same both sides.
            let insets = geometry.safeAreaInsets
            let sideStatus = insets.trailing > max(insets.leading, insets.top)
            // The device and the line over it stay in the middle of the whole display: the room the toolbar and the
            // display's insets take on one side is kept on the other as well.
            // (the top's inset is the bar's, and the line's under it when the bar has no middle for it)
            let top = insets.top + (aboutOver(wide: wide) ? Self.lineRoom : 0)
            let across = wide ? max(insets.leading, insets.trailing) + Self.toolbarRoom : 0
            let down = wide ? max(top, insets.bottom) : max(top, insets.bottom + Self.toolbarRoom)
            ZStack {
                stage(wide: wide)
                    .padding(.horizontal, across)
                    .padding(.vertical, down)
                    .ignoresSafeArea()
                notes(about: aboutOver(wide: wide))
                    .padding(.top, 4)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(.container, edges: [.leading, .trailing])
                if wide {
                    toolbar(vertical: true).padding(.leading, 12).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else {
                    toolbar(vertical: false).padding(.horizontal, 12).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .ignoresSafeArea(.container, edges: sideStatus ? .trailing : [])
                }
            }
            .toolbar { navigationItems(wide: wide) }
            // The page's title is that line: in the bar's middle as the title's stand-in, or, shown over the stage, the
            // system's title goes (a side bar puts it at the top leading corner, a top one beside the way back).
            .toolbar(removing: aboutOver(wide: wide) ? .title : nil)
        }
        .alert(Text("Type on the device"), isPresented: $typing) {
            TextField(text: $text) { Text("Text") }
            Button("Send") { sendText() }
            Button("Cancel", role: .cancel) { text = "" }
        }
    }

    @ToolbarContentBuilder private func navigationItems(wide: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(action: close) { Label { Text("Close") } icon: { Image(systemName: "chevron.backward") } }
        }
        .verticalBarPreferred()
        if !aboutOver(wide: wide) {
            ToolbarItem(placement: .principal) { about }
        }
        if wide, !session.postures.isEmpty {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ForEach(session.postures) { posture in postureButton(posture) }
            }
            .verticalBarPreferred()
        }
    }

    /// One posture in the bar, all of them on one glass: a toggle, which the bar draws on for the one the device
    /// shows in.
    private func postureButton(_ posture: DuoPosture) -> some View {
        Toggle(isOn: Binding(get: { session.posture?.id == posture.id }, set: { on in
            if on { session.choose(posture: posture) }
        })) {
            Label { posture.title } icon: { PostureGlyph.image(posture.icon) }
        }
        .disabled(!session.control || session.phase != .live)
    }

    /// The device.
    private func stage(wide: Bool) -> some View {
        ZStack {
            if session.textures != nil {
                DuoStageView(session: session, duration: postureDuration)
            } else {
                DeviceScreenStage(session: session).padding(wide ? 12 : 16)
            }
            if session.phase != .live {
                DeviceScreenStatus(phase: session.phase, retry: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// How far a toolbar reaches in from its edge of the safe area: its buttons, their glass and its margin.
    private static let toolbarRoom: CGFloat = 64
    /// The line over the stage, when it shows there.
    private static let lineRoom: CGFloat = 24

    /// Whether what the device is and how it is reached shows over the stage, not in the bar's middle: a side bar has
    /// none, and a wide one gives its middle up to the postures beside it.
    private func aboutOver(wide: Bool) -> Bool { verticalBar || wide }

    /// Over the stage's top: what the device is and how it is reached when the bar is a side one, and why the view
    /// does not drive.
    @ViewBuilder private func notes(about: Bool) -> some View {
        // The flat picture glows while an agent uses the device; the model says so here.
        let agent = session.agent && session.textures != nil
        VStack(spacing: 2) {
            if about { self.about }
            if let refused = session.refused {
                Text(verbatim: refused).multilineTextAlignment(.center).foregroundStyle(CommaTheme.textSecondary)
            }
            if agent {
                Label { Text("An agent is using this device") } icon: { Image(systemName: "sparkles") }
                    .foregroundStyle(CommaTheme.agentAvatar)
            }
        }
        .font(.caption)
    }

    /// What the device is and how the computer is reached, quietly.
    private var about: some View {
        let route = via.flatMap { session.phase == .live ? $0 : nil }
        return HStack(spacing: 6) {
            Text(verbatim: screen.title)
            if let route {
                Text(verbatim: "·")
                Label {
                    Text(route == "direct" ? "Direct connection" : route == "salix" ? "Through Comma's relay" : "Through a relay")
                } icon: {
                    Image(systemName: route == "direct" ? "bolt.horizontal" : "arrow.triangle.branch")
                }
                .labelStyle(.titleAndIcon)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(CommaTheme.textTertiary)
    }

    @ViewBuilder private func toolbar(vertical: Bool) -> some View {
        let bar = DeviceToolbarContent(vertical: vertical) {
            if session.offersChoice { watchOrControl(vertical: vertical) }
        } device: {
            deviceButtons(postures: !vertical)
        }
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 8) { bar }
        } else {
            bar
        }
    }

    private func watchOrControl(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            ForEach([false, true], id: \.self) { on in
                Button { session.choose(control: on) } label: {
                    Image(systemName: on ? "hand.point.up.left" : "eye")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(session.control == on ? Color.white : CommaTheme.textPrimary)
                        .background { if session.control == on { Circle().fill(CommaTheme.brandSolid) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(on ? Text("Control") : Text("Watch"))
                .accessibilityAddTraits(session.control == on ? .isSelected : [])
            }
        }
        .padding(3)
        .modifier(DeviceToolbarGlass(shape: Capsule()))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Watch or control"))
    }

    /// The device's buttons; its postures as a menu among them when they have no column of their own.
    @ViewBuilder private func deviceButtons(postures: Bool) -> some View {
        Group {
            if postures, !session.postures.isEmpty { postureMenu }
            if has("home") { DeviceButton(label: Text("Home"), icon: "circle") { press(key: "h", code: "KeyH", mods: Self.meta | Self.shift) } }
            if has("lock") { DeviceButton(label: Text("Lock"), icon: "lock") { press(key: "l", code: "KeyL", mods: Self.meta) } }
            if has("volume") {
                DeviceButton(label: Text("Volume down"), icon: "speaker.wave.1") { session.send(["t": "device", "name": "volume_down"]) }
                DeviceButton(label: Text("Volume up"), icon: "speaker.wave.3") { session.send(["t": "device", "name": "volume_up"]) }
            }
            // A device with postures turns with them.
            if has("rotate"), session.postures.isEmpty {
                DeviceButton(label: Text("Rotate"), icon: "rotate.right") { session.send(["t": "device", "name": "rotate"]) }
            }
            // A foldable without postures goes to each way it can stand but the one it stands in (the desktop's
            // `screenDeviceActions`): closed shows its outer screen, open its inner one.
            if session.postures.isEmpty {
                ForEach(PhoneDeviceScreenView.poseChoices(screen.poses, now: session.pose), id: \.pose) { choice in
                    DeviceButton(label: choice.label, icon: choice.icon) { session.send(["t": "pose", "name": choice.pose]) }
                }
            }
            DeviceButton(label: Text("Type on the device"), icon: "keyboard") { typing = true }
        }
        .disabled(!session.control || session.phase != .live)
    }

    private var postureMenu: some View {
        Menu {
            Picker(selection: Binding(get: { session.posture?.id ?? "" }, set: { id in
                if let next = session.postures.first(where: { $0.id == id }) { session.choose(posture: next) }
            })) {
                ForEach(session.postures) { posture in
                    Label { posture.title } icon: { PostureGlyph.image(posture.icon) }.tag(posture.id)
                }
            } label: { Text("Posture") }
                .pickerStyle(.inline)
        } label: {
            DeviceButtonFace(icon: session.posture?.icon ?? "iphone")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Posture"))
    }

    private func sendText() {
        let typed = text
        text = ""
        guard !typed.isEmpty else { return }
        session.send(["t": "text", "text": typed])
    }

    // A device's `mods`: bit 2 meta, 3 shift (`screenStreamInput.ts` `deviceMods`).
    private static let meta = 4
    private static let shift = 8

    private func has(_ button: String) -> Bool { screen.buttons.contains(button) }

    /// A shortcut the station turns into a device's button: ⌘⇧H home, ⌘L lock.
    private func press(key: String, code: String, mods: Int) {
        session.send(["t": "key", "kind": "down", "key": key, "code": code, "mods": mods])
        session.send(["t": "key", "kind": "up", "key": key, "code": code, "mods": mods])
    }
}

extension PhoneDeviceScreenView {
    struct PoseChoice {
        let pose: String
        let label: Text
        let icon: String
    }

    /// The poses a foldable can go to from `now` (open when it says nothing, as a foldable mostly is).
    static func poseChoices(_ poses: [String], now: String?) -> [PoseChoice] {
        let now = now ?? "open"
        let all = [
            PoseChoice(pose: "closed", label: Text("Outer screen"), icon: "rectangle.portrait"),
            PoseChoice(pose: "book", label: Text("Half fold"), icon: "book"),
            PoseChoice(pose: "open", label: Text("Inner screen"), icon: "rectangle.split.2x1"),
        ]
        return all.filter { poses.contains($0.pose) && $0.pose != now }
    }
}

/// The toolbar's two groups, each on its own glass: the page's (Watch or Control) and the device's buttons.
/// A row in a tall layout, a column in a wide one; it scrolls along when the page has not the room.
private struct DeviceToolbarContent<Page: View, Device: View>: View {
    let vertical: Bool
    @ViewBuilder let page: Page
    @ViewBuilder let device: Device

    var body: some View {
        let axis: Axis.Set = vertical ? .vertical : .horizontal
        ViewThatFits(in: axis) {
            groups
            ScrollView(axis, showsIndicators: false) { groups }
        }
    }

    private var groups: some View {
        let outer = vertical ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        let inner = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return outer {
            outer { page }
            inner { device }
                .padding(3)
                .modifier(DeviceToolbarGlass(shape: Capsule()))
        }
        .padding(2)
    }
}

/// Liquid Glass on iOS 26, a material before it.
struct DeviceToolbarGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct DeviceButton: View {
    let label: Text
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { DeviceButtonFace(icon: icon) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
    }
}

/// A toolbar button's icon, on the toolbar's glass.
private struct DeviceButtonFace: View {
    let icon: String
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        PostureGlyph.image(icon)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(CommaTheme.textPrimary.opacity(enabled ? 1 : 0.35))
            .frame(width: 34, height: 34)
            .contentShape(Circle())
    }
}

/// The picture, letterboxed to its own shape, and a finger on it while the view drives. An agent at work on the
/// device shows as a glowing edge and its finger where it touches.
private struct DeviceScreenStage: View {
    let session: DeviceScreenSession
    @State private var finger: CGPoint?
    @State private var movedAt = Date.distantPast

    // A finger's moves reach the device at most this often; its lift carries where it ends.
    private static let moveInterval: TimeInterval = 0.016

    /// The case's pictures once they have come, with the way it stood (`caseID`) they are of.
    @State private var casePictures: (id: String, pictures: DeviceCasePictures)?

    var body: some View {
        let cased = session.caseLayout
        GeometryReader { geometry in
            // (only pictures of the way it stands now: the last ones are of another while the new ones come)
            let pictures = cased.flatMap { cased in
                session.casePictures(cased) ?? casePictures.flatMap { $0.id == Self.caseID(cased) ? $0.pictures : nil }
            }
            // (in its case once its pictures have come; meanwhile in a plain body, as the desktop draws it)
            let shown = pictures == nil ? nil : cased
            let layout = DeviceFrameLayout.of(look: session.look, picture: session.frameSize, cased: shown, in: geometry.size)
            let frame = layout.picture
            let shape = DeviceCornersShape(corners: layout.corners, shapes: layout.shapes)
            ZStack(alignment: .topLeading) {
                DeviceFrameBehind(layout: layout, cased: shown, pictures: pictures)
                ScreenVideoLayerView(renderer: session.renderer)
                    .frame(width: frame.width, height: frame.height)
                    // (the body's own while no picture shows: the screen is part of it, as on the desktop)
                    .background(layout.body == nil ? Color.clear : CommaTheme.deviceBody)
                    .clipShape(shape)
                    .overlay {
                        if session.agent {
                            shape
                                .stroke(CommaTheme.agentAvatar, lineWidth: 3)
                                .shadow(color: CommaTheme.agentAvatar.opacity(0.6), radius: 8)
                                .accessibilityLabel(Text("An agent is using this device"))
                        }
                    }
                    .offset(x: frame.minX, y: frame.minY)
                DeviceFrameOver(layout: layout, cased: shown, pictures: pictures)
                    .allowsHitTesting(false)
                if let at = session.agentPointer, session.agent {
                    Circle()
                        .fill(CommaTheme.agentAvatar.opacity(at.down ? 0.8 : 0.4))
                        .frame(width: 22, height: 22)
                        .position(x: frame.minX + at.x * frame.width, y: frame.minY + at.y * frame.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(touch(in: frame))
            .accessibilityElement()
            .accessibilityLabel(Text("Device screen"))
        }
        .task(id: cased.map(Self.caseID)) {
            guard let cased else { return }
            // (a failed ask is asked again a few times, further apart each time; meanwhile the plain body shows)
            for wait in [2, 4, 8, 0] {
                await session.askCase(cased)
                if let came = session.casePictures(cased) { casePictures = (Self.caseID(cased), came); return }
                guard wait > 0, (try? await Task.sleep(for: .seconds(wait))) != nil else { return }
            }
        }
    }

    private static func caseID(_ cased: DeviceCaseLayout) -> String { "\(cased.key)/\(cased.turn)" }

    private func touch(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard session.control, frame.width > 0 else { return }
                let at = Self.fraction(value.location, in: frame)
                if finger == nil {
                    // A finger that starts outside the picture is not the device's.
                    guard frame.contains(value.startLocation) else { return }
                    finger = at
                    movedAt = Date()
                    session.send(["t": "pointer", "kind": "down", "x": at.x, "y": at.y, "buttons": 1])
                    return
                }
                guard Date().timeIntervalSince(movedAt) >= Self.moveInterval else { return }
                finger = at
                movedAt = Date()
                session.send(["t": "pointer", "kind": "move", "x": at.x, "y": at.y, "buttons": 1])
            }
            .onEnded { value in
                guard finger != nil else { return }
                finger = nil
                let at = Self.fraction(value.location, in: frame)
                session.send(["t": "pointer", "kind": "up", "x": at.x, "y": at.y, "buttons": 0])
            }
    }

    /// Where `point` is in the picture, as fractions of it, clamped to its edges.
    static func fraction(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - frame.minX) / frame.width)),
                y: min(1, max(0, (point.y - frame.minY) / frame.height)))
    }
}

private struct DeviceScreenStatus: View {
    let phase: DeviceScreenSession.Phase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .connecting:
            ProgressView { Text("Connecting") }
        case .failed(let message):
            InlineError(message: message, retry: retry)
        case .live:
            EmptyView()
        }
    }
}


/// The posture glyphs SF Symbols has none for, drawn as template images so a menu and a button tint them as symbols.
enum PostureGlyph {
    /// A device stood as a tent: its two halves meeting at the hinge on top, open below, on a table.
    static let tent = "comma.posture.tent"

    /// `name`'s image: one drawn here, else the SF Symbol of that name.
    static func image(_ name: String) -> Image {
        name == tent ? Image(uiImage: tentImage) : Image(systemName: name)
    }

    private static let tentImage: UIImage = {
        let size = CGSize(width: 22, height: 22)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let halves = UIBezierPath()
            halves.move(to: CGPoint(x: 5.2, y: 17.2))
            halves.addLine(to: CGPoint(x: 11, y: 5.2))
            halves.addLine(to: CGPoint(x: 16.8, y: 17.2))
            halves.lineWidth = 2.1
            halves.lineCapStyle = .round
            halves.lineJoinStyle = .round
            UIColor.black.setStroke()
            halves.stroke()
            let table = UIBezierPath()
            table.move(to: CGPoint(x: 2.6, y: 19.4))
            table.addLine(to: CGPoint(x: 19.4, y: 19.4))
            table.lineWidth = 1.5
            table.lineCapStyle = .round
            table.stroke()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}
