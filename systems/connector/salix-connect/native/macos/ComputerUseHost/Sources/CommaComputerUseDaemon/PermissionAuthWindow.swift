import AppKit
import CUShared
import Combine
import PermissionFlow
import SwiftUI

/// Single-window unified authorization UX. Lists every required pane with
/// its current TCC status and an Allow button that opens the macOS settings
/// flow only when the user clicks. Polls TCC on a timer while visible so the
/// row flips to "Granted" automatically after macOS finishes registering the
/// drop in System Settings.
@MainActor
final class PermissionAuthWindowController {
    var onClose: (() -> Void)?
    private var windowController: NSWindowController?
    private let viewModel = PermissionAuthViewModel()
    private let flow: PermissionFlowController

    /// Snapshot of whatever application was frontmost when the user invoked
    /// `ComputerUse permissions` — typically the terminal they typed into.
    /// Captured before the daemon flips to `.regular` and steals focus so we
    /// can hand focus back on close, matching PermissionFlow's own
    /// `closePanel(returnToPreviousApp:)` behaviour for its floating panel.
    private var previousFrontmostPID: pid_t?
    private var previousFrontmostBundleID: String?

    init() {
        flow = PermissionFlow.makeController(
            configuration: .init(
                promptForAccessibilityTrust: false
            )
        )
    }

    func show() {
        viewModel.onRowsChanged = { [weak self] rows in
            self?.flow.guidanceSteps = rows.map { (pane: Self.translate($0.pane), granted: $0.granted) }
        }
        flow.guidanceSteps = viewModel.rows.map { (pane: Self.translate($0.pane), granted: $0.granted) }
        viewModel.onAuthorize = { [weak self] pane in
            guard let self else { return }
            flow.resetDroppedApps()
            flow.authorize(
                pane: Self.translate(pane),
                suggestedAppURLs: [permissionAuthorizationAppURL(for: pane, helperBundleURL: Bundle.main.bundleURL)]
            )
        }
        viewModel.onAllGranted = { [weak self] in
            self?.requestClose()
        }

        if let wc = windowController, let window = wc.window {
            viewModel.startPolling()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        rememberPreviousFrontmost()

        let rootView = PermissionAuthView(
            viewModel: viewModel,
            onGrant: { [weak self] pane in self?.grant(pane: pane) },
            onClose: { [weak self] in self?.requestClose() }
        )
        let host = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: host)
        window.title = "Comma Computer Use — Authorize"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PermissionAuthWindowPalette.backgroundNSColor(for: window.effectiveAppearance)
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = 16
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
        }
        window.center()
        windowDelegate.controller = self
        window.delegate = windowDelegate

        let wc = NSWindowController(window: window)
        windowController = wc

