import AppKit
import QuartzCore
import QuickChatCore

/// One Quick Chat at a time: a double tap of ⌘ shows the NameDrop hint above
/// the Dock and listens; the words appear as they are said. Clicking them or
/// typing stops listening and opens them for editing; a tap of ⌘ then
/// listens again after them. Return or the send button sends them away
/// with the shockwave and asks Main to send a Message. The close button drops the
/// words. Esc or a click elsewhere closes it too, and the next Quick Chat
/// continues them; so does `silenceLimit` without new words while it
/// listens, so a double tap of ⌘ by mistake never leaves the microphone on. Words
/// taller than their box scroll under the pointer.
@MainActor
final class QuickChatController {
    private enum Phase {
        case idle
        case listening
        /// The microphone is off and the words are text to edit.
        case editing
        /// The shockwave and the text leaving, or the hint falling back.
        case leaving
    }

    private let emit: (HostEvent) -> Void
    private let transcripts: ServerTranscripts
    private let submissions: QuickChatSubmission
    private let makeSource: (_ draft: String) -> TranscriptSource
    /// False for `--preview`, which must not take the keyboard from the person at the Mac.
    private let takesKeyboard: Bool
    private let effectPanel = EffectPanel()
    private let keyPanel = KeyPanel()
    private let effect = NameDropEffect()
    private let transcript = TranscriptLayer()
    private let editor = TranscriptEditor()
    private let tip = ResumeTip()
    private let controls = QuickChatControls()
    private var phase = Phase.idle
    private var strings = QuickChatStrings.english
    private var source: TranscriptSource?
    private var editingSource: TranscriptSource?
    /// The words finishing as editing starts, until the editor opens with them.
    private var finishing: Task<String, Never>?
    /// The click and keys from then, for the editor once it opens; a click
    /// with its point in the text area.
    private var editInputs: [(event: NSEvent, point: CGPoint)] = []
    /// The send button was pressed while the words finished.
    private var sendWhenOpen = false
    /// When editing started, and the tip due half a second later.
    private var editStarted: CFTimeInterval = 0
    private var tipTimer: DispatchWorkItem?
    /// The text area, in the overlay's coordinates, and the overlay's screen origin.
    private var textFrame = CGRect.zero
    private var screenOrigin = CGPoint.zero
    private var level: CGFloat = 0
    private var hide: DispatchWorkItem?
    /// Closes a Quick Chat that heard no new words for `silenceLimit`.
    private var silence: DispatchWorkItem?
    static let silenceLimit: TimeInterval = 30
    /// The Messages Main is sending, and the words of Quick Chats closed without sending.
    private var sends = QuickChatSends()
    /// The send the overlay shows leaving, until another Quick Chat starts.
    private var leavingSend: String?

    init(
        takesKeyboard: Bool = true,
        emit: @escaping (HostEvent) -> Void,
        transcripts: ServerTranscripts,
        makeSource: @escaping (_ draft: String) -> TranscriptSource
    ) {
        self.takesKeyboard = takesKeyboard
        self.emit = emit
        self.transcripts = transcripts
        submissions = QuickChatSubmission(emit: emit)
        self.makeSource = makeSource
        let root = effectPanel.contentView!.layer!
        root.addSublayer(effect.layer)
        root.addSublayer(transcript.layer)
        root.addSublayer(tip.layer)
        keyPanel.contentView!.addSubview(editor.view)
        controls.onClose = { [weak self] in self?.close() }
        controls.onSend = { [weak self] in self?.send() }
        keyPanel.onKeyDown = { [weak self] event in self?.key(event) }
        keyPanel.onCancel = { [weak self] in self?.cancel() }
        keyPanel.onClick = { [weak self] event, point in self?.edit(with: event, at: point) }
        keyPanel.onScroll = { [weak self] event in
            guard let self, phase == .listening else { return }
            transcript.scroll(with: event)
            placeKeyPanel()
        }
        keyPanel.onKeyEquivalent = { [weak self] event in
            guard let self else { return false }
            // While the words finish, shortcuts wait for the editor like keys.
            if finishing != nil {
                editInputs.append((event, .zero))
                return true
            }
            return editor.performKeyEquivalent(event)
        }
        keyPanel.onResign = { [weak self] in self?.cancel() }
        editor.onCommand = { [weak self] command in
            switch command {
            case .send: self?.send()
            case .cancel: self?.cancel()
            }
        }
        editor.onChange = { [weak self] in
            guard let self else { return }
            controls.setCanSend(!Self.trimmed(editor.text).isEmpty)
            placeKeyPanel()
            // The tip stays above the words as they change.
            if tip.isShown { showTip(strings.resume) }
        }
    }

