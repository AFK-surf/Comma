import AppKit
import Foundation

@MainActor
final class AgentHUDController: OverlayWindowSource {
    private enum Mode {
        case hidden
        case agentOperating(text: String)
        case observeSummary(text: String)
        case observing(text: String)
    }

    private let window = AgentHUDWindow()
    private var mode: Mode = .hidden

    private var overlayWindow: NSWindow? {
        window.overlayWindow
    }

    var overlayWindows: [NSWindow] {
        overlayWindow.map { [$0] } ?? []
    }

    private let defaultAgentOperatingText = "Agent is operating..."
    private let defaultObserveSummaryText = "Putting together a quick summary..."
    private let defaultObservationText = "Observing your actions..."
    private var agentOperatingText: String
    private var temporaryAgentOperatingText: String?

    init() {
        agentOperatingText = defaultAgentOperatingText
        OverlayWindowRegistry.shared.register(self)
    }

    func resetAgentOperating() {
        agentOperatingText = defaultAgentOperatingText
        temporaryAgentOperatingText = nil
        showCurrentAgentOperating()
    }

    func showCurrentAgentOperating() {
        let displayText = temporaryAgentOperatingText ?? agentOperatingText
        mode = .agentOperating(text: displayText)
        window.show(text: displayText, style: .agentOperating)
    }

    func startObserveSummary(text: String? = nil) {
        agentOperatingText = defaultAgentOperatingText
        temporaryAgentOperatingText = nil

        let summaryText = normalizedObserveSummaryText(text)
        mode = .observeSummary(text: summaryText)
        window.show(text: summaryText, style: .agentOperating)
    }

    @discardableResult
    func updateAgentOperatingText(_ text: String) -> Bool {
        let resolvedText = normalizedAgentOperatingText(text)

        switch mode {
        case .observing:
            return false
        case .observeSummary:
            return false
        case .hidden:
            agentOperatingText = resolvedText
            return false
        case .agentOperating:
            agentOperatingText = resolvedText
            if temporaryAgentOperatingText == nil {
                showCurrentAgentOperating()
            }
            return true
        }
    }

    @discardableResult
    func beginTemporaryAgentOperatingText(_ text: String) -> Bool {
        guard case .agentOperating = mode else {
            return false
        }

        temporaryAgentOperatingText = normalizedAgentOperatingText(text)
        showCurrentAgentOperating()
        return true
    }

    func endTemporaryAgentOperatingText() {
        guard temporaryAgentOperatingText != nil else { return }
        temporaryAgentOperatingText = nil

        guard case .agentOperating = mode else { return }
        showCurrentAgentOperating()
    }

    func startObserving(initialText: String? = nil, anchoredAt point: CGPoint? = nil) {
        let text = initialText ?? defaultObservationText
        mode = .observing(text: text)
        window.show(text: text, anchoredAt: point, style: .observing)
    }

    func updateObservation(_ text: String) {
        switch mode {
        case .observing:
            mode = .observing(text: text)
            window.updateText(text)
        case .hidden, .agentOperating, .observeSummary:
            startObserving(initialText: text)
        }
    }

    func resumeAgentOperating() {
        guard case .observing = mode else {
            showCurrentAgentOperating()
            return
        }

        showCurrentAgentOperating()
    }

    func hide() {
        mode = .hidden
        temporaryAgentOperatingText = nil
        window.hide()
    }

    /// Synchronous reposition — see `AgentHUDWindow.nudge()`.
    func nudge() {
        window.nudge()
    }

    private func normalizedAgentOperatingText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultAgentOperatingText : text
    }

    private func normalizedObserveSummaryText(_ text: String?) -> String {
        guard let text else { return defaultObserveSummaryText }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultObserveSummaryText : text
    }
}
