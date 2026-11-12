import ApplicationServices
import CUShared
import Foundation

@MainActor
public enum ComputerUseAction {
    public static func getAppState(
        appIdentifier: String,
        windowTitle: String?
    ) throws -> ComputerUseCommandOutput {
        let snapshot = try ComputerUseCore.captureSnapshot(
            appIdentifier: appIdentifier,
            selection: WindowSelection(titleSubstring: windowTitle),
            includeScreenshot: true
        )
        return try ComputerUseCore.persistAndFormat(snapshot: snapshot)
    }

    public static func listApps() -> ComputerUseCommandOutput {
        let lines = ComputerUseCore.listRunningApps().map { app in
            "\(app.name) — \(app.bundleID) [running\(app.isActive ? ", active" : "")]"
        }
        return ComputerUseCommandOutput(text: lines.joined(separator: "\n"))
    }

    public static func click(
        snapshotID: String,
        elementIndex: Int?,
        x: Double?,
        y: Double?
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)

        if let elementIndex {
            let node = try ComputerUseCore.resolveCachedElement(
                cachedIndex: elementIndex,
                metadata: metadata,
                fresh: current
            )
            try click(node: node, in: current)
        } else if let x, let y {
            try ComputerUseCore.ensureStableFrameForCoordinateAction(
                metadata: metadata,
                fresh: current
            )
            let point = try screenshotPointToWindowLocal(
                screenshotSize: metadata.screenshotSize,
                windowFrame: current.windowFrame,
                x: x,
                y: y
            )
            try clickAtLocalPoint(point, in: current)
        } else {
            throw ComputerUseError.invalidArgument("click requires either --element-index or --x/--y")
        }

