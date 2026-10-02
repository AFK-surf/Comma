import SwiftUI
import Observation
import CommaCore

/// Whether the Task details are open. Owned by the dock controller, so its drag, collapse and grabber
/// follow it without a SwiftUI round trip.
@MainActor @Observable
final class TaskDockState {
    var detailsOpen = false {
        didSet { if detailsOpen != oldValue { onDetailsChange?(detailsOpen) } }
    }
    /// The header title is held down: the closed card shows its pressed surface.
    var titlePressed = false
    @ObservationIgnored var onDetailsChange: ((Bool) -> Void)?
    /// Top of the resting title capsule, from the sheet's top edge; the grabber centres above it.
    @ObservationIgnored var capsuleTop: CGFloat = 12 {
        didSet { if capsuleTop != oldValue { onCapsuleTopChange?() } }
    }
    @ObservationIgnored var onCapsuleTopChange: (() -> Void)?
}

/// A button whose own press state drives the details card rather than the label alone.
struct PressReportingButtonStyle: ButtonStyle {
    let onPress: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}

/// The title's press response, shared by the title and the surface behind it so both grow together.
enum TaskTitlePress {
    static let scale: CGFloat = 1.04
    static func animation(_ pressed: Bool) -> Animation {
        pressed ? .easeOut(duration: 0.08) : .spring(response: 0.32, dampingFraction: 0.7)
    }
}

/// The coordinate space of the details card, which the header's title reports its frame in.
let taskDetailsCardSpace = "taskDetailsCard"

/// The header title's frame, where the closed card starts its growth.
struct TaskTitleFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// The dock header, which grows in place into the Task's properties (status, origin, Worker, labels),
/// like Slack's channel header: the glass starts as a capsule hugging the title and widens and lengthens
/// into a full-width card, while the header row itself stays put. Any tap outside the card closes it.
struct TaskDetailsCard<Header: View>: View {
    /// The card's inset from the sheet edge, equal on the top and both sides.
    static var inset: CGFloat { 8 }
    /// Header row height inside the card; with the inset it lands the row where the dock bar puts it.
    private static var headerHeight: CGFloat { TaskDockViewController.barHeight - inset }
    private static var radius: CGFloat { 30 }
    private static var spring: Animation { .spring(response: 0.42, dampingFraction: 0.86) }
    /// The two axes run on their own springs: opening leads with height, closing leads with width.
    private static var leadingAxis: Animation { .spring(response: 0.25, dampingFraction: 0.88) }
    private static var trailingAxis: Animation { .spring(response: 0.38, dampingFraction: 0.86) }

    let store: CommaStore
    @Bindable var pane: ConversationPane
    @Bindable var state: TaskDockState
    @ViewBuilder let header: () -> Header
    @State private var naturalHeight: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var titleFrame: CGRect = .zero
    /// Vertical travel of a drag outside the open card: it stretches the card, and a pull up closes it on release.
    @State private var dragTravel: CGFloat = 0
    /// Drive the card's width and height separately, each following `detailsOpen` on its own spring.
    @State private var wide = false
    @State private var tall = false
    /// Drives the details' opacity: on with the growth, but off only once the shrink has finished.
    @State private var surfaceShown = false