        // Accessory apps can't become .regular for a floating panel without
        // temporarily stealing focus; we switch back to .accessory when the
        // window closes so the daemon stays headless.
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        window.applyAuthorizationPanelBackground()
        DispatchQueue.main.async {
            window.applyAuthorizationPanelBackground()
        }
        viewModel.startPolling()
    }

    /// User-facing close trigger (the in-window Close button). Routes through
    /// AppKit so the window's `windowWillClose` delegate callback ends up
    /// being the single cleanup point for every close path (red traffic
    /// light, Close button, programmatic close) — avoiding re-entrance.
    private func requestClose() {
        windowController?.window?.performClose(nil)
    }

    /// Cleanup performed exactly once after the window has committed to
    /// closing. Called by the delegate's `windowWillClose`.
    fileprivate func didClose() {
        viewModel.stopPolling()
        windowController = nil

        // If the floating drag panel is still attached to System Settings
        // from an Allow click, tear it down too. We handle the focus
        // restoration ourselves below, so pass false.
        flow.closePanel(returnToPreviousApp: false)

        restorePreviousFrontmost()
        onClose?()

        // Defer the policy flip to the next runloop tick so AppKit finishes
        // tearing down the window on the current tick first.
        DispatchQueue.main.async {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    private func rememberPreviousFrontmost() {
        let selfBundleID = Bundle.main.bundleIdentifier
        guard
            let front = NSWorkspace.shared.frontmostApplication,
            front.bundleIdentifier != selfBundleID
        else {
            previousFrontmostPID = nil
            previousFrontmostBundleID = nil
            return
        }
        previousFrontmostPID = front.processIdentifier
        previousFrontmostBundleID = front.bundleIdentifier
    }

    private func restorePreviousFrontmost() {
        defer {
            previousFrontmostPID = nil
            previousFrontmostBundleID = nil
        }
        if
            let pid = previousFrontmostPID,
            let app = NSRunningApplication(processIdentifier: pid)
        {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        guard let bundleID = previousFrontmostBundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?
            .activate(options: [.activateIgnoringOtherApps])
    }

    private func grant(pane: PermissionPane) {
        viewModel.beginAuthorization(pane)
    }

    private lazy var windowDelegate = AuthWindowDelegate()

    private static func translate(_ pane: PermissionPane) -> PermissionFlowPane {
        switch pane {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        }
    }
}

// TCC attributes screen capture to the outer app when the helper is nested.
// Accessibility uses the helper's own bundle identity.
func permissionAuthorizationAppURL(for pane: PermissionPane, helperBundleURL: URL) -> URL {
    let helper = helperBundleURL.standardizedFileURL
    guard pane == .screenRecording else { return helper }

    var target = helper
    var ancestor = helper.deletingLastPathComponent()
    while ancestor.path != "/" {
        if ancestor.pathExtension.lowercased() == "app" {
            target = ancestor
        }
        ancestor.deleteLastPathComponent()
    }
    return target
}

private final class AuthWindowDelegate: NSObject, NSWindowDelegate {
    weak var controller: PermissionAuthWindowController?

    func windowWillClose(_: Notification) {
        controller?.didClose()
    }
}

private enum PermissionAuthWindowPalette {
    static func backgroundColor(for colorScheme: ColorScheme) -> Color {
        Color(nsColor: backgroundNSColor(isDark: colorScheme == .dark))
    }

    static func backgroundNSColor(for appearance: NSAppearance) -> NSColor {
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return backgroundNSColor(isDark: isDark)
    }

    private static func backgroundNSColor(isDark: Bool) -> NSColor {
        if isDark {
            return NSColor(deviceWhite: 40.0 / 255.0, alpha: 1)
        }
        return NSColor(deviceWhite: 242.0 / 255.0, alpha: 1)
    }
}

private extension NSWindow {
    func applyAuthorizationPanelBackground() {
        let backgroundColor = PermissionAuthWindowPalette.backgroundNSColor(for: effectiveAppearance)
        self.backgroundColor = backgroundColor

        applyAuthorizationBackground(to: contentView, backgroundColor: backgroundColor)
        applyAuthorizationBackground(to: contentView?.superview, backgroundColor: backgroundColor)

        var titlebarView = standardWindowButton(.closeButton)?.superview
        while let view = titlebarView {
            applyAuthorizationBackground(to: view, backgroundColor: backgroundColor)
            if view === contentView?.superview {
                break
            }
            titlebarView = view.superview
        }
    }

    private func applyAuthorizationBackground(to view: NSView?, backgroundColor: NSColor) {
        guard let view else { return }
        view.wantsLayer = true
        view.layer?.backgroundColor = backgroundColor.cgColor
    }
}

@MainActor
final class PermissionAuthViewModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let pane: PermissionPane
        let granted: Bool
        var id: PermissionPane {
            pane
        }
    }

    @Published var rows: [Row]
    private let permissionProbe: (PermissionPane) -> Bool
    private var activePane: PermissionPane?
    var onAuthorize: ((PermissionPane) -> Void)?
    var onRowsChanged: (([Row]) -> Void)?

    init(permissionProbe: @escaping (PermissionPane) -> Bool = { PermissionStatusProbe.check($0) }) {
        self.permissionProbe = permissionProbe
        rows = PermissionPane.allCases.map { Row(pane: $0, granted: permissionProbe($0)) }
    }

    func beginAuthorization(_ pane: PermissionPane) {
        activePane = pane
        onAuthorize?(pane)
    }

    var allGranted: Bool {
        rows.allSatisfy(\.granted)
    }

    var onAllGranted: (() -> Void)?

    private var timer: Timer?
    private var autoCloseTask: Task<Void, Never>?
    private var didScheduleAutoClose = false

    func startPolling() {
        refresh()
        timer?.invalidate()
        // 0.8s is fast enough that the row flips within one visual beat of
        // the System Settings toggle landing, without burning CPU on AX calls.
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        activePane = nil
        timer?.invalidate()
        timer = nil
        autoCloseTask?.cancel()
        autoCloseTask = nil
        didScheduleAutoClose = false
    }

    func refresh() {
        let next = PermissionPane.allCases.map {
            Row(pane: $0, granted: permissionProbe($0))
        }
        if next != rows {
            rows = next
            onRowsChanged?(next)
        }
        if let activePane, next.contains(where: { $0.pane == activePane && $0.granted }) {
            self.activePane = nil
            if let remaining = next.first(where: { !$0.granted }) {
                beginAuthorization(remaining.pane)
            }
        }
        scheduleAutoCloseIfNeeded()
    }

    private func scheduleAutoCloseIfNeeded() {
        guard allGranted else {
            autoCloseTask?.cancel()
            autoCloseTask = nil
            didScheduleAutoClose = false
            return
        }
        guard didScheduleAutoClose == false else { return }

        didScheduleAutoClose = true
        autoCloseTask = Task { @MainActor [weak self] in
            // Let the granted rows and success state render for one beat,
            // then close automatically so users do not need a final click.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, Task.isCancelled == false else { return }
            if allGranted {
                onAllGranted?()
            } else {
                didScheduleAutoClose = false
                autoCloseTask = nil
            }
        }
    }
}

