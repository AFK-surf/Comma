import AppKit
import ApplicationServices
import CoreGraphics
import CUShared
import Foundation
import ObjectiveC
import OSLog

private let virtualDesktopLogger = Logger(
    subsystem: "surf.comma.CommaComputerUse",
    category: "VirtualDesktop"
)

/// Pure frame placement math for migrating an app window onto the virtual desktop.
public enum VirtualDesktopLayout {
    public static let menuBarReserve: CGFloat = 28
    public static let outerMargin: CGFloat = 20

    public static func targetFrame(
        for originalSize: CGSize,
        in displayBounds: CGRect,
        windowIndex: Int = 0
    ) -> CGRect {
        let usable = CGRect(
            x: displayBounds.minX + outerMargin,
            y: displayBounds.minY + menuBarReserve + outerMargin,
            width: max(320, displayBounds.width - outerMargin * 2),
            height: max(240, displayBounds.height - menuBarReserve - outerMargin * 2)
        )
        let targetW = min(max(originalSize.width, 480), usable.width)
        let targetH = min(max(originalSize.height, 360), usable.height)
        let cascadeOffset = CGFloat(windowIndex % 4) * 28
        let rawX = usable.minX + (usable.width - targetW) * 0.5 + cascadeOffset
        let rawY = usable.minY + (usable.height - targetH) * 0.5 + cascadeOffset
        let clampedX = min(max(usable.minX, rawX), usable.maxX - targetW)
        let clampedY = min(max(usable.minY, rawY), usable.maxY - targetH)
        return CGRect(
            x: round(clampedX),
            y: round(clampedY),
            width: round(targetW),
            height: round(targetH)
        )
    }

    public static func isFrame(_ frame: CGRect, inside displayBounds: CGRect) -> Bool {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displayBounds.contains(center)
    }
}

/// Manages an isolated, non-mirrored HiDPI virtual display (`CGVirtualDisplay`)
/// dedicated to the active Computer Use session, along with window migration,
/// crash-safe restoration, and a human cursor barrier.
@MainActor
public final class VirtualDesktopManager {
    public enum ScreenChangeOutcome: Equatable, Sendable {
        case unchanged
        case updated(CGRect)
        case shouldDowngrade
    }

    public private(set) var displayID: CGDirectDisplayID?
    public private(set) var displayBounds: CGRect = .zero
    public private(set) var migratedRecords: [MigratedWindowRecord] = []

    private var virtualDisplayObject: NSObject?
    private var cursorBarrier: CursorBarrierRunner?

    public var isActive: Bool {
        displayID != nil && virtualDisplayObject != nil
    }

    public init() {}

    @discardableResult
    public func start(
        logicalWidth: UInt32 = 1440,
        logicalHeight: UInt32 = 900,
        initialApps: [String] = []
    ) async throws -> CGDirectDisplayID {
        if let existing = displayID {
            return existing
        }

        if VirtualDesktopRecovery.hasSnapshot() {
            let msg = VirtualDesktopRecovery.applyRecovery()
            virtualDesktopLogger.notice("Recovered orphan virtual desktop snapshot: \(msg, privacy: .public)")
        }

        guard
            let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
            let vdCls = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
            let settingsCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
            let modeCls = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type
        else {
            throw VirtualDesktopError.privateAPIUnavailable
        }

        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)

        let desc = descCls.init()
        desc.setValue("Comma Agent Desktop", forKey: "name")
        desc.setValue(NSNumber(value: Int(logicalWidth * 2)), forKey: "maxPixelsWide")
        desc.setValue(NSNumber(value: Int(logicalHeight * 2)), forKey: "maxPixelsHigh")
        desc.setValue(
            NSValue(size: NSSize(width: 300, height: 187.5)),
            forKey: "sizeInMillimeters"
        )
        desc.setValue(NSNumber(value: 0x0001), forKey: "productID")
        desc.setValue(NSNumber(value: 0xC0AA), forKey: "vendorID")
        let uniqueSerial = UInt32.random(in: 0x1000...0x7FFF_FFFF)
        desc.setValue(NSNumber(value: uniqueSerial), forKey: "serialNum")
        desc.setValue(DispatchQueue.main, forKey: "queue")

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard
            let vdAllocObj = vdCls.perform(allocSel)?.takeUnretainedValue() as? NSObject,
            let vd = vdAllocObj.perform(initSel, with: desc)?.takeRetainedValue() as? NSObject
        else {
            virtualDesktopLogger.error("CGVirtualDisplay initWithDescriptor returned nil")
            throw VirtualDesktopError.creationFailed
        }