    var body: some View {
        let open = state.detailsOpen
        let pressed = state.titlePressed && !wide && !tall
        let closed = pressed ? closedRect.scaled(TaskTitlePress.scale) : closedRect
        let open_ = openRect
        let rect = CGRect(x: wide ? open_.minX : closed.minX, y: tall ? open_.minY : closed.minY,
                          width: wide ? open_.width : closed.width, height: tall ? open_.height : closed.height)
        // A capsule while short, the card radius once tall enough.
        let shape = RoundedRectangle(cornerRadius: min(Self.radius, rect.height / 2), style: .continuous)
        ZStack(alignment: .topLeading) {
            if open {
                // Outside the card: a tap closes it; a drag pulls on it without moving it.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { state.detailsOpen = false }
                    .simultaneousGesture(drag)
                    .accessibilityHidden(true)
            }
            ZStack(alignment: .topLeading) {
                surface(rect: rect, shape: shape, open: open, pressed: pressed, lifted: tall)
                VStack(alignment: .leading, spacing: 0) {
                    // A 50pt row centred where the dock bar centres it (10pt below the sheet top).
                    header()
                        .frame(height: 50)
                        .padding(.top, Self.headerHeight - 50)
                        .padding(.horizontal, -Self.inset)
                    TaskDetailsContent(store: store, pane: pane, task: pane.conversation ?? store.taskSummary(id: pane.taskID ?? ""))
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 20)
                        .opacity(surfaceShown ? 1 : 0)
                        .blur(radius: surfaceShown ? 0 : 6)
                        .allowsHitTesting(open)
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                .padding([.horizontal, .top], Self.inset)
                // The details show only inside the growing surface; the header row is never clipped.
                .mask(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().frame(height: TaskDockViewController.barHeight)
                        shape.axisFrame(rect)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // A drag outside the card pulls on it: up, it gives a little; down, it stretches a little.
            .scaleEffect(stretch, anchor: .top)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(taskDetailsCardSpace))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onPreferenceChange(TaskTitleFrameKey.self) { value in
            MainActor.assumeIsolated { titleFrame = value }
        }
        .animation(TaskTitlePress.animation(state.titlePressed), value: state.titlePressed)
        .animation(Self.spring, value: naturalHeight)
        // Opening the details from the title plays a tap; closing stays silent.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: open) { _, open in open }
        .onChange(of: closedRect.minY, initial: true) { _, top in state.capsuleTop = top }
        .onChange(of: open) { _, open in
            if open {
                // Opening, the card drops down first and widens behind it.
                withAnimation(Self.leadingAxis) { tall = true }
                withAnimation(Self.trailingAxis) { wide = true }
                withAnimation(.easeOut(duration: 0.16)) { surfaceShown = true }
            } else {
                // Closing, it narrows first and lifts behind it, fully opaque; only then does it fade.
                withAnimation(Self.leadingAxis) { wide = false }
                withAnimation(Self.trailingAxis, completionCriteria: .logicallyComplete) {
                    tall = false
                } completion: {
                    guard !state.detailsOpen else { return }
                    withAnimation(.easeOut(duration: 0.12)) { surfaceShown = false }
                }
            }
        }
        .task(id: open) {
            if open { await pane.loadLabelCatalog() }
        }
    }

    /// The title always sits on glass; pressed, a fill tints through it, and open, the same glass grows
    /// into the card and lifts with a deeper shadow.
    private func surface(rect: CGRect, shape: RoundedRectangle, open: Bool, pressed: Bool, lifted: Bool) -> some View {
        ZStack {
            shape.fill(CommaTheme.bgTertiary)
                .opacity(pressed ? 1 : 0)
            Color.clear
                .detailsGlass(in: shape, lifted: lifted)
        }
        .frame(width: rect.width)
        .frame(height: rect.height)
        .contentShape(shape)
        .onTapGesture {}
        .allowsHitTesting(open)
        .offset(x: rect.minX)
        .offset(y: rect.minY)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { dragTravel = $0.translation.height }
            .onEnded { value in
                // Released after pulling up, the card closes; after pulling down, it springs back.
                if value.translation.height < -12 || value.predictedEndTranslation.height < -60 {
                    state.detailsOpen = false
                }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.68)) { dragTravel = 0 }
            }
    }

    /// Rubber-banded: the further the finger goes, the less the card follows.
    private var stretch: CGFloat {
        dragTravel < 0 ? 1 - 0.06 * tanh(-dragTravel / 260) : 1 + 0.04 * tanh(dragTravel / 260)
    }

    private var openRect: CGRect {
        CGRect(x: Self.inset, y: Self.inset, width: max(0, width - Self.inset * 2),
               height: max(naturalHeight, Self.headerHeight))
    }

