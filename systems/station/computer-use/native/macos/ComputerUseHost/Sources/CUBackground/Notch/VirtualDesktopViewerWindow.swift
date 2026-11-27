import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@available(macOS 14.0, *)
@MainActor
public final class VirtualDesktopViewerModel: ObservableObject {
    @Published public var title: String
    @Published public var subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// Interactive high-resolution viewer opened when the user clicks "Check computer ↗"
/// in the Notch Dynamic Island. Shows the full virtual desktop stream (including
/// the live AI cursor) and lets the user inspect or bring windows back to the main screen.
///
/// Uses a native `.unifiedCompact` dark toolbar (without `.fullSizeContentView` or
/// `.ignoresSafeArea()`) so the virtual desktop's own menu bar is never clipped underneath
/// the titlebar, the window title stays vertically centered with the traffic lights, and
/// the "Bring Windows Here" pill receives clicks natively across macOS 14–27.
@available(macOS 14.0, *)
@MainActor
public final class VirtualDesktopViewerController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private let stream: VirtualDesktopStream
    private let virtualDisplayID: CGDirectDisplayID?
    private let virtualDisplayBounds: CGRect
    private let model: VirtualDesktopViewerModel

    public var onBringWindowsBack: (() -> Void)?
    public var onClose: (() -> Void)?

    public static let headerHeight: CGFloat = 38

    private static let statusItemID = NSToolbarItem.Identifier("surf.comma.computer-use.viewer.status")
    private static let bringWindowsItemID = NSToolbarItem.Identifier("surf.comma.computer-use.viewer.bring-windows")

    public init(
        stream: VirtualDesktopStream,
        virtualDisplayID: CGDirectDisplayID? = nil,
        virtualDisplayBounds: CGRect,
        title: String,
        subtitle: String
    ) {
        self.stream = stream
        self.virtualDisplayID = virtualDisplayID
        self.virtualDisplayBounds = virtualDisplayBounds
        self.model = VirtualDesktopViewerModel(title: title, subtitle: subtitle)
        super.init()
    }

    private var displayAspect: CGFloat {
        virtualDisplayBounds.width > 0 && virtualDisplayBounds.height > 0
            ? virtualDisplayBounds.width / virtualDisplayBounds.height
            : 1440.0 / 900.0
    }

    public func show() {
        let hostScreen = NotchOverlayController.selectHostScreen(excluding: virtualDisplayID)
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = hostScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let aspect = displayAspect
        let toolbarHeight = Self.headerHeight
        // Keep clear of the expanded island hanging from the top edge.
        let notchClearance: CGFloat = 170
        let maxContentHeight = max(360, screenFrame.height - notchClearance - toolbarHeight - 24)
        let maxContentWidth = min(1040, screenFrame.width - 96)
        let contentWidth = round(min(maxContentWidth, maxContentHeight * aspect))
        let contentHeight = round(contentWidth / aspect)

        // Note: NO `.fullSizeContentView` — contentView starts strictly below the
        // `.unifiedCompact` toolbar hairline so the virtual desktop's menu bar is 100% unclipped.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.delegate = self

        let toolbar = NSToolbar(identifier: "surf.comma.computer-use.viewer.compact")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        // Set title after toolbar install; keep window.subtitle empty so macOS centers
        // the title vertically with the traffic lights (live status renders in statusItemID).
        window.title = model.title
        window.subtitle = ""

        let hosting = NSHostingView(rootView: VirtualDesktopViewerStreamView(stream: stream))
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        window.contentMinSize = NSSize(width: 560, height: round(560 / aspect))

        let frame = window.frame
        let origin = NSPoint(
            x: round(screenFrame.midX - frame.width / 2),
            y: round(screenFrame.minY + max(16, (screenFrame.height - notchClearance - frame.height) / 2))
        )
        window.setFrameOrigin(origin)
        // The notch panel never activates the app, so activate explicitly: the
        // user asked for this window and expects it focused, not dimmed behind.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    public func bringToFront() {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    public func updateSubtitle(_ text: String) {
        model.subtitle = text
    }

    public func updateTitle(_ text: String) {
        model.title = text
        window?.title = text
    }

    public func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        onClose?()
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }

    // MARK: - NSToolbarDelegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.statusItemID, .flexibleSpace, Self.bringWindowsItemID]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isBordered = false
        switch itemIdentifier {
        case Self.statusItemID:
            item.label = "Status"
            let statusHost = NSHostingView(rootView: VirtualDesktopViewerStatusBadge(model: model))
            statusHost.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            item.view = statusHost
        case Self.bringWindowsItemID:
            item.label = "Bring Windows Here"
            item.toolTip = "Move the agent's windows back to this screen"
            let btnHost = NSHostingView(
                rootView: VirtualDesktopBringWindowsPill(action: { [weak self] in
                    self?.onBringWindowsBack?()
                })
            )
            let fit = btnHost.fittingSize
            btnHost.frame = NSRect(origin: .zero, size: NSSize(width: ceil(fit.width), height: 26))
            item.view = btnHost
        default:
            return nil
        }
        return item
    }
}

/// Pure stream viewport placed strictly below the native `.unifiedCompact` toolbar.
@available(macOS 14.0, *)
private struct VirtualDesktopViewerStreamView: View {
    let stream: VirtualDesktopStream

    var body: some View {
        VirtualDesktopSurfaceView(stream: stream)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

/// Quiet live activity indicator & status text placed cleanly beside the window title.
@available(macOS 14.0, *)
public struct VirtualDesktopViewerStatusBadge: View {
    @ObservedObject public var model: VirtualDesktopViewerModel

    public init(model: VirtualDesktopViewerModel) {
        self.model = model
    }

    public var body: some View {
        let text = model.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        Group {
            if !text.isEmpty {
                HStack(alignment: .center, spacing: 6) {
                    NotchActivityRing()
                        .frame(width: 11, height: 11)
                    Text(text)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.56))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// High-contrast native-feeling capsule action button inside the dark compact toolbar.
@available(macOS 14.0, *)
public struct VirtualDesktopBringWindowsPill: View {
    public var action: () -> Void
    @State private var isHovering = false
    @State private var isPressing = false

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 5) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 11, weight: .medium))
                Text("Bring Windows Here")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.94))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isPressing ? 0.24 : (isHovering ? 0.17 : 0.11)))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(isHovering ? 0.22 : 0.14), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NotchPressStyle(isPressed: $isPressing))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
