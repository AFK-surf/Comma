import SwiftUI
import CommaCore

/// A compact Task row, the same on Home, in Search and in the Archive: the status glyph and a two-line title.
/// Running progress is the accessibility value instead of a subtitle. The press surface appears on
/// touch-down; the action runs on touch-up.
struct TaskListRow: View {
    let task: TaskSummary
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TaskRowLabel(task: task, pinned: pinned)
        }
        .buttonStyle(TaskRowButtonStyle())
        .accessibilityValue(Text(task.progressLabel ?? String(localized: task.listBucket.label)))
        .accessibilityIdentifier("task-" + task.id)
    }
}

/// What every Task row shows, so a row reads the same wherever it appears: the status glyph, the title in up
/// to two lines, then the Loop kind chip on a Loop Task, a pin when pinned and the caller's `details` (the Inbox's
/// age), which drop under the title at accessibility sizes. A row that acts wraps it in a `Button` styled with
/// `TaskRowButtonStyle`.
struct TaskRowLabel<Details: View>: View {
    let task: TaskSummary
    let pinned: Bool
    /// The Inbox's read state; nil in lists without one. An unread row puts its dot before the status glyph, in
    /// room only it has, so a read row's glyph lines up with an unread row's dot. The title keeps its weight, as on
    /// the desktop.
    var unread: Bool?
    @ViewBuilder let details: Details
    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 18
    /// Centres the glyph on the title's first line.
    @ScaledMetric(relativeTo: .body) private var glyphInset: CGFloat = 2
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let titleAndDetails = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                if let unread { UnreadSlot(unread: unread, height: glyphSize, inset: glyphInset) }
                // Archived rows show the status they were archived from, standing still, as does a row whose status
                // is not known yet.
                TaskStatusIcon(bucket: task.listBucket, size: glyphSize, spins: !task.isArchived && !task.status.isEmpty)
                    .padding(.top, glyphInset)
            }
            titleAndDetails {
                Text(task.title).font(.body)
                    .foregroundStyle(CommaTheme.textPrimary)
                    // Two lines keep the list scannable; at accessibility sizes two lines hold only a few words.
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if task.loop != nil || pinned || Details.self != EmptyView.self {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let loop = task.loop { loopChip(loop) }
                        if pinned { pin }
                        details
                    }
                    .fixedSize()
                }
            }
        }
        .padding(10)
        .frame(minHeight: 44)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// The filled pin, as for any state that is on. Its foot rests on the title's baseline.
    private var pin: some View {
        CentralIcon("central-pin-fill", size: 14, relativeTo: .body)
            .foregroundStyle(CommaTheme.textPlaceholder)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - $0.height * 0.08 }
            .accessibilityRepresentation { Text("Pinned") }
    }

    /// Every Loop Task keeps this chip, an ended one too: its kind's glyph and name, as on desktop cards.
    /// Larger text sizes show only the glyph beside the title.
    /// Accessibility sizes place the glyph and name below the title.
    @ViewBuilder private func loopChip(_ loop: TaskLoop) -> some View {
        let kind = loop.kind
        let glyph = CentralIcon(kind.iconName, size: 12, relativeTo: .footnote)
            .foregroundStyle(CommaTheme.textQuaternary)
        if typeSize > .large && !typeSize.isAccessibilitySize {
            glyph
                .padding(4)
                .overlay(Circle().strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
                // Its centre sits where the worded chip's does, on the title's first line.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - $0.height * 0.25 }
                .accessibilityRepresentation { Text(verbatim: kind.label) }
        } else {
            HStack(spacing: 3) {
                glyph
                Text(verbatim: kind.label).foregroundStyle(CommaTheme.textSecondary)
            }
            .font(.footnote.weight(.medium))
            .padding(.leading, 5).padding(.trailing, 7).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
        }
    }
}

/// The unread dot and its gap to the glyph, centred on the glyph. Read, the dot shrinks and fades first, then its
/// room closes and the glyph and title slide into the place it held; marked unread again, the room opens first and
/// the dot then appears in it, the same path back. With Reduce Motion both happen at once, as a fade.
private struct UnreadSlot: View {
    let unread: Bool
    let height: CGFloat
    let inset: CGFloat
    /// The row has room for the dot.
    @State private var open: Bool
    /// The dot shows in that room.
    @State private var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let width = AttentionDot.size + 8
    private static let fade = Animation.easeOut(duration: 0.16)

    init(unread: Bool, height: CGFloat, inset: CGFloat) {
        self.unread = unread
        self.height = height
        self.inset = inset
        _open = State(initialValue: unread)
        _shown = State(initialValue: unread)
    }

    var body: some View {
        AttentionDot()
            .scaleEffect(shown ? 1 : 0.2)
            .opacity(shown ? 1 : 0)
            .frame(width: AttentionDot.size, height: height)
            .padding(.top, inset)
            .frame(width: open ? Self.width : 0, alignment: .leading)
            .onChange(of: unread) { _, unread in unread ? arrive() : leave() }
    }

    private func leave() {
        guard !reduceMotion else { return withAnimation(CommaMotion.stateChange) { shown = false; open = false } }
        withAnimation(Self.fade, completionCriteria: .logicallyComplete) { shown = false } completion: {
            // Marked unread again before the dot was gone: the room stays.
            guard !unread else { return }
            withAnimation(CommaMotion.settle(reduced: false)) { open = false }
        }
    }

    private func arrive() {
        guard !reduceMotion else { return withAnimation(CommaMotion.stateChange) { open = true; shown = true } }
        withAnimation(CommaMotion.settle(reduced: false), completionCriteria: .logicallyComplete) { open = true } completion: {
            guard unread else { return }
            withAnimation(Self.fade) { shown = true }
        }
    }
}

extension TaskRowLabel where Details == EmptyView {
    init(task: TaskSummary, pinned: Bool, unread: Bool? = nil) {
        self.init(task: task, pinned: pinned, unread: unread) { EmptyView() }
    }
}

/// Rows have no resting surface; a press paints the item colour the moment the finger lands, like the
/// desktop rail hover, and lets it go without a bounce.
struct TaskRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(CommaTheme.sidebarItem.opacity(configuration.isPressed ? 0.7 : 0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.05) : CommaMotion.release,
                       value: configuration.isPressed)
    }
}