    /// A capsule just around the title and status; the full header band until the title is measured.
    private var closedRect: CGRect {
        guard titleFrame != .zero else {
            return CGRect(x: Self.inset, y: Self.inset, width: max(0, width - Self.inset * 2), height: Self.headerHeight)
        }
        return titleFrame.insetBy(dx: -14, dy: -5)
    }
}

private struct TaskDetailsContent: View {
    let store: CommaStore
    @Bindable var pane: ConversationPane
    let task: Conversation?
    @State private var historyOpen = false
    @State private var labelsOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let task {
                section("Properties") {
                    FlowLayout(spacing: 6) {
                        pill {
                            TaskStatusIcon(bucket: task.bucket, size: 18)
                            Text(task.bucket.label)
                        }
                        if task.canAcceptReview {
                            Button { Task { await pane.acceptReview() } } label: {
                                pill { Text("Done") }
                            }
                            .buttonStyle(TactileButtonStyle(scale: 0.94))
                        }
                        if let origin = TaskOrigin(rawValue: task.origin ?? "") {
                            pill {
                                origin.icon
                                Text(origin.label)
                            }
                        }
                        if task.origin == "comma", let platform = task.clientPlatform {
                            pill {
                                Image(systemName: platformSymbol(platform))
                                    .font(.system(size: 14)).foregroundStyle(CommaTheme.textQuaternary)
                                    .frame(width: 18, height: 18)
                                Text(platformLabel(platform))
                            }
                        }
                    }
                }
                if let worker = pane.boundWorker {
                    section("Worker") {
                        Button { historyOpen = true } label: {
                            pill {
                                WorkerAvatar(identity: worker.actorID ?? worker.participantID, size: 18)
                                Text(worker.name.isEmpty ? String(localized: "Worker") : worker.name)
                                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(CommaTheme.textPlaceholder)
                            }
                        }
                        .buttonStyle(TactileButtonStyle(scale: 0.96))
                        .accessibilityHint("Shows the Worker’s steps")
                        .sheet(isPresented: $historyOpen) {
                            if let target = pane.target { WorkerHistoryView(store: store, target: target, worker: worker) }
                        }
                    }
                }
                section("Labels") { labels(task) }
            }
        }
        .sheet(isPresented: $labelsOpen) {
            NavigationStack {
                TaskLabelsView(store: store)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { labelsOpen = false } } }
            }
        }
    }

    // MARK: Labels

    @ViewBuilder private func labels(_ task: Conversation) -> some View {
        let catalog = pane.labelCatalog ?? []
        let applied = (task.labels ?? []).compactMap { id in catalog.first { $0.id == id } }
        let canPick = pane.labelCatalog != nil
        FlowLayout(spacing: 6) {
            ForEach(applied) { label in
                if canPick {
                    labelMenu(task: task, catalog: catalog) { chip(label) }
                } else {
                    chip(label)
                }
            }
            if applied.isEmpty, catalog.isEmpty, pane.labelCatalog != nil {
                Text("No labels").font(.system(size: 15)).foregroundStyle(CommaTheme.textQuaternary)
                    .frame(height: 30)
            }
            if pane.labelCatalog == nil {
                ProgressView().controlSize(.small).frame(height: 30)
            }
            if canPick {
                labelMenu(task: task, catalog: catalog) {
                    Image(systemName: pane.labelsBusy ? "ellipsis" : "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(CommaTheme.textQuaternary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Add label")
            }
        }
        .animation(CommaMotion.spatialMove, value: task.labels ?? [])
    }

    private func labelMenu<Label: View>(task: Conversation, catalog: [TaskLabel],
                                        @ViewBuilder label: () -> Label) -> some View {
        let applied = Set(task.labels ?? [])
        return Menu {
            ForEach(catalog) { item in
                Button {
                    let current = (task.labels ?? []).filter { id in catalog.contains { $0.id == id } }
                    let next = applied.contains(item.id) ? current.filter { $0 != item.id } : current + [item.id]
                    Task { await pane.setLabels(next) }
                } label: {
                    if applied.contains(item.id) {
                        SwiftUI.Label(item.name, systemImage: "checkmark")
                    } else {
                        Text(item.name)
                    }
                }
            }
            Divider()
            Button("Manage labels…", systemImage: "tag") { labelsOpen = true }
        } label: { label() }
        .disabled(pane.labelsBusy)
    }

    private func chip(_ label: TaskLabel) -> some View {
        pill {
            Circle().fill(TaskLabelColor.color(label.color)).frame(width: 8, height: 8)
            Text(label.name)
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(CommaTheme.textQuaternary)
            content()
        }
    }

    /// The desktop `comma-task-panel-pill`: a hairline capsule around an icon and a label.
    private func pill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(CommaTheme.textPrimary)
            .lineLimit(1)
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(height: 30)
            .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
            .contentShape(Capsule())
    }

    private func platformSymbol(_ platform: String) -> String {
        switch platform {
        case "ios", "android": "iphone"
        case "web": "globe"
        default: "laptopcomputer"
        }
    }

    private func platformLabel(_ platform: String) -> String {
        switch platform {
        case "macos": "macOS"
        case "windows": "Windows"
        case "linux": "Linux"
        case "ios": "iOS"
        case "android": "Android"
        case "web": String(localized: "Web browser")
        default: String(localized: "Unknown device")
        }
    }
}