        let modeSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let modeMethod = class_getInstanceMethod(modeCls, modeSel) else {
            throw VirtualDesktopError.creationFailed
        }
        typealias ModeInitFn = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
        let modeInit = unsafeBitCast(method_getImplementation(modeMethod), to: ModeInitFn.self)
        let mode1x: AnyObject? = modeCls.perform(allocSel).flatMap { raw in
            modeInit(raw.takeUnretainedValue(), modeSel, UInt(logicalWidth), UInt(logicalHeight), 60.0)?.takeRetainedValue()
        }
        let mode2x: AnyObject? = modeCls.perform(allocSel).flatMap { raw in
            modeInit(raw.takeUnretainedValue(), modeSel, UInt(logicalWidth * 2), UInt(logicalHeight * 2), 60.0)?.takeRetainedValue()
        }

        let settings = settingsCls.init()
        settings.setValue(NSNumber(value: 1), forKey: "hiDPI")
        settings.setValue([mode2x as Any, mode1x as Any].compactMap { $0 }, forKey: "modes")
        _ = vd.perform(NSSelectorFromString("applySettings:"), with: settings)

        let createdID = CGDirectDisplayID((vd.value(forKey: "displayID") as? NSNumber)?.uint32Value ?? 0)
        guard createdID != 0 else {
            throw VirtualDesktopError.creationFailed
        }

        virtualDisplayObject = vd
        displayID = createdID

        try? await Task.sleep(nanoseconds: 250_000_000)

        // Do NOT call CGBeginDisplayConfiguration / CGConfigureDisplayOrigin on a
        // CGVirtualDisplay: mutating its display configuration traps it in WindowServer
        // until process exit, leaking one ghost display per session in a long-lived daemon.
        // Without a display transaction, releasing `virtualDisplayObject` tears the display
        // down cleanly in-process (~0.2s on macOS 26), while `installCursorBarrier` keeps
        // the human pointer inside `mainBounds` regardless of which edge WindowServer chose.

        for _ in 0..<15 {
            let bounds = CGDisplayBounds(createdID)
            let hasScreen = NSScreen.screens.contains { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == createdID
            }
            if bounds.width >= 320, bounds.height >= 240, hasScreen {
                displayBounds = bounds
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if displayBounds.isEmpty {
            displayBounds = CGDisplayBounds(createdID)
        }

        installCursorBarrier(mainBounds: mainBounds, virtualBounds: displayBounds)

        if !initialApps.isEmpty {
            migrateApps(named: initialApps)
        }

        virtualDesktopLogger.notice(
            "Virtual desktop ready: id=\(createdID) bounds=\(NSStringFromRect(self.displayBounds), privacy: .public)"
        )
        return createdID
    }

    public func migrateApps(named appNames: [String], preferredWindowTitle: String? = nil) {
        guard isActive, !displayBounds.isEmpty else { return }
        let selfPID = getpid()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != selfPID
        }
        for query in appNames {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { continue }
            let app = running.first(where: { $0.bundleIdentifier?.lowercased() == needle })
                ?? running.first(where: { $0.localizedName?.lowercased() == needle })
                ?? running.first(where: { $0.localizedName?.lowercased().contains(needle) == true })
            guard let app else { continue }
            migratePrimaryWindow(of: app, preferredWindowTitle: preferredWindowTitle)
        }
    }

    public func handleScreenParametersChanged() -> ScreenChangeOutcome {
        guard let vdID = displayID, isActive else { return .unchanged }
        let mainID = CGMainDisplayID()
        let physicalScreens = NSScreen.screens.filter { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != vdID
        }
        let vdBounds = CGDisplayBounds(vdID)
        if mainID == vdID || physicalScreens.isEmpty || vdBounds.isEmpty {
            return .shouldDowngrade
        }
        let mainBounds = CGDisplayBounds(mainID)
        let changed = vdBounds != displayBounds
        displayBounds = vdBounds
        cursorBarrier?.updateBounds(mainBounds: mainBounds, virtualBounds: vdBounds)
        return changed ? .updated(vdBounds) : .unchanged
    }

