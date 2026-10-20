import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// An Agent's question, drawn as a card under the message that asks it, as the desktop's `QuestionCard` draws it.
/// While it is open the member picks, writes their own answer (with images) or skips; what they send closes it into
/// a receipt, and so does a message they write in the chat instead. Nothing moves: picking, sending and closing
/// change the card at once.
struct QuestionCard: View {
    let question: ChatQuestion
    let pane: ConversationPane

    var body: some View {
        if question.state.status.isOpen {
            // An answer that failed opens a new form, holding what it sent.
            QuestionForm(question: question, pane: pane).id(question.state.status)
        } else {
            QuestionReceipt(question: question)
        }
    }
}

// MARK: - Form

private struct QuestionForm: View {
    let question: ChatQuestion
    let pane: ConversationPane

    @State private var picks: [String]
    @State private var other: String
    /// The other answer is picked: typed into, given an image, or chosen.
    @State private var otherOn: Bool
    /// The listed choice a single-select card goes back to when the other answer empties.
    @State private var lastPick: String?
    @State private var note: Note?
    /// Send was pressed while images upload: the answer goes once they have.
    @State private var waitingForUploads = false
    @State private var picking = false
    @State private var photos: [PhotosPickerItem] = []
    /// Photos picked that are still being read and compressed, before the core has them: the answer waits for them.
    @State private var preparing = 0
    @FocusState private var otherFocused: Bool
    @Environment(\.displayScale) private var displayScale
    /// Half a capital's height at the choices' text size: a control sits that far above the first line's baseline.
    @ScaledMetric(relativeTo: .callout) private var lineCenter: CGFloat = 5.7

    init(question: ChatQuestion, pane: ConversationPane) {
        self.question = question
        self.pane = pane
        let failed = question.state.status == .failed
        let recommended = question.choices.first(where: \.recommended)?.id
        let picks = failed ? question.state.choiceIDs : question.multiSelect ? [] : recommended.map { [$0] } ?? []
        _picks = State(initialValue: picks)
        _other = State(initialValue: failed ? question.state.other ?? "" : "")
        _otherOn = State(initialValue: failed && question.state.other != nil)
        _lastPick = State(initialValue: failed ? picks.first ?? recommended : recommended)
    }

    /// How far below its top the field's first line sits on its baseline, at the reader's text size.
    private static var fieldAscent: CGFloat { UIFont.preferredFont(forTextStyle: .callout).ascender }

