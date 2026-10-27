// QuickChatHost: Comma's Quick Chat on macOS.
//
// A double tap of ⌘ (or the modifier the person chose) anywhere, the global shortcut Main holds instead, or the
// menu-bar menu's Quick Chat row shows NameDrop's connection hint above the Dock and sends the microphone to the
// server's live dictation; the words can be edited, and a tap of the modifier then listens again. Return or the send button sends the words
// away and Main creates a Task for the Worker from them.
//
// Protocol (one JSON object per line):
//   stdin  ← {"type":"configure","strings":{…},"tap"}    interface text, Comma's language; the tapped modifier or null
//            {"type":"result","requestId","ok","message"?} the Task for a submit
//            {"type":"transcript","clipId","text"?}       the server's words for a transcribe
//            {"type":"dictationTicket","requestId","url"?,"ticket"?}  live dictation's socket, if any
//            {"type":"listen"}                            the menu-bar row or the global shortcut: as a double tap
//   stdout → {"type":"ready"}
//            {"type":"submit","requestId","text","draft","audio"?}
//            {"type":"transcribe","clipId","audio"}       audio between two pauses, without live dictation
//            {"type":"dictationTicket","requestId"}       asks for live dictation's socket
// stdin EOF quits.
//
// `--preview [text]` plays one Quick Chat with `text` typed in place of speech,
// then sends it, for reviewing the motion without Main or a microphone.

import AppKit
import Foundation
import QuickChatCore

func write(_ event: HostEvent) {
    guard let data = try? JSONEncoder().encode(event), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

let arguments = CommandLine.arguments
let previewText: String? = arguments.firstIndex(of: "--preview").map { index in
    index + 1 < arguments.count ? arguments[index + 1] : "帮我把今天下午的设计评审整理成一份任务清单，标出负责人和截止时间，然后发到团队频道。"
}

NSApplication.shared.setActivationPolicy(.accessory)

let transcripts = ServerTranscripts(emit: write)
let tickets = DictationTickets(emit: write)
let controller = QuickChatController(
    takesKeyboard: previewText == nil, emit: write, transcripts: transcripts, tickets: tickets
) { draft in
    if let previewText { return PreviewTranscript(text: previewText) }
    return LiveDictation(draft: draft, ticket: tickets.ticket, transcribe: transcripts.transcribe)
}
let monitor = ModifierTapMonitor()
controller.onTapModifier = { monitor.modifier = $0 }
monitor.onTap = { controller.resume() }
monitor.onDoubleTap = { controller.summon() }
monitor.start()

if previewText != nil {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { controller.present() }
    NotificationCenter.default.addObserver(forName: .previewSend, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
            controller.send()
            DispatchQueue.main.asyncAfter(deadline: .now() + NameDropEffect.sendDuration + 0.5) { exit(0) }
        }
    }
} else {
    DispatchQueue.global(qos: .userInitiated).async {
        while let line = readLine() {
            guard let data = line.data(using: .utf8) else { continue }
            do {
                let command = try JSONDecoder().decode(HostCommand.self, from: data)
                Task { @MainActor in controller.handle(command) }
            } catch {
                FileHandle.standardError.write(Data("QuickChatHost ignored a command: \(error)\n".utf8))
            }
        }
        Task { @MainActor in NSApplication.shared.terminate(nil) }
    }
}

write(.ready)
NSApplication.shared.run()

/// `--preview`'s words: typed out like volatile results, a few characters at
/// a time, then sent with Return as a person would.
@MainActor
final class PreviewTranscript: TranscriptSource {
    var onText: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onFailure: ((SpeechFailure) -> Void)?
    private(set) var text = ""
    let draft = ""
    let audio: Data? = nil
    private let script: [Character]
    private var timer: Timer?

    init(text: String) {
        script = Array(text)
    }

    func start() {
        var shown = 0
        var tick = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                tick += 1
                self.onLevel?(shown < self.script.count ? 0.35 + 0.35 * abs(sin(Double(tick) * 0.45)) : 0)
                // Speech starts after a beat and arrives in short bursts.
                guard tick > 18, tick % 4 == 0 else { return }
                guard shown < self.script.count else {
                    if tick > 18 + self.script.count + 40 {
                        self.timer?.invalidate()
                        NotificationCenter.default.post(name: .previewSend, object: nil)
                    }
                    return
                }
                shown = min(self.script.count, shown + Int.random(in: 1...3))
                self.text = String(self.script[..<shown])
                self.onText?(self.text)
            }
        }
    }

    func stop() {
        timer?.invalidate()
    }

    func finish() async -> String {
        stop()
        return text
    }

    func serverWords(waitForSlot: Bool) async -> String? {
        nil
    }
}

extension Notification.Name {
    static let previewSend = Notification.Name("QuickChatPreviewSend")
}