    @discardableResult
    public func ensureWindowOnVirtualDesktop(
        app: NSRunningApplication,
        axWindow: AXUIElement,
        windowID: CGWindowID,
        windowTitle: String?
    ) -> CGRect? {
        guard isActive, !displayBounds.isEmpty else { return nil }
        guard let currentFrame = readAXFrame(of: axWindow) else { return nil }
        if VirtualDesktopLayout.isFrame(currentFrame, inside: displayBounds) {
            return currentFrame
        }

        let alreadyRecorded = migratedRecords.contains { existing in
            if windowID != 0 {
                return existing.windowID == windowID
            }
            return existing.pid == app.processIdentifier && existing.windowTitle == windowTitle
        }
        if !alreadyRecorded {
            let record = MigratedWindowRecord(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                appName: app.localizedName ?? "App",
                windowID: windowID,
                windowTitle: windowTitle,
                originX: currentFrame.origin.x,
                originY: currentFrame.origin.y,
                width: currentFrame.size.width,
                height: currentFrame.size.height
            )
            migratedRecords.append(record)
            persistSnapshot()
        }

        let target = VirtualDesktopLayout.targetFrame(
            for: currentFrame.size,
            in: displayBounds,
            windowIndex: max(0, migratedRecords.count - 1)
        )
        applyAXFrame(target, to: axWindow)
        return readAXFrame(of: axWindow) ?? target
    }

    @discardableResult
    public func restoreAllWindows() -> Int {
        guard !migratedRecords.isEmpty else {
            VirtualDesktopRecovery.discardSnapshot()
            return 0
        }
        let count = VirtualDesktopRecovery.restoreWindows(migratedRecords)
        migratedRecords.removeAll()
        VirtualDesktopRecovery.discardSnapshot()
        return count
    }

    public func stop() {
        removeCursorBarrier()
        _ = restoreAllWindows()
        displayID = nil
        displayBounds = .zero
        virtualDisplayObject = nil
        virtualDesktopLogger.notice("Virtual desktop torn down")
    }

    // MARK: - Private helpers

    private func migratePrimaryWindow(of app: NSRunningApplication, preferredWindowTitle: String? = nil) {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef) == .success,
            let windows = windowsRef as? [AXUIElement],
            !windows.isEmpty
        else { return }

