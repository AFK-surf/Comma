import SwiftUI
import UIKit
import CommaCore

/// Replying to a message, as Messages does: a long press or a swipe to the right opens the message's thread, whose
/// messages leave their places in the transcript and gather above the composer over a blurred transcript. Sends go
/// into that thread until a tap on the space above it closes it and the messages fly back.
extension ChatTranscriptView {
    /// Only a committed message has an id the server accepts as a reply target.
    func canReply(_ row: ChatRow) -> Bool { row.message != nil && pane.target != nil && !pane.closed }

    func inOpenThread(_ row: ChatRow) -> Bool { replyThread.map { row.threadRoot == $0.rootID } ?? false }

    func openThread(_ row: ChatRow) {
        guard let message = row.message else { return }
        replyFrames.opening = replyFrames.current
        withAnimation(CommaMotion.replyThread(reduced: reduceMotion)) { pane.openReplyThread(on: message) }
        onReplyOpened()
    }

    func closeThread() {
        withAnimation(CommaMotion.replyThread(reduced: reduceMotion)) { pane.closeReplyThread() }
    }

    /// The swipe on a row's bubbles; off while a thread is open, whose copies are already gathered.
    func swipeToReply(_ row: ChatRow) -> ReplySwipe {
        ReplySwipe(id: row.id, pane: ObjectIdentifier(pane), enabled: replyThread == nil && canReply(row)) {
            openThread(row)
        }
    }

    /// The long-press menu on a bubble.
    @ViewBuilder func messageMenu(_ row: ChatRow) -> some View {
        if canReply(row) {
            Button { openThread(row) } label: {
                Label { Text("Reply") } icon: { Image(decorative: "central-arrow-share-left") }
            }
        }
        if !row.text.isEmpty {
            Button { UIPasteboard.general.string = row.text } label: {
                Label { Text("Copy") } icon: { Image(decorative: "central-square-behind-square-6") }
            }
        }
    }

    /// The open thread: its rows, related among themselves, gathered at the bottom over a material backdrop. Each
    /// row flies from its transcript position without moving the transcript's hidden placeholder.
    func threadLayer(_ thread: ReplyThreadSelection) -> some View {
        let members: [ChatRow] = ChatTranscriptModel.thread(rows, root: thread.rootID)
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    threadStack(members, proxy: proxy)
                        .padding(.horizontal, 16).padding(.top, 16)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .bottom)
                        // The scroll view takes every touch over it, so the space around the bubbles closes the
                        // thread from here; a bubble's own content stays in front of it.
                        .background {
                            Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeThread)
                        }
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .environment(\.assistantBubbleFill, CommaTheme.bubbleAssistantOverBlur)
        .background { threadBackdrop }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reply thread")
        .accessibilityIdentifier("replyThread")
        .accessibilityAction(.escape, closeThread)
    }

    /// Blurs the transcript behind the thread; a tap where the thread does not cover it closes the thread.
    private var threadBackdrop: some View {
        Rectangle().fill(.regularMaterial)
            .ignoresSafeArea()
            .onTapGesture(perform: closeThread)
            .accessibilityLabel("Close reply thread")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { closeThread() }
    }

    private func threadStack(_ members: [ChatRow], proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, row in
                threadRow(row, after: index == 0 ? nil : members[index - 1], proxy: proxy)
            }
            Color.clear.frame(height: 12)
        }
    }

    var replyLayerTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: ReplyFlightTransition(progress: 0, opening: true),
                                 identity: ReplyFlightTransition(progress: 1, opening: true)),
            removal: .modifier(active: ReplyFlightTransition(progress: 0, opening: false),
                               identity: ReplyFlightTransition(progress: 1, opening: false)))
            .combined(with: .opacity)
    }

    private func threadRow(_ row: ChatRow, after previous: ChatRow?, proxy: ScrollViewProxy) -> some View {
        rowView(row, proxy: proxy)
            .modifier(ReplyBubbleFlight(frames: replyFrames, id: row.id))
            .transition(replyFrames.opening[row.id] == nil ? transition(for: row) : .identity)
            .padding(.top, previous.map { spacing(before: row, after: $0) } ?? 0)
    }
}

/// Geometry reports keep only mounted transcript rows; changing them does not invalidate the transcript.
@MainActor final class ReplyFlightFrames {
    var current: [String: CGRect] = [:]
    var opening: [String: CGRect] = [:]
}

/// Animate a visual offset only. Shared geometry across the transcript and reply containers can retarget
/// the flight while the keyboard is up, taking a bubble past its destination before pulling it back.
private struct ReplyBubbleFlight: ViewModifier {
    let frames: ReplyFlightFrames
    let id: String
    @Environment(\.replyFlightPhase) private var phase

    func body(content: Content) -> some View {
        let source = (phase.opening ? frames.opening : frames.current)[id]
        let progress = phase.progress
        content.visualEffect { effect, geometry in
            let target = geometry.frame(in: .global)
            return effect
                .offset(x: ((source?.midX ?? target.midX) - target.midX) * (1 - progress),
                        y: ((source?.midY ?? target.midY) - target.midY) * (1 - progress))
                .opacity(source == nil ? Double(progress) : 1)
        }
    }
}

private struct ReplyFlightPhase {
    var progress: CGFloat = 1
    var opening = true
}

private extension EnvironmentValues {
    @Entry var replyFlightPhase = ReplyFlightPhase()
}

/// The container owns the transition, so all rows fly back when the whole thread closes, including new replies.
private struct ReplyFlightTransition: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    let opening: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View {
        content.environment(\.replyFlightPhase, ReplyFlightPhase(progress: progress, opening: opening))
    }
}