    func handle(_ command: HostCommand) {
        switch command {
        case let .configure(strings):
            self.strings = strings
            controls.configure(close: strings.close, send: strings.send)
        case let .result(requestId, ok, _):
            submissions.cancel(requestId: requestId)
            // A failed send waits in the Notch, where a click sends it again;
            // only the overlay still showing this send says that it failed.
            guard sends.result(requestId: requestId, ok: ok),
                  phase == .leaving, leavingSend == requestId, effectPanel.isVisible else { return }
            transcript.reset(placeholder: strings.sendFailed, style: .message)
            scheduleHide(after: 3)
        case let .transcript(clipId, text):
            transcripts.receive(clipId: clipId, text: text)
        case .listen:
            summon()
        }
    }

    /// A double tap of ⌘, or a click on the menu-bar item: Quick Chat opens, or
    /// listens again after edited words; it keeps listening when it already does.
    func summon() {
        switch phase {
        case .idle, .leaving: present()
        case .listening: break
        case .editing: resume()
        }
    }

    func present() {
        hide?.cancel()
        leavingSend = nil
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main!
        let geometry = Geometry(screen: screen)
        textFrame = geometry.text
        screenOrigin = screen.frame.origin
        editor.width = geometry.text.width
        effectPanel.setFrame(screen.frame, display: false)
        effect.layout(overlay: CGRect(origin: .zero, size: screen.frame.size), stageWidth: geometry.stageWidth)
        transcript.layout(frame: geometry.text)
        effectPanel.orderFrontRegardless()
        if takesKeyboard { keyPanel.makeKeyAndOrderFront(nil) }
        effect.present()
        controls.show(
            at: CGPoint(x: screen.frame.minX + geometry.controls.x, y: screen.frame.minY + geometry.controls.y),
            canSend: false
        )
        listen(after: sends.takeDraft())
    }

    /// Starts the microphone; the words continue `draft`.
    private func listen(after draft: String) {
        phase = .listening
        level = 0
        transcript.layer.isHidden = false
        transcript.reset(placeholder: strings.listening, style: .waiting)
        let source = makeSource(draft)
        source.onText = { [weak self] text in
            self?.show(text)
            self?.armSilence()
        }
        source.onLevel = { [weak self] loudness in self?.setLevel(loudness) }
        // What is happening, or what went wrong, shows where the words will be,
        // or above them once there are words.
        source.onPreparing = { [weak self, weak source] preparing in
            guard let self, let source else { return }
            if !source.text.isEmpty {
                preparing ? showTip(strings.preparing) : hideTip()
            } else {
                transcript.setPlaceholder(preparing ? strings.preparing : strings.listening, style: .waiting)
            }
        }
        source.onFailure = { [weak self, weak source] failure in
            guard let self, let source else { return }
            let message = failure == .microphoneDenied ? strings.microphoneDenied : strings.speechUnavailable
            if !source.text.isEmpty {
                showTip(message)
            } else {
                transcript.setPlaceholder(message, style: .hint)
            }
        }
        self.source = source
        // The draft was on screen already: it shows at once.
        show(source.text, revealed: true)
        armSilence()
        source.start()
    }