struct PermissionAuthView: View {
    @ObservedObject var viewModel: PermissionAuthViewModel
    let onGrant: (PermissionPane) -> Void
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 18) {
            PermissionAuthIconView()
                .padding(.top, 10)

            VStack(spacing: 8) {
                Text(String(localized: "Enable Comma Computer Use"))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(String(localized: "Comma Computer Use needs these permissions to use apps on your Mac.\nThese permissions are only used when you ask Comma to perform tasks."))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }

            VStack(spacing: 10) {
                ForEach(viewModel.rows) { row in
                    PermissionRowView(row: row) {
                        onGrant(row.pane)
                    }
                }
            }
            if viewModel.allGranted {
                Label("Permissions enabled", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .onExitCommand(perform: onClose)
        .padding(.top, 30)
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .frame(width: 540)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(windowBackgroundColor)
                .shadow(color: .black.opacity(0.16), radius: 28, x: 0, y: 16)
        )
    }

    private var windowBackgroundColor: Color {
        PermissionAuthWindowPalette.backgroundColor(for: colorScheme)
    }
}

private struct PermissionAuthIconView: View {
    private var panelLogo: NSImage {
        if let url = Bundle.commaResources.url(forResource: "panel-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    var body: some View {
        Image(nsImage: panelLogo)
            .resizable()
            .interpolation(.high)
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
    }
}

struct PermissionRowView: View {
    let row: PermissionAuthViewModel.Row
    let onGrant: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PermissionPaneIconView(pane: row.pane, granted: row.granted)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.pane.authorizationDisplayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(row.pane.authorizationPurpose)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.granted {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityLabel(String(localized: "Granted"))
            } else {
                Button("Allow", action: onGrant)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
        }
        .padding(.vertical, 13)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(cardBackgroundColor)
                .shadow(color: cardShadowColor, radius: 12, x: 0, y: 7)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(cardBorderColor, lineWidth: 1)
        )
    }

    private var cardBackgroundColor: Color {
        colorScheme == .dark ? .white.opacity(0.085) : .white.opacity(0.94)
    }

    private var cardBorderColor: Color {
        colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.08)
    }

    private var cardShadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.2) : .black.opacity(0.08)
    }
}

private extension PermissionPane {
    var authorizationDisplayName: String {
        switch self {
        case .accessibility:
            String(localized: "Accessibility")
        case .screenRecording:
            String(localized: "Screenshots")
        }
    }

    var authorizationPurpose: String {
        switch self {
        case .accessibility:
            String(localized: "Allows Comma to access app interfaces")
        case .screenRecording:
            String(localized: "Comma uses screenshots to know where to click")
        }
    }
}

private struct PermissionPaneIconView: View {
    let pane: PermissionPane
    let granted: Bool

    var body: some View {
        Image(nsImage: PermissionPaneIconAsset.image(for: pane))
            .resizable()
            .interpolation(.high)
            .opacity(granted ? 0.78 : 1)
            .frame(width: 40, height: 40)
    }
}

private enum PermissionPaneIconAsset {
    static func image(for pane: PermissionPane) -> NSImage {
        switch pane {
        case .accessibility:
            load("authorize-accessibility", fallbackSystemName: "figure.arms.open")
        case .screenRecording:
            load("authorize-screen-recording", fallbackSystemName: "camera.viewfinder")
        }
    }

    private static func load(_ name: String, fallbackSystemName: String) -> NSImage {
        if let url = Bundle.commaResources.url(forResource: name, withExtension: "svg"),
           let image = NSImage(contentsOf: url)
        {
            image.size = NSSize(width: 40, height: 40)
            return image
        }

        return NSImage(systemSymbolName: fallbackSystemName, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 40, height: 40))
    }
}
