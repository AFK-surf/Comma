import SwiftUI
import UIKit
import CommaCore

/// The next message's Routine items, files and photos inside the composer's card, above the text, as ChatGPT holds
/// them: a Routine item as a card with its app's mark and first line, a photo as its own picture, a file as a card
/// with its name and size, each with a remove button in its corner. Each file shows its upload where it sits, and a
/// failed one asks to be tapped to try again.
struct AttachmentTray: View {
    let pane: ConversationPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let side: CGFloat = 96

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(pane.draftTexts) { staged in
                    DraftTextTile(attached: staged.attached, showInField: {
                        withAnimation(CommaMotion.stateChange) { pane.showDraftTextInField(staged.id) }
                    }, remove: {
                        withAnimation(CommaMotion.stateChange) { pane.removeDraftText(staged.id) }
                    })
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
                ForEach(pane.drafts) { draft in
                    AttachmentTile(draft: draft, retry: { pane.retryAttachment(draft.id) }, remove: {
                        withAnimation(CommaMotion.stateChange) { pane.removeAttachment(draft.id) }
                    })
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
                }
            }
            // The card's own inset, so the first tile lines up with the text under it.
            .padding(.horizontal, 10)
        }
        .animation(CommaMotion.settle(reduced: reduceMotion), value: pane.drafts.map(\.id))
        .animation(CommaMotion.settle(reduced: reduceMotion), value: pane.draftTexts.map(\.id))
    }
}

/// A staged Routine item, drawn as a file's card: its app's mark, its first line and the app's name. Held, it offers
/// to put the text in the field instead, as the desktop's tile does.
private struct DraftTextTile: View {
    let attached: ChatAttachedText
    let showInField: () -> Void
    let remove: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let image = ProviderArtwork.image(attached.source) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 20, height: 20)
                        .foregroundStyle(CommaTheme.textPrimary)
                } else {
                    CentralIcon("central-file-bend", size: 20).foregroundStyle(CommaTheme.textSecondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(CommaTheme.bgTertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: attached.title).font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(1)
                (attached.source.map { Text(verbatim: $0) } ?? Text("Text"))
                    .font(.footnote).foregroundStyle(CommaTheme.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 24)
        .frame(width: 220, height: 64, alignment: .leading)
        .background(CommaTheme.bgSecondary)
        .clipShape(shape)
        .overlay(shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            Button(action: showInField) { Text("Show in Text Field") }
            Button(role: .destructive, action: remove) { Text("Remove") }
        }
        .overlay(alignment: .topTrailing) { RemoveButton(action: remove) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: attached.title))
        .accessibilityValue(Text(verbatim: attached.source ?? ""))
        .accessibilityIdentifier("draft-text")
        .accessibilityAction(named: Text("Remove"), remove)
        .accessibilityAction(named: Text("Show in Text Field"), showInField)
    }
}

private struct AttachmentTile: View {
    let draft: DraftAttachment
    let retry: () -> Void
    let remove: () -> Void

    /// The card's 24pt corner less its 10pt inset, so the tile's corner runs with the card's.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }
    private var failed: Bool { if case .failed = draft.state { true } else { false } }

    var body: some View {
        Button(action: retry) {
            Group {
                if draft.isImage, let data = draft.thumbnail, let image = UIImage(data: data) {
                    photo(image)
                } else {
                    file
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 0.5))
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(!failed)
        .overlay(alignment: .topTrailing) { RemoveButton(action: remove) }
        .animation(CommaMotion.stateChange, value: draft.state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(draft.file.filename))
        .accessibilityValue(status)
        .accessibilityAction(named: Text("Remove"), remove)
        .accessibilityAction(named: Text("Try Again")) { if failed { retry() } }
    }

    /// A photo, dimmed under its progress or its retry while it is not yet uploaded.
    private func photo(_ image: UIImage) -> some View {
        Image(uiImage: image).resizable().scaledToFill()
            .frame(width: AttachmentTray.side, height: AttachmentTray.side)
            .overlay {
                switch draft.state {
                case .uploading:
                    ZStack { Color.black.opacity(0.3); ProgressView().tint(.white) }.transition(.opacity)
                case .failed:
                    ZStack {
                        Color.black.opacity(0.45)
                        CentralIcon("central-arrow-rotate-clockwise", size: 20).foregroundStyle(.white)
                    }
                    .transition(.opacity)
                case .ready:
                    EmptyView()
                }
            }
    }

    /// A file: its kind, its name, and how far it has come.
    private var file: some View {
        HStack(spacing: 10) {
            CentralIcon("central-file-bend", size: 20)
                .foregroundStyle(CommaTheme.textSecondary)
                .frame(width: 40, height: 40)
                .background(CommaTheme.bgTertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.file.filename).font(.subheadline.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    if draft.state == .uploading { ProgressView().controlSize(.mini) }
                    status.font(.footnote).foregroundStyle(failed ? CommaTheme.attention : CommaTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 24)
        .frame(width: 220, height: 64, alignment: .leading)
        .background(CommaTheme.bgSecondary)
    }

    private var status: Text {
        switch draft.state {
        case .uploading: Text("Uploading…")
        case .failed: Text("Couldn’t upload. Tap to retry.")
        case .ready: Text(Self.detail(of: draft.file))
        }
    }

    /// "PDF · 1.2 MB"
    private static func detail(of file: AttachmentPayload) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
        let kind = (file.filename as NSString).pathExtension.uppercased()
        return kind.isEmpty ? size : "\(kind) · \(size)"
    }

}

/// A dark glassy circle with a white cross inside a tile's corner, as ChatGPT draws it, in a 36pt target.
private struct RemoveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CentralIcon("icon-close", size: 10)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.black.opacity(0.5), in: Circle())
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(TactileButtonStyle(scale: 0.85))
        .accessibilityHidden(true)
    }
}
