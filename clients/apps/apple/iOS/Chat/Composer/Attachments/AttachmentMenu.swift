import SwiftUI

/// The + button's open surface and frame. Only the composer and the attachment overlay read them, so opening
/// or closing the card or the chat moving on screen never re-renders the conversation around the composer.
@MainActor @Observable final class AttachmentModel {
    /// What the + has open: nil while the card is folded onto the button.
    var surface: AttachmentSurface?
    /// Where the card grows from and folds back to: the + button's frame in global coordinates, kept while the
    /// card is out, so it still folds onto the button after Camera or Photos lowers the keyboard.
    private(set) var anchor: CGRect = .zero
    /// The button's latest frame. The chat moving (the router zoom, a drag) changes it every frame, so it is
    /// copied into `anchor` only when the card opens or is out.
    @ObservationIgnored var liveFrame: CGRect = .zero
    /// The + is enabled. A touch that turns a folding card back opens it only when the + itself could.
    @ObservationIgnored var canAttach = true

    func pinAnchor() { if anchor != liveFrame { anchor = liveFrame } }
}

/// The + menu's rows, with the desktop's Central Icons in round chips; `AttachmentCard` is their surface.
/// Rows follow native menus: a row lights on touch-down, sliding across rows moves the light with a
/// selection tick, and release on a row chooses it.
struct AttachmentMenu: View {
    enum Choice: CaseIterable { case camera, photos, files }

    let choose: (Choice) -> Void
    @State private var highlighted: Choice?
    @State private var rowFrames: [Choice: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Choice.allCases, id: \.self, content: row)
        }
        .padding(8)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { highlight(at: $0.location) }
            .onEnded { release(at: $0.location) })
        .sensoryFeedback(.selection, trigger: highlighted) { old, new in old != nil && new != nil }
    }

    private func row(_ choice: Choice) -> some View {
        HStack(spacing: 14) {
            CentralIcon(choice.icon, size: 20)
                .frame(width: 40, height: 40)
                .background(CommaTheme.textPrimary.opacity(0.06), in: Circle())
            Text(choice.title).font(.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(CommaTheme.textPrimary)
        .padding(.horizontal, 10)
        .frame(minHeight: 60)
        .background(CommaTheme.textPrimary.opacity(highlighted == choice ? 0.06 : 0),
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames[choice] = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(choice) }
    }

    /// The light lands at once, as on touch-down in a native menu; only its fade-out is animated.
    private func highlight(at point: CGPoint) {
        highlighted = rowFrames.first { $0.value.contains(point) }?.key
    }

    private func release(at point: CGPoint) {
        let choice = rowFrames.first { $0.value.contains(point) }?.key
        withAnimation(.easeOut(duration: 0.15)) { highlighted = nil }
        if let choice { choose(choice) }
    }
}

private extension AttachmentMenu.Choice {
    var icon: String {
        switch self {
        case .camera: "icon-camera"
        case .photos: "icon-photos"
        case .files: "icon-files"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .camera: "Camera"
        case .photos: "Photos"
        case .files: "Files"
        }
    }
}
