import Foundation

/// One-line, human description of the action the agent is executing, for the
/// island's live status line (for example `Clicking “Run Preview” in Comma Studio`).
///
/// Built only from the command and the snapshot it acts on: the element's
/// accessibility title or role and the snapshot's app name. Typed text is shown
/// only when the target field is known and is not a secure (password) field.
public enum NotchActivityText {
    /// Snapshot facts used to name the target. Nil fields mean "unknown".
    public struct Target: Equatable, Sendable {
        public var appName: String?
        public var elements: [CachedNodeSignature]

        public init(appName: String?, elements: [CachedNodeSignature]) {
            self.appName = appName
            self.elements = elements
        }

        public init(metadata: ComputerUseSnapshotMetadata) {
            self.init(appName: metadata.appName, elements: metadata.nodeSignatures)
        }

        func element(_ index: Int?) -> CachedNodeSignature? {
            guard let index, elements.indices.contains(index) else { return nil }
            return elements[index]
        }
    }

    static let maxQuotedLength = 32
    static let maxTypedPreviewLength = 24

    /// The status line for `command`, or nil for commands that are not agent
    /// actions (permissions).
    public static func describe(_ command: ComputerUseCLICommand, target: Target?) -> String? {
        let suffix = target?.appName.flatMap(nonEmpty).map { " in \($0)" } ?? ""
        switch command {
        case .listApps:
            return "Checking open apps"
        case let .getAppState(app, _):
            return "Looking at \(target?.appName.flatMap(nonEmpty) ?? app)"
        case let .click(_, elementIndex, _, _):
            if let name = elementName(target?.element(elementIndex)) {
                return "Clicking \(name)\(suffix)"
            }
            return "Clicking\(suffix)"
        case let .typeText(_, text, elementIndex):
            guard let element = target?.element(elementIndex) else {
                return "Typing\(suffix)"
            }
            if isSecure(element) {
                return "Entering a password\(suffix)"
            }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "Typing\(suffix)"
            }
            return "Typing \(quoted(line, limit: maxTypedPreviewLength))\(suffix)"
        case let .setValue(_, elementIndex, _):
            let element = target?.element(elementIndex)
            if let element, isSecure(element) {
                return "Entering a password\(suffix)"
            }
            if let name = elementName(element) {
                return "Setting \(name)\(suffix)"
            }
            return "Setting a value\(suffix)"
        case let .pressKey(_, key):
            return "Pressing \(key)\(suffix)"
        case let .scroll(_, _, direction, _):
            return "Scrolling \(direction)\(suffix)"
        case let .performSecondaryAction(_, elementIndex, action):
            let verb = displayName(forAction: action)
            if let name = elementName(target?.element(elementIndex)) {
                return "\(verb) on \(name)\(suffix)"
            }
            return "\(verb)\(suffix)"
        case .drag:
            return "Dragging\(suffix)"
        case .permissions:
            return nil
        }
    }

    /// `“Title”` when the element has one, else its role (`button`).
    static func elementName(_ element: CachedNodeSignature?) -> String? {
        guard let element else { return nil }
        if let title = nonEmpty(element.title) {
            return quoted(title, limit: maxQuotedLength)
        }
        guard !element.role.isEmpty else { return nil }
        let role = describeRole(element.role)
        return role.isEmpty ? nil : "the \(role)"
    }

    static func isSecure(_ element: CachedNodeSignature) -> Bool {
        element.subrole == "AXSecureTextField"
    }

    static func quoted(_ text: String, limit: Int) -> String {
        let single = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let clipped = single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
        return "“\(clipped)”"
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