    private var multiple: Bool { question.multiSelect }
    private var attachments: [ChatDraftAttachment] { pane.questionAttachments[question.messageID] ?? [] }
    private var hasOther: Bool {
        !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || preparing > 0
    }
    private var uploading: Bool { preparing > 0 || attachments.contains { $0.status == .uploading } }
    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(question.prompt).font(.headline).foregroundStyle(CommaTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if multiple {
                    Text("Choose any").font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                }
            }
            .padding([.horizontal, .top], 16)
            VStack(spacing: 8) {
                ForEach(question.choices) { choice in option(choice) }
                if question.allowOther { otherRow }
            }
            .padding(.horizontal, 8).padding(.top, 12)
            if question.state.status == .failed { failure }
            if let note {
                note.text.font(.footnote).foregroundStyle(CommaTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.top, 8)
            }
            ThirdsLayout(spacing: 8) {
                Button("Skip") { pane.answerQuestion(question.messageID, choiceIDs: [], skipped: true) }
                    .buttonStyle(CommaButtonStyle(hierarchy: .secondary))
                Button("Send", action: submit)
                    .buttonStyle(CommaButtonStyle())
            }
            .padding(8).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CommaTheme.bgSecondary, in: card)
        .overlay(card.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1 / displayScale))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(question.prompt))
        // Typing or adding an image picks the other answer; emptying it gives the pick back.
        .onChange(of: other) { _, _ in
            note = nil
            followOther(hasOther)
        }
        .onChange(of: attachments.map(\.id)) { _, _ in followOther(hasOther) }
        .onChange(of: otherFocused) { _, focused in
            if focused, hasOther { followOther(true) }
        }
        .onChange(of: uploading) { _, now in
            guard waitingForUploads, !now else { return }
            waitingForUploads = false
            submit()
        }
        .onChange(of: photos) { _, items in
            Task { await addPhotos(items) }
        }
    }

    // MARK: Choices

    private func option(_ choice: ChatQuestion.Choice) -> some View {
        let picked = picks.contains(choice.id)
        return Button { choose(choice.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                QuestionIndicator(on: picked, multiple: multiple)
                    .onFirstLine(lineCenter)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(choice.label).font(.callout.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                        if choice.recommended { RecommendedPill() }
                    }
                    if let description = choice.description {
                        Text(description).font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
                    }
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(minHeight: 44)
            .contentShape(QuestionRowStyle.shape)
        }
        .buttonStyle(QuestionRowStyle(picked: picked))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// The other answer: its control and name, a field that grows with its text, an image button, the images under it.
    private var otherRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button(action: pickOther) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        QuestionIndicator(on: otherOn, multiple: multiple)
                            .onFirstLine(lineCenter)
                        Text("Other").font(.callout.weight(.medium)).foregroundStyle(CommaTheme.textPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(otherOn ? .isSelected : [])
                TextField("", text: $other, prompt: Text("Write your answer").foregroundStyle(CommaTheme.textPlaceholder),
                          axis: .vertical)
                    .font(.callout)
                    .foregroundStyle(CommaTheme.textPrimary)
                    .lineLimit(1...6)
                    .focused($otherFocused)
                    .accessibilityLabel(Text("Other"))
                    // An empty field reports its first baseline at its top; its placeholder's sits a line's ascent
                    // below it, as a typed line's does.
                    .alignmentGuide(.firstTextBaseline) { [empty = other.isEmpty, ascent = Self.fieldAscent] in
                        empty ? $0[.top] + ascent : $0[.firstTextBaseline]
                    }
                Button { picking = true } label: {
                    CentralIcon("central-images-1", size: 20)
                        .foregroundStyle(CommaTheme.textTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(TactileButtonStyle())
                .onFirstLine(lineCenter)
                .accessibilityLabel(Text("Add image"))
                .photosPicker(isPresented: $picking, selection: $photos,
                              maxSelectionCount: max(1, pane.attachmentRoom(question.messageID)),
                              matching: .images, preferredItemEncoding: .compatible)
            }
            if !attachments.isEmpty {
                FlowLayout(spacing: 12) {
                    ForEach(attachments) { attachment in
                        QuestionImageTile(attachment: attachment, thumbnail: pane.questionThumbnails[attachment.id],
                                          retry: { pane.retryAttachment(attachment.id, questionMessageID: question.messageID) },
                                          remove: { pane.removeAttachment(attachment.id, questionMessageID: question.messageID) })
                    }
                }
                .padding(.top, 4).padding(.bottom, 6)
                // Under the field, after the control's column.
                .padding(.leading, QuestionIndicator.side + 12)
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
        .frame(minHeight: 44)
        .background(otherOn ? CommaTheme.bgQuaternary : .clear, in: QuestionRowStyle.shape)
        .overlay(QuestionRowStyle.shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
    }

    private var failure: some View {
        HStack(spacing: 8) {
            Text("Not sent. Your choice is kept.").font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: submit)
                .buttonStyle(CommaButtonStyle(hierarchy: .secondary, compact: true))
        }
        .padding(.leading, 12).padding(4)
        .background(CommaTheme.bgPrimary, in: QuestionRowStyle.shape)
        .overlay(QuestionRowStyle.shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
        .padding(.horizontal, 8).padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    // MARK: Picking and sending

    private func choose(_ id: String) {
        note = nil
        if multiple {
            picks = picks.contains(id) ? picks.filter { $0 != id }
                : question.choices.map(\.id).filter { $0 == id || picks.contains($0) }
        } else {
            picks = [id]
            lastPick = id
            otherOn = false
        }
    }

    private func pickOther() {
        note = nil
        if multiple {
            otherOn.toggle()
        } else {
            otherOn = true
            picks = []
        }
        if otherOn { otherFocused = true }
    }

    private func followOther(_ has: Bool) {
        guard has != otherOn else { return }
        otherOn = has
        guard !multiple else { return }
        if has { picks = [] } else if let lastPick { picks = [lastPick] }
    }

    private func submit() {
        let answered = otherOn && hasOther
        if picks.isEmpty && !answered {
            note = multiple ? .pickAny : otherOn ? .otherEmpty : .pickOne
            return
        }
        if answered, attachments.contains(where: { $0.status == .failed }) {
            note = .uploadFailed
            return
        }
        if answered, uploading {
            note = .waitForUploads
            waitingForUploads = true
            return
        }
        note = nil
        otherFocused = false
        pane.answerQuestion(question.messageID, choiceIDs: picks, other: answered ? other : nil)
    }

    /// Photos from the system picker, each added to the other answer as soon as it has loaded.
    private func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        photos = []
        let taken = items.prefix(pane.attachmentRoom(question.messageID))
        // Until each is in the core, the card counts it as uploading, as the composer's `preparing` holds its send.
        preparing += taken.count
        followOther(true)
        for item in taken {
            defer { preparing -= 1 }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let photo = try await AttachmentFile.photo(AttachmentImage(data: data, type: item.supportedContentTypes.first ?? .jpeg))
                await pane.attach(photo.file, thumbnail: photo.thumbnail, questionMessageID: question.messageID).value
            } catch {
                pane.showError(error.localizedDescription)
            }
        }
    }

    private enum Note {
        case pickOne, pickAny, otherEmpty, uploadFailed, waitForUploads

        var text: Text {
            switch self {
            case .pickOne: Text("Choose one, or write your answer in Other.")
            case .pickAny: Text("Choose at least one, or write your answer in Other.")
            case .otherEmpty: Text("Write your answer in Other or add an image, or choose above.")
            case .uploadFailed: Text("An image didn’t upload. Tap it to try again, or remove it.")
            case .waitForUploads: Text("The answer sends when the images finish uploading.")
            }
        }
    }
}

private extension View {
    /// Centres a control on the first line of the text beside it: `center` above that line's baseline.
    func onFirstLine(_ center: CGFloat) -> some View {
        alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + center }
    }
}

/// A choice's row: outlined, and gray while picked or pressed. Only its control takes the brand colour.
private struct QuestionRowStyle: ButtonStyle {
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    let picked: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(picked || configuration.isPressed ? CommaTheme.bgQuaternary : .clear, in: Self.shape)
            .overlay(Self.shape.strokeBorder(CommaTheme.borderPrimary, lineWidth: 1))
    }
}

/// A radio (one choice) or a checkbox (any), outlined until picked, then filled with the brand colour.
private struct QuestionIndicator: View {
    static let side: CGFloat = 20
    let on: Bool
    let multiple: Bool
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = Self.side

    var body: some View {
        Group {
            if multiple {
                let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                if on {
                    shape.fill(CommaTheme.brandSolid)
                        .overlay { CentralIcon("icon-check", size: size).foregroundStyle(.white) }
                } else {
                    shape.fill(CommaTheme.bgPrimary).overlay(shape.strokeBorder(CommaTheme.borderMenuPrimary, lineWidth: 1))
                }
            } else if on {
                Circle().fill(CommaTheme.brandSolid)
                    .overlay { Circle().fill(.white).frame(width: size * 0.4, height: size * 0.4) }
            } else {
                Circle().fill(CommaTheme.bgPrimary).overlay(Circle().strokeBorder(CommaTheme.borderMenuPrimary, lineWidth: 1))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct RecommendedPill: View {
    var body: some View {
        Text("Recommended")
            .font(.caption.weight(.medium))
            .foregroundStyle(CommaTheme.brandSolid)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(CommaTheme.brandSolid.opacity(0.1), in: Capsule())
    }
}

/// An image of the other answer: its picture (dimmed under a spinner while it uploads, behind a retry when it
/// failed) and a remove button that always shows.
private struct QuestionImageTile: View {
    let attachment: ChatDraftAttachment
    let thumbnail: Data?
    let retry: () -> Void
    let remove: () -> Void

    private static let side: CGFloat = 56
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Button(action: retry) {
            ZStack {
                if let thumbnail, let image = UIImage(data: thumbnail) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .opacity(attachment.status == .uploading ? 0.45 : 1)
                } else {
                    CentralIcon("central-images-1", size: 20).foregroundStyle(CommaTheme.textTertiary)
                }
                switch attachment.status {
                case .uploading:
                    ProgressView().controlSize(.small)
                case .failed:
                    ZStack {
                        Color.black.opacity(0.45)
                        CentralIcon("central-arrow-rotate-clockwise", size: 18).foregroundStyle(.white)
                    }
                case .uploaded:
                    EmptyView()
                }
            }
            .frame(width: Self.side, height: Self.side)
            .background(CommaTheme.bgTertiary)
            .clipShape(shape)
            .overlay(shape.strokeBorder(GroupedSurface.ink(0.1), lineWidth: 1))
        }
        .buttonStyle(TactileButtonStyle())
        .disabled(attachment.status != .failed)
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                CentralIcon("icon-cross-small", size: 16)
                    .foregroundStyle(CommaTheme.bgSecondary)
                    .frame(width: 20, height: 20)
                    .background(CommaTheme.textPrimary, in: Circle())
                    .overlay(Circle().stroke(CommaTheme.bgSecondary, lineWidth: 2))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(TactileButtonStyle(scale: 0.85))
            .offset(x: 12, y: -12)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(attachment.name))
        .accessibilityValue(status)
        .accessibilityAction(named: Text("Remove"), remove)
        .accessibilityAction(named: Text("Retry")) { if attachment.status == .failed { retry() } }
    }

    private var status: Text {
        switch attachment.status {
        case .uploading: Text("Uploading")
        case .failed: Text("Upload failed")
        case .uploaded: Text(verbatim: "")
        }
    }
}

/// Two buttons across the card: the first a third of the width, the second the rest.
private struct ThirdsLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let height = zip(subviews, widths(width)).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max()
        return CGSize(width: width, height: height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func widths(_ width: CGFloat) -> [CGFloat] {
        let third = max(0, width - spacing) / 3
        return [third, third * 2]
    }
}

// MARK: - Receipt

/// What a card closes into: what was asked, small, and how it ended.
private struct QuestionReceipt: View {
    let question: ChatQuestion

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(question.prompt).font(.footnote).foregroundStyle(CommaTheme.textTertiary)
                answer
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12).padding(.leading, 12).padding(.trailing, 16)
        .background(CommaTheme.bgSecondary, in: shape)
        .overlay(shape.strokeBorder(CommaTheme.borderSecondary, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        let status = question.state.status
        return ZStack {
            Circle().fill(status == .answered ? CommaTheme.brandSolid : CommaTheme.bgTertiary)
            switch status {
            case .sending: ProgressView().controlSize(.mini)
            case .skipped: glyph("central-chevron-double-right")
            case .replied: glyph("central-chat-bubble-7")
            case .replaced: glyph("central-arrow-rotate-clockwise")
            default: CentralIcon("icon-check", size: 18).foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private func glyph(_ name: String) -> some View {
        CentralIcon(name, size: 14).foregroundStyle(CommaTheme.textTertiary)
    }

    @ViewBuilder private var answer: some View {
        switch question.state.status {
        case .answered, .sending:
            let given = Text(Self.given(question)).fontWeight(.medium).foregroundStyle(CommaTheme.textPrimary)
            if question.state.status == .sending {
                Text("\(given) · \(Text("Sending"))").font(.subheadline).foregroundStyle(CommaTheme.textTertiary)
            } else {
                given.font(.subheadline)
            }
        case .skipped: muted(Text("Skipped. The agent decides."))
        case .replied: muted(Text("Answered in the chat"))
        case .replaced: muted(Text("Replaced by a newer question"))
        case .open, .failed: EmptyView()
        }
    }

    private func muted(_ text: Text) -> some View {
        text.font(.subheadline).foregroundStyle(CommaTheme.textSecondary)
    }

    /// The picked choices' labels, in the card's order, then the other answer's words; images only read as such.
    static func given(_ question: ChatQuestion) -> String {
        let picked = question.choices.filter { question.state.choiceIDs.contains($0.id) }.map(\.label)
        let other = question.state.other?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = picked + (other.isEmpty ? [] : [other])
        return words.isEmpty ? String(localized: "Answered with images")
            : words.joined(separator: String(localized: ", ", comment: "Joins the answers a question card gave; Chinese uses 、"))
    }
}