        return try settledOutput(afterActionOn: current)
    }

    public static func typeText(
        snapshotID: String,
        text: String,
        elementIndex: Int?
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try editableNode(
            in: current,
            metadata: metadata,
            explicitIndex: elementIndex
        )

        if cuIsAttributeSettable(node.element, name: kAXFocusedAttribute as String) {
            _ = AXUIElementSetAttributeValue(
                node.element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }

        let keyboard = BackgroundKeyboardDispatcher(targetPID: current.app.processIdentifier)
        try keyboard.typeText(text)

        return try settledOutput(afterActionOn: current)
    }

    public static func setValue(
        snapshotID: String,
        elementIndex: Int,
        value: String
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )

        guard node.isValueSettable else {
            throw ComputerUseError.elementNotSettable(elementIndex)
        }

        let result = AXUIElementSetAttributeValue(
            node.element,
            kAXValueAttribute as CFString,
            value as CFString
        )
        guard result == .success else {
            throw UIElementError.axError(result, action: "setValue")
        }

        return try settledOutput(afterActionOn: current)
    }

    public static func pressKey(
        snapshotID: String,
        key: String
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let dispatcher = BackgroundKeyboardDispatcher(targetPID: current.app.processIdentifier)
        try dispatcher.press(keyCombination: key)

        return try settledOutput(afterActionOn: current)
    }

    public static func scroll(
        snapshotID: String,
        elementIndex: Int,
        direction: String,
        pages: Int
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )
        let action = try resolveScrollAction(node: node, direction: direction)
        let overlayPoint = overlayScreenPoint(for: node, in: current)
        let overlayTarget = overlayTarget(for: current)
        let tracking = overlayTracking(for: node, in: current)

        for _ in 0 ..< max(1, pages) {
            try DaemonCursor.shared.runApproachThenAction(
                kind: .scroll(direction: direction),
                target: overlayTarget,
                fallbackScreenPoint: overlayPoint,
                fallbackWindowFrame: current.windowFrame,
                tracking: tracking
            ) {
                let result = AXUIElementPerformAction(node.element, action as CFString)
                guard result == .success else {
                    throw UIElementError.axError(result, action: action)
                }
            }
        }

        return try settledOutput(afterActionOn: current)
    }

    public static func performSecondaryAction(
        snapshotID: String,
        elementIndex: Int,
        action: String
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        let node = try ComputerUseCore.resolveCachedElement(
            cachedIndex: elementIndex,
            metadata: metadata,
            fresh: current
        )
        let rawAction = try resolveSecondaryAction(node: node, requestedAction: action)

        try DaemonCursor.shared.runApproachThenAction(
            kind: .secondaryAction,
            target: overlayTarget(for: current),
            fallbackScreenPoint: overlayScreenPoint(for: node, in: current),
            fallbackWindowFrame: current.windowFrame,
            tracking: overlayTracking(for: node, in: current)
        ) {
            let result = AXUIElementPerformAction(node.element, rawAction as CFString)
            guard result == .success else {
                throw UIElementError.axError(result, action: rawAction)
            }
        }

        return try settledOutput(afterActionOn: current)
    }

    public static func drag(
        snapshotID: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double
    ) throws -> ComputerUseCommandOutput {
        let metadata = try ComputerUseSnapshotStore.load(snapshotID: snapshotID)
        let current = try ComputerUseCore.validateSnapshot(metadata)
        try ComputerUseCore.ensureStableFrameForCoordinateAction(
            metadata: metadata,
            fresh: current
        )
        let fromLocal = try screenshotPointToWindowLocal(
            screenshotSize: metadata.screenshotSize,
            windowFrame: current.windowFrame,
            x: fromX,
            y: fromY
        )
        let toLocal = try screenshotPointToWindowLocal(
            screenshotSize: metadata.screenshotSize,
            windowFrame: current.windowFrame,
            x: toX,
            y: toY
        )

        let dispatcher = BackgroundMouseDispatcher(
            targetPID: current.app.processIdentifier,
            windowNumber: current.windowID,
            windowLayer: current.windowLayer,
            windowFrame: current.windowFrame,
            modifierFlags: []
        )

        let startScreen = overlayScreenPointForLocalPoint(
            windowLocalPoint: fromLocal,
            windowFrame: current.windowFrame
        )
        let endScreen = overlayScreenPointForLocalPoint(
            windowLocalPoint: toLocal,
            windowFrame: current.windowFrame
        )
        var currentAnchor = fromLocal
        let target = overlayTarget(for: current)
        let tracking = windowLocalPointOverlayTracking(
            target: target,
            fallbackWindowFrame: current.windowFrame,
            currentWindowLocalPoint: { currentAnchor }
        )

        var handle: DragHandle?
        try DaemonCursor.shared.runApproachThenDrag(
            button: .left,
            target: target,
            startScreenPoint: startScreen,
            endScreenPoint: endScreen,
            fallbackWindowFrame: current.windowFrame,
            approachTracking: tracking,
            onDragDown: {
                currentAnchor = fromLocal
                handle = try dispatcher.startDrag(at: fromLocal, button: .left)
            },
            onDragMove: { screenPoint, _ in
                let local = translatedWindowLocalPoint(
                    fromAppKitScreenPoint: screenPoint,
                    windowFrame: current.windowFrame
                )
                currentAnchor = local
                try handle?.move(to: local)
            },
            onDragUp: { _ in
                currentAnchor = toLocal
                try handle?.release(at: toLocal)
            }
        )

        return try settledOutput(afterActionOn: current)
    }

    private static func click(
        node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) throws {
        let pressLikeAction = node.actions.first(where: { action in
            action == kAXPressAction as String || action == kAXConfirmAction as String
        })

        if let pressLikeAction,
           node.role != kAXTextFieldRole as String,
           node.role != kAXTextAreaRole as String
        {
            try DaemonCursor.shared.runApproachThenAction(
                kind: .accessibilityAction,
                target: overlayTarget(for: snapshot),
                fallbackScreenPoint: overlayScreenPoint(for: node, in: snapshot),
                fallbackWindowFrame: snapshot.windowFrame,
                tracking: overlayTracking(for: node, in: snapshot)
            ) {
                let result = AXUIElementPerformAction(node.element, pressLikeAction as CFString)
                guard result == .success else {
                    throw UIElementError.axError(result, action: pressLikeAction)
                }
            }
            return
        }

        guard let frame = node.frame else {
            throw ComputerUseError.elementFrameUnavailable(node.index)
        }

        let screenPoint = CGPoint(x: frame.midX, y: frame.midY)
        let localPoint = translatedWindowLocalPoint(
            screenPoint: screenPoint,
            windowFrame: snapshot.windowFrame
        )
        try clickAtLocalPoint(localPoint, in: snapshot)
    }

    private static func clickAtLocalPoint(
        _ localPoint: CGPoint,
        in snapshot: RuntimeAppSnapshot
    ) throws {
        let dispatcher = BackgroundMouseDispatcher(
            targetPID: snapshot.app.processIdentifier,
            windowNumber: snapshot.windowID,
            windowLayer: snapshot.windowLayer,
            windowFrame: snapshot.windowFrame,
            modifierFlags: []
        )
        let overlayPoint = overlayScreenPointForLocalPoint(
            windowLocalPoint: localPoint,
            windowFrame: snapshot.windowFrame
        )
        let target = overlayTarget(for: snapshot)
        let tracking = windowLocalPointOverlayTracking(
            target: target,
            fallbackWindowFrame: snapshot.windowFrame,
            currentWindowLocalPoint: { localPoint }
        )

        try DaemonCursor.shared.runApproachThenAction(
            kind: .click(button: .left),
            target: target,
            fallbackScreenPoint: overlayPoint,
            fallbackWindowFrame: snapshot.windowFrame,
            tracking: tracking
        ) {
            try dispatcher.click(at: localPoint)
        }
    }

    private static func editableNode(
        in snapshot: RuntimeAppSnapshot,
        metadata: ComputerUseSnapshotMetadata,
        explicitIndex: Int?
    ) throws -> RuntimeAXNode {
        if let explicitIndex {
            let node = try ComputerUseCore.resolveCachedElement(
                cachedIndex: explicitIndex,
                metadata: metadata,
                fresh: snapshot
            )
            guard node.isValueSettable else {
                throw ComputerUseError.elementNotSettable(explicitIndex)
            }
            return node
        }

        guard let focusedIndex = snapshot.focusedElementIndex else {
            throw ComputerUseError.focusedElementUnavailable
        }
        let focused = try snapshot.node(index: focusedIndex)
        guard focused.isValueSettable else {
            throw ComputerUseError.elementNotSettable(focusedIndex)
        }
        return focused
    }

    private static func screenshotPointToWindowLocal(
        screenshotSize: CGSizeCodable?,
        windowFrame: CGRect,
        x: Double,
        y: Double
    ) throws -> CGPoint {
        guard let screenshotSize = screenshotSize?.cgSize else {
            throw ComputerUseError.coordinateActionRequiresScreenshot
        }

        return windowLocalPoint(
            fromScreenshotPixel: CGPoint(x: x, y: y),
            screenshotSize: screenshotSize,
            windowFrame: windowFrame
        )
    }

    private static func resolveScrollAction(
        node: RuntimeAXNode,
        direction: String
    ) throws -> String {
        let canonical = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchingActions = node.actions.filter { action in
            let display = displayName(forAction: action).lowercased()
            return display.contains("scroll") && display.contains(canonical)
        }

        if let pageAction = matchingActions.first(where: { $0.localizedCaseInsensitiveContains("Page") }) {
            return pageAction
        }
        if let first = matchingActions.first {
            return first
        }

        throw ComputerUseError.elementNotScrollable(node.index)
    }

    private static func resolveSecondaryAction(
        node: RuntimeAXNode,
        requestedAction: String
    ) throws -> String {
        if let raw = node.actions.first(where: {
            $0.caseInsensitiveCompare(requestedAction) == .orderedSame
        }) {
            return raw
        }

        if let display = node.actions.first(where: {
            displayName(forAction: $0).caseInsensitiveCompare(requestedAction) == .orderedSame
        }) {
            return display
        }

        throw ComputerUseError.secondaryActionNotFound(
            elementIndex: node.index,
            action: requestedAction
        )
    }

    private static func overlayTarget(for snapshot: RuntimeAppSnapshot) -> ActionOverlayTarget {
        ActionOverlayTarget(
            windowNumber: snapshot.windowID,
            windowLayer: snapshot.windowLayer
        )
    }

    private static func overlayScreenPoint(
        for node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> CGPoint {
        if let frame = node.frame {
            return overlayScreenPointForAXFrame(frame)
        }

        return overlayScreenPointForAXFrame(snapshot.windowFrame)
    }

    private static func overlayTracking(
        for node: RuntimeAXNode,
        in snapshot: RuntimeAppSnapshot
    ) -> ActionOverlayTracking {
        let fallbackFrame = node.frame ?? snapshot.windowFrame
        let overlayTarget = overlayTarget(for: snapshot)

        return axFrameOverlayTracking(
            target: overlayTarget,
            fallbackWindowFrame: snapshot.windowFrame,
            fallbackFrame: fallbackFrame
        ) {
            actionOverlayAXFrame(of: node.element) ?? actionOverlayAXFrame(of: snapshot.windowElement)
        }
    }

    private static func settledOutput(
        afterActionOn snapshot: RuntimeAppSnapshot
    ) throws -> ComputerUseCommandOutput {
        let updated = try ComputerUseCore.captureSettledSnapshot(
            afterActionOn: snapshot,
            includeScreenshot: true
        )
        return try ComputerUseCore.persistAndFormat(snapshot: updated)
    }
}