/// Where a Task was asked for, as on the desktop Task panel.
private enum TaskOrigin: String {
    case slack, telegram, feishu, wechat, signal, comma

    var label: String {
        switch self {
        case .slack: "Slack"
        case .telegram: "Telegram"
        case .feishu: String(localized: "Feishu")
        case .wechat: String(localized: "WeChat")
        case .signal: "Signal"
        case .comma: "Comma"
        }
    }

    @ViewBuilder var icon: some View {
        switch self {
        case .comma:
            CommaMark(size: 15).foregroundStyle(CommaTheme.textPrimary).frame(width: 18, height: 18)
        default:
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint).frame(width: 18, height: 18)
        }
    }

    private var symbol: String {
        switch self {
        case .wechat: "bubble.left.and.bubble.right.fill"
        case .telegram: "paperplane.fill"
        case .signal: "bubble.left.fill"
        default: "number"
        }
    }

    private var tint: Color {
        switch self {
        case .wechat: Color(hex: 0x07C160)
        case .telegram: Color(hex: 0x2AABEE)
        case .signal: Color(hex: 0x3A76F0)
        case .feishu: Color(hex: 0x3370FF)
        default: CommaTheme.textSecondary
        }
    }
}

/// Label colours from the desktop palette (`.comma-label-dot`): a preset name or a `#rrggbb` custom colour.
enum TaskLabelColor {
    static func color(_ value: String) -> Color {
        if value.hasPrefix("#"), value.count == 7, let hex = UInt32(value.dropFirst(), radix: 16) { return Color(hex: hex) }
        switch value {
        case "blue": return Color(hex: 0x0BA5EC)
        case "indigo": return Color(hex: 0x6172F3)
        case "purple": return Color(hex: 0x7A5AF8)
        case "pink": return Color(hex: 0xF670C7)
        case "orange": return Color(hex: 0xF38744)
        case "warning": return Color(hex: 0xFAC515)
        case "success": return Color(hex: 0x47CD89)
        case "error": return Color(hex: 0xF97066)
        case "brand": return Color(hex: 0x205BFF)
        default: return Color(hex: 0xB6B8BB)
        }
    }
}

/// The desktop Worker fingerprint (`workerMeshGradientStyle`): the same salted hashes pick the palette
/// and highlight position, so one Worker looks the same on every client.
struct WorkerAvatar: View {
    let identity: String
    var size: CGFloat = 20