    /// Starts the wait for words over: without any for `silenceLimit`, Quick
    /// Chat closes as Esc does, keeping its words for the next one.
    private func armSilence() {
        silence?.cancel()
        guard phase == .listening else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, phase == .listening else { return }
            cancel()
        }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.silenceLimit, execute: work)
    }

    private func show(_ text: String, revealed: Bool = false) {
        guard phase == .listening else { return }
        transcript.setText(text, revealed: revealed)
        controls.setCanSend(!text.isEmpty)
        placeKeyPanel()
    }

    /// A key while no text view has the keyboard. While the words finish,
    /// keys wait for the editor, Return and Esc too, so they apply in order.
    private func key(_ event: NSEvent) {
        if finishing != nil {
            editInputs.append((event, .zero))
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76:
            // Return or the keypad's Enter.
            if modifiers.isEmpty { send() }
        case 53:
            cancel()
        case 48:
            // Tab types nothing here.
            break
        default:
            if modifiers.isDisjoint(with: [.command, .control]) { edit(with: event, at: .zero) }
        }
    }

    /// A click on the words or a key while listening: the words finish, about
    /// 0.1 s, and open for editing, with the click or keys applied.
    private func edit(with event: NSEvent, at point: CGPoint) {
        switch phase {
        case .listening:
            guard let source else { return }
            self.source = nil
            editingSource = source
            phase = .editing
            effect.setVoiceLevel(0)
            editInputs = [(event, point)]
            sendWhenOpen = false
            editStarted = CACurrentMediaTime()
            placeKeyPanel()
            let scrolledBack = transcript.scrolledBack
            finishing = Task {
                let text = await source.finish()
                guard editingSource === source else { return text }
                openEditor(text, scrolledBack: scrolledBack)
                Task {
                    guard editingSource === source else { return }
                    if let words = await source.serverWords(waitForSlot: false), editingSource === source {
                        serverWordsCame(words, replacing: text)
                    }
                }
                return text
            }
        case .editing where finishing != nil:
            editInputs.append((event, point))
        default:
            break
        }
    }

    private func openEditor(_ text: String, scrolledBack: CGFloat) {
        guard phase == .editing, finishing != nil else { return }
        finishing = nil
        // The editor sets the words where they are drawn; the drawn ones go
        // once it is on screen, so the words never blink between the windows.
        editor.open(text, scrolledBack: scrolledBack)
        placeKeyPanel()
        keyPanel.displayIfNeeded()
        DispatchQueue.main.async { [self] in
            if phase == .editing, editor.isOpen { transcript.layer.isHidden = true }
        }
        let inputs = editInputs
        editInputs = []
        // A replayed Return or Esc may send or close Quick Chat; nothing after it applies.
        for input in inputs where phase == .editing { editor.replay(input.event, at: input.point) }
        guard phase == .editing else { return }
        controls.setCanSend(!Self.trimmed(editor.text).isEmpty)
        scheduleResumeTip()
        if sendWhenOpen { send() }
    }

    /// The server's words for what was said, after the editor opened with
    /// others: they take their place while nothing was typed there.
    private func serverWordsCame(_ words: String, replacing opened: String) {
        guard phase == .editing, editor.isOpen, editor.text == opened, !editor.isComposing else { return }
        editor.replace(with: words)
        controls.setCanSend(!Self.trimmed(editor.text).isEmpty)
        placeKeyPanel()
        if tip.isShown { showTip(strings.resume) }
    }

    /// Half a second after editing starts, the tip says how to listen again:
    /// soon enough to find, late enough not to flash at a quick fix.
    private func scheduleResumeTip() {
        tipTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, phase == .editing, editor.isOpen else { return }
            showTip(strings.resume)
        }
        tipTimer = work
        let wait = max(0, 0.5 - (CACurrentMediaTime() - editStarted))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Above the words: tap ⌘ to listen again, or what keeps Quick Chat from listening.
    private func showTip(_ text: String) {
        let top = editor.isOpen ? editor.view.frame.maxY : transcript.wordsRect?.maxY ?? TranscriptLayer.boxHeight
        tip.show(text, at: CGPoint(x: textFrame.midX, y: textFrame.minY + top + 8), scale: effectPanel.backingScaleFactor)
    }

    private func hideTip() {
        tipTimer?.cancel()
        tip.hide()
    }

    /// Lays the key panel over the words, the halo's width around them: a
    /// click there edits, one beside them reaches the app below and closes
    /// Quick Chat. From the moment editing starts until the editor closes it
    /// spans the whole text area and stays put, so the window never moves
    /// under shown text. With no words it takes no clicks. Its content view
    /// keeps the text area's coordinates.
    private func placeKeyPanel() {
        let editing = phase == .editing || editor.isOpen
        let words = editing ? CGRect(origin: .zero, size: textFrame.size) : transcript.wordsRect
        guard let words else {
            keyPanel.ignoresMouseEvents = true
            return
        }
        let rect = words.insetBy(dx: -12, dy: -12).integral
        let frame = rect.offsetBy(dx: screenOrigin.x + textFrame.minX, dy: screenOrigin.y + textFrame.minY)
        if keyPanel.frame != frame {
            keyPanel.setFrame(frame, display: false)
            keyPanel.contentView?.setBoundsOrigin(rect.origin)
        }
        keyPanel.ignoresMouseEvents = false
    }

    /// A tap of ⌘ while editing: listening resumes after the edited words.
    /// They are drawn at once over the editor, which goes once they are on screen.
    func resume() {
        guard phase == .editing, editor.isOpen else { return }
        let text = editor.text
        editingSource?.stop()
        editingSource = nil
        hideTip()
        listen(after: text)
        DispatchQueue.main.async { [self] in
            guard phase == .listening else { return }
            editor.close()
            placeKeyPanel()
        }
    }

    private func closeEditor() {
        editingSource?.stop()
        editingSource = nil
        editor.close()
        hideTip()
    }

    /// Return shows the pending send at once. Its remaining clips finish before Message submission.
    func send() {
        let request = UUID().uuidString.lowercased()
        let submit: () -> Void
        switch phase {
        case .listening:
            guard let source, !source.text.isEmpty else { return }
            submit = { self.submissions.send(requestId: request, source: source) }
        case .editing:
            // The send button while the words finish: send what the editor opens with.
            guard finishing == nil else {
                sendWhenOpen = true
                return
            }
            let text = Self.trimmed(editor.text)
            guard !text.isEmpty else { return }
            // The edited words leave as the drawn ones do, from where the editor was scrolled.
            transcript.setText(text)
            transcript.scroll(back: editor.scrolledBack)
            submit = { self.emit(.submit(requestId: request, text: text, draft: "", audio: nil)) }
        default:
            return
        }
        end()
        leavingSend = request
        effect.send()
        transcript.layer.isHidden = false
        transcript.send(distance: effectPanel.frame.height * 0.3)
        scheduleHide(after: NameDropEffect.sendDuration)
        sends.send(requestId: request)
        submit()
    }

    /// The close button: the words are dropped.
    func close() {
        leave(keepingWords: false)
    }

    /// Esc or a click elsewhere, which can happen by accident: the words wait
    /// for the next Quick Chat, finished like a send.
    func cancel() {
        leave(keepingWords: true)
    }

    private func leave(keepingWords: Bool) {
        let words: (() async -> String)?
        switch phase {
        case .listening:
            guard let source else { return }
            words = source.text.isEmpty ? nil : {
                let text = await source.finish()
                source.stop()
                return text
            }
            if !keepingWords || words == nil { source.stop() }
        case .editing:
            if let finishing {
                words = { await finishing.value }
            } else {
                let text = editor.text
                words = { text }
            }
        default:
            return
        }
        end()
        effect.cancel()
        transcript.cancel()
        scheduleHide(after: NameDropEffect.cancelDuration)
        guard keepingWords, let words else { return }
        Task { sends.keep(await words()) }
    }

    private func end() {
        silence?.cancel()
        silence = nil
        source = nil
        finishing = nil
        editInputs = []
        sendWhenOpen = false
        phase = .leaving
        closeEditor()
        controls.hide()
        // The keyboard and the pointer return to the app in front while the overlay finishes.
        keyPanel.orderOut(nil)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, phase == .leaving else { return }
            effectPanel.orderOut(nil)
            phase = .idle
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Rises quickly with the voice and falls back slowly.
    private func setLevel(_ loudness: CGFloat) {
        guard phase == .listening else { return }
        level += (loudness - level) * (loudness > level ? 0.5 : 0.12)
        effect.setVoiceLevel(level)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where Quick Chat sits on a screen, in the overlay's coordinates (y up):
/// the effect over the bottom of the screen, its glows centered on the Dock,
/// the text above the Dock and the buttons between them. `text` reaches as
/// high as the words can grow; their box is at its bottom.
private struct Geometry {
    /// How wide NameDrop's phone canvas is drawn around the Dock. At its
    /// proportions the effect then rises to about a third of the screen.
    var stageWidth: CGFloat
    var text: CGRect
    /// The center of the close and send buttons.
    var controls: CGPoint

    init(screen: NSScreen) {
        let frame = screen.frame
        // The Dock's height when it is at the bottom; zero when it hides or sits at a side.
        let dock = max(screen.visibleFrame.minY - frame.minY, 0)
        stageWidth = min(frame.width, 500, frame.height * 0.38)
        let textWidth = min(max(stageWidth - 60, 360), 480, frame.width - 40)
        text = CGRect(
            x: ((frame.width - textWidth) / 2).rounded(),
            y: (dock + 58).rounded(),
            width: textWidth.rounded(),
            height: TranscriptLayer.maximumHeight
        )
        controls = CGPoint(x: frame.width / 2, y: (dock + 30).rounded())
    }
}
