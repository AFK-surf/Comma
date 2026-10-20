import SwiftUI
import CommaCore

/// A change to the Inbox that the toast can take back for a few seconds.
struct InboxUndo: Identifiable {
    enum Change {
        case cleared([TaskSummary])
        case archived(TaskSummary)
    }

    let id = UUID()
    let change: Change

    var message: String {
        switch change {
        case .cleared(let tasks) where tasks.count > 1: String(localized: "Cleared \(tasks.count)")
        case .cleared: String(localized: "Cleared")
        case .archived: String(localized: "Archived")
        }
    }
}

extension View {
    /// A glass capsule above the tab bar (12pt over the bottom safe area) saying what just happened, with Undo.
    /// It leaves after four seconds, or ten while VoiceOver runs, and a newer change replaces it.
    func inboxUndoToast(_ undo: Binding<InboxUndo?>, perform: @escaping (InboxUndo.Change) async -> Void) -> some View {
        modifier(InboxUndoToast(undo: undo, perform: perform))
    }
}

private struct InboxUndoToast: ViewModifier {
    @Binding var undo: InboxUndo?
    let perform: (InboxUndo.Change) async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                ZStack {
                    if let current = undo { toast(current).id(current.id) }
                }
                .animation(CommaMotion.settle(reduced: reduceMotion), value: undo?.id)
            }
            // Only a new change is announced.
            .onChange(of: undo?.id) { _, _ in
                if let undo { AccessibilityNotification.Announcement(undo.message).post() }
            }
    }

    /// One line, or two at accessibility text sizes, then Undo.
    private func toast(_ current: InboxUndo) -> some View {
        HStack(spacing: 4) {
            Text(current.message).font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
            Button {
                undo = nil
                Task { await perform(current.change) }
            } label: {
                Text("Undo").font(.subheadline.weight(.semibold)).padding(.horizontal, 12)
                    .frame(minHeight: 44).contentShape(Capsule())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.92))
            .foregroundStyle(CommaTheme.brandSolid)
            // "Undo" never breaks; the message gives way instead.
            .fixedSize()
            .accessibilityIdentifier("inboxUndo")
        }
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 16).padding(.trailing, 4)
        // Only "Undo" answers a touch, so the capsule is plain glass rather than interactive glass.
        .commaGlass(in: Capsule())
        .accessibilityElement(children: .contain)
        // At most the screen's width less 16pt a side; the capsule keeps its own width inside.
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        // The glass rises from the tab bar, growing as it comes, and sinks back the same way.
        .transition(reduceMotion ? .opacity
            : .scale(scale: 0.85, anchor: .bottom).combined(with: .offset(y: 16)).combined(with: .opacity))
        .task {
            try? await Task.sleep(for: .seconds(voiceOver ? 10 : 4))
            if undo?.id == current.id { undo = nil }
        }
    }
}