        let targetWindow: AXUIElement = {
            if let wanted = preferredWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !wanted.isEmpty
            {
                let lowered = wanted.lowercased()
                if let exact = windows.first(where: { win in
                    var tRef: CFTypeRef?
                    return AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &tRef) == .success
                        && (tRef as? String)?.lowercased() == lowered
                }) {
                    return exact
                }
                if let partial = windows.first(where: { win in
                    var tRef: CFTypeRef?
                    return AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &tRef) == .success
                        && ((tRef as? String)?.lowercased().contains(lowered) == true)
                }) {
                    return partial
                }
            }
            return windows[0]
        }()

        var titleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(targetWindow, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        let winID = BackgroundSkyLight.cgWindowID(forAXWindow: targetWindow) ?? 0
        _ = ensureWindowOnVirtualDesktop(
            app: app,
            axWindow: targetWindow,
            windowID: winID,
            windowTitle: title
        )
    }

    private func readAXFrame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let posVal = posRef,
            let sizeVal = sizeRef,
            CFGetTypeID(posVal) == AXValueGetTypeID(),
            CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private func applyAXFrame(_ frame: CGRect, to window: AXUIElement) {
        var origin = frame.origin
        var size = frame.size
        if let posVal = AXValueCreate(.cgPoint, &origin) {
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    private func persistSnapshot() {
        guard let displayID else { return }
        let snapshot = VirtualDesktopSnapshot(
            virtualDisplayID: displayID,
            windows: migratedRecords
        )
        try? VirtualDesktopRecovery.writeSnapshot(snapshot)
    }

    private func installCursorBarrier(mainBounds: CGRect, virtualBounds: CGRect) {
        removeCursorBarrier()
        guard !virtualBounds.isEmpty, !mainBounds.isEmpty else { return }
        let runner = CursorBarrierRunner(mainBounds: mainBounds, virtualBounds: virtualBounds)
        runner.start()
        cursorBarrier = runner
    }

    private func removeCursorBarrier() {
        cursorBarrier?.stop()
        cursorBarrier = nil
    }
}

public final class CursorBarrierRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var mainBounds: CGRect
    private var virtualBounds: CGRect
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false

    public init(mainBounds: CGRect, virtualBounds: CGRect) {
        self.mainBounds = mainBounds
        self.virtualBounds = virtualBounds
    }

    public static func clampedPoint(
        _ point: CGPoint,
        mainBounds: CGRect,
        virtualBounds: CGRect
    ) -> CGPoint? {
        guard !mainBounds.isEmpty, !virtualBounds.isEmpty, virtualBounds.contains(point) else {
            return nil
        }
        return CGPoint(
            x: min(max(mainBounds.minX + 2, point.x), mainBounds.maxX - 2),
            y: min(max(mainBounds.minY + 2, point.y), mainBounds.maxY - 2)
        )
    }

    public func updateBounds(mainBounds: CGRect, virtualBounds: CGRect) {
        lock.lock()
        self.mainBounds = mainBounds
        self.virtualBounds = virtualBounds
        lock.unlock()
    }

    func start() {
        let thread = Thread { [self] in
            self.runTapLoop()
        }
        thread.name = "surf.comma.vd-cursor-barrier"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        stopped = true
        let activeTap = tap
        let activeRunLoop = runLoop
        lock.unlock()

        if let activeTap {
            CGEvent.tapEnable(tap: activeTap, enable: false)
        }
        if let activeRunLoop {
            CFRunLoopStop(activeRunLoop)
            CFRunLoopWakeUp(activeRunLoop)
        }
    }

    private func clampedIfNeeded(_ point: CGPoint) -> CGPoint? {
        lock.lock()
        let main = mainBounds
        let virtual = virtualBounds
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return nil }
        return Self.clampedPoint(point, mainBounds: main, virtualBounds: virtual)
    }

    private func isStopped() -> Bool {
        lock.lock()
        let value = stopped
        lock.unlock()
        return value
    }

    private func reenableTapIfActive() {
        lock.lock()
        let activeTap = stopped ? nil : tap
        lock.unlock()
        if let activeTap {
            CGEvent.tapEnable(tap: activeTap, enable: true)
        }
    }

    private func runTapLoop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        lock.unlock()

        let refcon = Unmanaged.passRetained(self).toOpaque()
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)

        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let runner = Unmanaged<CursorBarrierRunner>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    runner.reenableTapIfActive()
                    return Unmanaged.passUnretained(event)
                }
                if let clamped = runner.clampedIfNeeded(event.location) {
                    CGWarpMouseCursorPosition(clamped)
                    event.location = clamped
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Unmanaged<CursorBarrierRunner>.fromOpaque(refcon).release()
            return
        }

        let currentRL = CFRunLoopGetCurrent()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)

        lock.lock()
        if stopped {
            lock.unlock()
            CGEvent.tapEnable(tap: createdTap, enable: false)
            CFMachPortInvalidate(createdTap)
            Unmanaged<CursorBarrierRunner>.fromOpaque(refcon).release()
            return
        }
        tap = createdTap
        runLoop = currentRL
        lock.unlock()

        CFRunLoopAddSource(currentRL, source, .commonModes)
        CGEvent.tapEnable(tap: createdTap, enable: true)
        while !isStopped() {
            _ = CFRunLoopRunInMode(.defaultMode, 0.5, false)
        }

        CGEvent.tapEnable(tap: createdTap, enable: false)
        CFRunLoopRemoveSource(currentRL, source, .commonModes)
        CFMachPortInvalidate(createdTap)

        lock.lock()
        tap = nil
        runLoop = nil
        lock.unlock()

        Unmanaged<CursorBarrierRunner>.fromOpaque(refcon).release()
    }
}

public enum VirtualDesktopError: LocalizedError {
    case privateAPIUnavailable
    case creationFailed

    public var errorDescription: String? {
        switch self {
        case .privateAPIUnavailable:
            "CGVirtualDisplay private API is unavailable on this macOS version"
        case .creationFailed:
            "Failed to create virtual display for Comma Computer Use"
        }
    }
}