    private static let palettes: [(light: UInt32, accent: UInt32, depth: UInt32)] = [
        (0xA5B4FC, 0x6366F1, 0x3730A3), (0x7DD3FC, 0x0EA5E9, 0x075985), (0x99F6E4, 0x14B8A6, 0x115E59),
        (0xA7F3D0, 0x10B981, 0x065F46), (0xFDE68A, 0xF59E0B, 0xB45309), (0xFED7AA, 0xF97316, 0xC2410C),
        (0xFECDD3, 0xFB7185, 0xBE123C), (0xFBCFE8, 0xEC4899, 0x9D174D), (0xDDD6FE, 0x8B5CF6, 0x5B21B6),
        (0xC4B5FD, 0x7C3AED, 0x4338CA),
    ]

    var body: some View {
        let seeds = [0x243F6A88, 0x85A308D3, 0x13198A2E, 0x03707344].map { Self.hash(identity, salt: UInt32($0)) }
        let palette = Self.palettes[Int(seeds[0] % UInt32(Self.palettes.count))]
        let light = UnitPoint(x: Self.channel(seeds[1], 3, 30, 7) / 100, y: Self.channel(seeds[1], 13, 25, 5) / 100)
        let tint = UnitPoint(x: Self.channel(seeds[2], 4, 33, 57) / 100, y: Self.channel(seeds[2], 15, 34, 52) / 100)
        Circle()
            .fill(LinearGradient(colors: [Color(hex: palette.light), Color(hex: palette.accent), Color(hex: palette.depth)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().fill(RadialGradient(colors: [Color(hex: palette.light), .clear], center: tint,
                                                  startRadius: 0, endRadius: size * 0.58)))
            .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.7), .white.opacity(0.12), .clear], center: light,
                                                  startRadius: 0, endRadius: size * 0.48)))
            .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private static func hash(_ identity: String, salt: UInt32) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5 ^ salt
        for unit in identity.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x01000193
            hash ^= hash >> 13
        }
        hash = (hash ^ (hash >> 16)) &* 0x85EBCA6B
        hash = (hash ^ (hash >> 13)) &* 0xC2B2AE35
        return hash ^ (hash >> 16)
    }

    private static func channel(_ seed: UInt32, _ shift: UInt32, _ range: UInt32, _ offset: UInt32) -> CGFloat {
        CGFloat(offset + (seed >> shift) % range)
    }
}

private extension Shape {
    /// Width, height and position as separate modifiers, so each axis animates on its own transaction.
    func axisFrame(_ rect: CGRect) -> some View {
        frame(width: rect.width).frame(height: rect.height).offset(x: rect.minX).offset(y: rect.minY)
    }
}

private extension CGRect {
    /// Grown about its own centre.
    func scaled(_ factor: CGFloat) -> CGRect {
        insetBy(dx: -width * (factor - 1) / 2, dy: -height * (factor - 1) / 2)
    }
}

/// Wraps chips onto as many lines as they need.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

private extension View {
    /// A dense glass: the card holds text, so the transcript only tints through it. Lifted (the open card)
    /// it casts a deeper shadow than the resting title capsule.
    @ViewBuilder func detailsGlass<S: Shape>(in shape: S, lifted: Bool) -> some View {
        let shadow = Color.black.opacity(lifted ? 0.12 : 0.05)
        let radius: CGFloat = lifted ? 24 : 8
        if #available(iOS 26.0, *) {
            self.background(shape.fill(CommaTheme.bgPrimary.opacity(0.35)))
                .glassEffect(.regular.tint(CommaTheme.bgPrimary.opacity(0.6)), in: shape)
                .shadow(color: shadow, radius: radius, y: lifted ? 8 : 2)
        } else {
            self.background {
                ZStack {
                    shape.fill(CommaTheme.bgPrimary.opacity(0.5))
                    shape.fill(.thickMaterial)
                    shape.stroke(CommaTheme.borderPrimary.opacity(0.7), lineWidth: 0.5)
                }
                .shadow(color: shadow, radius: radius, y: lifted ? 8 : 2)
            }
        }
    }
}
