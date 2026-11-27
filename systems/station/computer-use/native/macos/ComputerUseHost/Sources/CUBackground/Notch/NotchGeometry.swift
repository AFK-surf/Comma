import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Presentation state of the macOS Notch Dynamic Island during a Computer Use session.
public enum NotchPresentationState: String, Equatable, Sendable {
    /// Tucked cleanly inside the hardware notch / pill / top edge before reveal or after stop.
    case hidden
    /// Compact black pill flanking the notch or camera cutout showing live activity status.
    case compact
    /// Expanded card (default on session start): live virtual desktop preview,
    /// task name, one live status line, and the "Check computer" / "Stop" actions.
    case expanded
}

/// Physical top-bezel cutout style of the host display.
public enum NotchDisplayStyle: String, Equatable, Sendable {
    /// Traditional top-flush camera notch on 2021–2025 MacBook Pro / Air built-in displays.
    case legacyNotch
    /// Floating iPhone-aligned Dynamic Island camera cutout on 2026+ OLED MacBook Pro built-in displays.
    case dynamicIsland
    /// Non-notched built-in or external display (uses the existing top-flush menu-bar style).
    case none
}

/// Pure, display-derived anchor metrics for the notch / Dynamic Island / top-center bezel.
public struct NotchAnchorMetrics: Equatable, Sendable {
    /// Full AppKit frame of the host display (y-up).
    public let screenFrame: CGRect
    /// True when running on a physical built-in MacBook display with a top camera cutout
    /// (either traditional notch or floating Dynamic Island).
    public let hasHardwareNotch: Bool
    /// Cutout silhouette style determined for this physical display.
    public let displayStyle: NotchDisplayStyle
    /// Width of the hardware notch / camera cutout (or synthetic bezel anchor on non-notched screens).
    public let notchWidth: CGFloat
    /// Height of the hardware notch / menu-bar safe area band, or of the menu bar on non-notched screens.
    public let notchHeight: CGFloat
    /// Vertical floating offset from the top display edge (non-zero only for `.dynamicIsland`).
    public let topMargin: CGFloat

    /// True when the island renders as a floating iPhone-aligned capsule rather than top-flush with ears.
    public var isFloatingCapsule: Bool {
        displayStyle == .dynamicIsland
    }

    public init(
        screenFrame: CGRect,
        hasHardwareNotch: Bool,
        notchWidth: CGFloat,
        notchHeight: CGFloat,
        displayStyle: NotchDisplayStyle? = nil,
        topMargin: CGFloat? = nil
    ) {
        let resolvedStyle = displayStyle ?? (hasHardwareNotch ? .legacyNotch : .none)
        self.screenFrame = screenFrame
        self.displayStyle = resolvedStyle
        self.hasHardwareNotch = hasHardwareNotch || resolvedStyle != .none
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.topMargin = topMargin ?? (resolvedStyle == .dynamicIsland ? NotchDynamicIslandLayout.topMargin : 0)
    }

    /// Pure, scaling-invariant display style classification used by `from(screen:)` and unit tests.
    ///
    /// External monitors (`isBuiltIn == false`) and displays without a top safe area always resolve
    /// to `.none`. Built-in displays with a top cutout classify as `.dynamicIsland` when matching:
    /// 1. Known 2026+ OLED MacBook Pro hardware model identifiers (`Mac17,10`, `Mac17,12`), or
    /// 2. Known 2026 PROLED native panel pixel dimensions (`3024×1986`, `3472×2266`), or
    /// 3. Narrow camera cutout width ratio (`rawCutoutWidth / screenWidth < 9.5%`, invariant across
    ///    all macOS Display Scaling modes, unlike logical point width).
    /// All other notched built-in displays resolve to `.legacyNotch`.
    public static func detectDisplayStyle(
        isBuiltIn: Bool,
        safeAreaTop: CGFloat,
        screenWidth: CGFloat,
        rawCutoutWidth: CGFloat?,
        nativePixelSize: CGSize?,
        hardwareModel: String?
    ) -> NotchDisplayStyle {
        guard isBuiltIn, safeAreaTop > 0 else {
            return .none
        }
        if let model = hardwareModel, NotchDynamicIslandLayout.knownHardwareModels.contains(model) {
            return .dynamicIsland
        }
        if let px = nativePixelSize,
           NotchDynamicIslandLayout.knownNativePixelSizes.contains(where: {
               abs($0.width - px.width) <= 2 && abs($0.height - px.height) <= 2
           }) {
            return .dynamicIsland
        }
        if let rawWidth = rawCutoutWidth,
           rawWidth > 0,
           screenWidth > 0,
           (rawWidth / screenWidth) < NotchDynamicIslandLayout.maxCutoutWidthRatio {
            return .dynamicIsland
        }
        return .legacyNotch
    }

    @MainActor
    public static func from(screen: NSScreen) -> NotchAnchorMetrics {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let isBuiltIn = displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false
        let topInset = screen.safeAreaInsets.top

        if isBuiltIn, topInset > 0 {
            let left = screen.auxiliaryTopLeftArea
            let right = screen.auxiliaryTopRightArea
            let rawCutoutWidth: CGFloat? = {
                guard let left, let right else { return nil }
                return max(0, screen.frame.width - left.width - right.width)
            }()
            let nativeSize = displayID.flatMap(Self.nativeDisplayPixelSize(for:))
            let style = Self.detectDisplayStyle(
                isBuiltIn: true,
                safeAreaTop: topInset,
                screenWidth: screen.frame.width,
                rawCutoutWidth: rawCutoutWidth,
                nativePixelSize: nativeSize,
                hardwareModel: Self.currentHardwareModel()
            )
            if style == .dynamicIsland {
                let width = max(
                    NotchDynamicIslandLayout.minCutoutWidth,
                    rawCutoutWidth ?? NotchDynamicIslandLayout.defaultCutoutWidth
                )
                return NotchAnchorMetrics(
                    screenFrame: screen.frame,
                    hasHardwareNotch: true,
                    notchWidth: width,
                    notchHeight: topInset,
                    displayStyle: .dynamicIsland
                )
            }
            if let rawCutoutWidth {
                let computedWidth = max(140, rawCutoutWidth)
                return NotchAnchorMetrics(
                    screenFrame: screen.frame,
                    hasHardwareNotch: true,
                    notchWidth: computedWidth,
                    notchHeight: topInset,
                    displayStyle: .legacyNotch
                )
            }
        }
        // Non-notched or external display: the island hangs over the menu bar, so its top band
        // matches the menu bar height (24pt when the menu bar auto-hides).
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchAnchorMetrics(
            screenFrame: screen.frame,
            hasHardwareNotch: false,
            notchWidth: 200,
            notchHeight: menuBarHeight >= 20 && menuBarHeight <= 40 ? menuBarHeight : 24,
            displayStyle: .none
        )
    }

    private static let cachedHardwareModel: String? = {
        var size: Int = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let model = String(cString: buffer)
        return model.isEmpty ? nil : model
    }()

    static func currentHardwareModel() -> String? {
        cachedHardwareModel
    }

    private static func nativeDisplayPixelSize(for displayID: CGDirectDisplayID) -> CGSize? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] {
            // kDisplayModeNativeFlag (0x02000000) identifies the panel's true physical resolution
            // independent of HiDPI display scaling.
            let nativeFlag: UInt32 = 0x0200_0000
            if let native = modes.first(where: { ($0.ioFlags & nativeFlag) != 0 }) {
                return CGSize(width: native.pixelWidth, height: native.pixelHeight)
            }
        }
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        return nil
    }
}

/// Dimensions and styling tokens for the Notch silhouette and content regions.
public struct NotchDimensions: Equatable, Sendable {
    /// Outer concave ear radius curving seamlessly into the top screen edge (0 for floating capsules).
    public let earRadius: CGFloat
    /// Bottom corner radius of the island body (also top corner radius for floating capsules).
    public let bottomCornerRadius: CGFloat
    /// Width of the island body (excluding the two concave ears).
    public let bodyWidth: CGFloat
    /// Height of the island body.
    public let bodyHeight: CGFloat
    /// Top clearance inside the body so content never overlaps the physical camera housing / menu bar.
    public let topContentInset: CGFloat

    public init(
        earRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        bodyWidth: CGFloat,
        bodyHeight: CGFloat,
        topContentInset: CGFloat
    ) {
        self.earRadius = earRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.bodyWidth = bodyWidth
        self.bodyHeight = bodyHeight
        self.topContentInset = topContentInset
    }

    /// Total width including left & right concave bezel ears.
    public var totalWidth: CGFloat {
        bodyWidth + (earRadius * 2)
    }

    public static func target(
        for state: NotchPresentationState,
        anchor: NotchAnchorMetrics
    ) -> NotchDimensions {
        let topClearance = max(0, anchor.notchHeight - anchor.topMargin)
        switch state {
        case .hidden:
            if anchor.isFloatingCapsule {
                let height = NotchDynamicIslandLayout.compactHeight(for: anchor)
                return NotchDimensions(
                    earRadius: 0,
                    bottomCornerRadius: height / 2,
                    bodyWidth: max(NotchDynamicIslandLayout.minCutoutWidth, anchor.notchWidth),
                    bodyHeight: height,
                    topContentInset: topClearance
                )
            }
            // On a legacy hardware notch the island starts as the notch itself. Elsewhere it
            // starts as a zero-height sliver on the top edge, so it grows out of the
            // bezel instead of popping in.
            return NotchDimensions(
                earRadius: 6,
                bottomCornerRadius: 10,
                bodyWidth: anchor.hasHardwareNotch ? anchor.notchWidth : 120,
                bodyHeight: anchor.hasHardwareNotch ? anchor.notchHeight : 0,
                topContentInset: topClearance
            )
        case .compact:
            if anchor.isFloatingCapsule {
                let layout = NotchDynamicIslandLayout.self
                let height = layout.compactHeight(for: anchor)
                let width = max(layout.minCutoutWidth, anchor.notchWidth) + layout.wingWidth * 2
                return NotchDimensions(
                    earRadius: 0,
                    bottomCornerRadius: height / 2,
                    bodyWidth: width,
                    bodyHeight: height,
                    topContentInset: 0
                )
            }
            // Truly minimal collapsed state: flush with the hardware notch or
            // macOS menu bar so zero pixels protrude onto windows beneath.
            let layout = NotchCompactLayout.self
            if anchor.hasHardwareNotch {
                let height = max(anchor.notchHeight, 30)
                let width = anchor.notchWidth + layout.notchedWingWidth * 2
                return NotchDimensions(
                    earRadius: layout.earRadius,
                    bottomCornerRadius: layout.bottomCornerRadius,
                    bodyWidth: width,
                    bodyHeight: height,
                    topContentInset: 0
                )
            } else {
                let height = max(anchor.notchHeight, layout.minNonNotchedHeight)
                return NotchDimensions(
                    earRadius: layout.earRadius,
                    bottomCornerRadius: layout.bottomCornerRadius,
                    bodyWidth: layout.nonNotchedBodyWidth,
                    bodyHeight: height,
                    topContentInset: 0
                )
            }
        case .expanded:
            let layout = NotchExpandedLayout.self
            let maxAllowedWidth = max(420, anchor.screenFrame.width - 80)
            let bodyWidth = min(layout.bodyWidth, maxAllowedWidth)
            if anchor.isFloatingCapsule {
                let di = NotchDynamicIslandLayout.self
                let detailsTop = di.expandedDetailsTop(forTopClearance: topClearance)
                let bodyHeight = max(
                    di.expandedEdgeInset * 2 + di.expandedPreviewSize.height,
                    detailsTop + di.expandedMinDetailsHeight + di.expandedEdgeInset
                )
                return NotchDimensions(
                    earRadius: 0,
                    bottomCornerRadius: di.expandedCornerRadius,
                    bodyWidth: bodyWidth,
                    bodyHeight: bodyHeight,
                    topContentInset: topClearance
                )
            }
            let bodyHeight = topClearance + layout.topGap + layout.previewSize.height + layout.edgeInset
            return NotchDimensions(
                earRadius: layout.earRadius,
                bottomCornerRadius: layout.bottomCornerRadius,
                bodyWidth: bodyWidth,
                bodyHeight: bodyHeight,
                topContentInset: topClearance
            )
        }
    }

    /// Computes the AppKit window frame (top-edge flush with `anchor.screenFrame.maxY`,
    /// horizontally centered on `anchor.screenFrame.midX`), including extra bottom/side
    /// padding so subtle shadow never clips. Defaults to `.expanded` so existing callers
    /// keep stable full-island bounds; pass `state: .compact` to shrink the panel when collapsed.
    public static func panelFrame(
        for anchor: NotchAnchorMetrics,
        state: NotchPresentationState = .expanded,
        shadowPadding: CGFloat = 36
    ) -> CGRect {
        let dims = target(for: state, anchor: anchor)
        let compactPad: CGFloat = anchor.isFloatingCapsule ? 16 : 10
        let pad = state == .compact ? min(shadowPadding, compactPad) : shadowPadding
        let width = dims.totalWidth + pad * 2
        let height = anchor.topMargin + dims.bodyHeight + pad
        let x = round(anchor.screenFrame.midX - width / 2)
        let y = round(anchor.screenFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Exact visible silhouette bounding rect in AppKit screen coordinates (no shadow padding),
    /// used for click-through gating (`ignoresMouseEvents`) and hover expand/collapse tracking.
    public static func islandScreenRect(
        for state: NotchPresentationState,
        anchor: NotchAnchorMetrics
    ) -> CGRect {
        let dims = target(for: state, anchor: anchor)
        guard dims.bodyHeight > 0.5 else { return .zero }
        let width = dims.totalWidth
        let height = dims.bodyHeight
        let x = round(anchor.screenFrame.midX - width / 2)
        let y = round(anchor.screenFrame.maxY - anchor.topMargin - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Outward hit tolerance matching Comma's `NotchConfiguration.interactionOutset` (4pt),
    /// ensuring pointer hits slammed against `screenFrame.maxY` (top bezel) always register.
    public static let compactInteractionOutset: CGFloat = 4

    /// Interactive hit rect for the compact notch / floating capsule (expanded by
    /// `compactInteractionOutset` on left/right and up to `screenFrame.maxY` on top;
    /// kept tight on the bottom so browser tabs below stay clickable).
    public static func compactHitRect(for anchor: NotchAnchorMetrics) -> CGRect {
        let base = islandScreenRect(for: .compact, anchor: anchor)
        guard base != .zero else { return .zero }
        let pad = compactInteractionOutset
        let topPad = anchor.topMargin + pad
        return CGRect(
            x: base.minX - pad,
            y: base.minY - 2,
            width: base.width + pad * 2,
            height: base.height + topPad + 2
        )
    }

    public static func expandedPreviewScreenRect(for anchor: NotchAnchorMetrics) -> CGRect {
        let expanded = target(for: .expanded, anchor: anchor)
        let island = islandScreenRect(for: .expanded, anchor: anchor)
        guard island != .zero else { return .zero }
        let local = anchor.isFloatingCapsule
            ? NotchDynamicIslandLayout.expandedPreviewFrame(in: expanded)
            : NotchExpandedLayout.previewFrame(in: expanded)
        let bodyMinX = island.minX + expanded.earRadius
        return CGRect(
            x: bodyMinX + local.minX,
            y: island.maxY - local.maxY,
            width: local.width,
            height: local.height
        )
    }
}

/// Layout tokens for the floating iPhone-aligned Dynamic Island capsule on
/// 2026+ OLED MacBook Pro built-in displays.
public enum NotchDynamicIslandLayout {
    /// Vertical gap between the top screen edge and the floating capsule.
    public static let topMargin: CGFloat = 6
    /// Width of each symmetric wing flanking the center camera housing in compact mode.
    public static let wingWidth: CGFloat = 52
    /// Minimum center cutout width reserved for the camera pill.
    public static let minCutoutWidth: CGFloat = 96
    /// Fallback center cutout width if auxiliary top areas are unavailable.
    public static let defaultCutoutWidth: CGFloat = 122
    /// Compact floating capsule height bounds.
    public static let minCompactHeight: CGFloat = 28
    public static let maxCompactHeight: CGFloat = 34
    /// 16:10 mini live desktop preview nested concentrically inside the left semicircular cap
    /// (`7.21pt` radial clearance vs `7.25pt` vertical clearance on a `32pt` pill).
    public static let previewSize = CGSize(width: 28, height: 17.5)
    public static let previewCornerRadius: CGFloat = 5.5
    public static let previewLeadingInset: CGFloat = 11
    /// Concentric activity ring nested in the right semicircular cap (`8pt` all around on `32pt` pill).
    public static let activityRingSize: CGFloat = 16
    public static let activityRingLineWidth: CGFloat = 2
    /// Uniform tactile hover scale (scales shell & content together while preserving `#000` body).
    public static let hoverScale: CGFloat = 1.032

    /// Expanded floating capsule card tokens (staggered iPhone Dynamic Island layout):
    /// preview sits triple-concentrically in the left slot (`14pt` top/left/bottom, clearing the
    /// centered camera cutout by `9pt`), while details start cleanly below the camera band (`36pt`).
    public static let expandedCornerRadius: CGFloat = 30
    public static let expandedEdgeInset: CGFloat = 14
    public static let expandedPreviewSize = CGSize(width: 150, height: 94)
    public static let expandedPreviewToDetailsGap: CGFloat = 14
    public static let expandedTitleToStatusGap: CGFloat = 6
    public static let expandedMinDetailsHeight: CGFloat = 72
    public static var expandedPreviewCornerRadius: CGFloat {
        expandedCornerRadius - expandedEdgeInset
    }

    /// Cutout-to-screen width ratio separating the narrow Dynamic Island cutout (< 9.5%)
    /// from traditional MacBook notches (10.5%–14.5%), invariant across macOS scaling modes.
    public static let maxCutoutWidthRatio: CGFloat = 0.095
    /// Known 2026 PROLED XDR MacBook Pro hardware model identifiers.
    public static let knownHardwareModels: Set<String> = ["Mac17,10", "Mac17,12"]
    /// Known 2026 PROLED XDR native panel pixel sizes (14" and 16").
    public static let knownNativePixelSizes: [CGSize] = [
        CGSize(width: 3024, height: 1986),
        CGSize(width: 3472, height: 2266),
    ]

    public static func compactHeight(for anchor: NotchAnchorMetrics) -> CGFloat {
        let available = max(0, anchor.notchHeight - anchor.topMargin)
        return min(maxCompactHeight, max(minCompactHeight, available))
    }

    public static func activityTrailingInset(forHeight height: CGFloat) -> CGFloat {
        max(6, (height - activityRingSize) / 2)
    }

    public static func expandedDetailsTop(forTopClearance topClearance: CGFloat) -> CGFloat {
        max(36, topClearance + 4)
    }

    public static func expandedPreviewFrame(in body: NotchDimensions) -> CGRect {
        CGRect(
            x: expandedEdgeInset,
            y: expandedEdgeInset,
            width: expandedPreviewSize.width,
            height: expandedPreviewSize.height
        )
    }

    public static func expandedDetailsFrame(in body: NotchDimensions) -> CGRect {
        let preview = expandedPreviewFrame(in: body)
        let x = preview.maxX + expandedPreviewToDetailsGap
        let y = expandedDetailsTop(forTopClearance: body.topContentInset)
        return CGRect(
            x: x,
            y: y,
            width: max(0, body.bodyWidth - x - expandedEdgeInset),
            height: max(0, body.bodyHeight - y - expandedEdgeInset)
        )
    }
}

/// Layout of the minimal compact (collapsed) notch state: strictly flush with
/// the hardware notch or macOS menu bar (0pt hanging below).
public enum NotchCompactLayout {
    public static let earRadius: CGFloat = 8
    public static let bottomCornerRadius: CGFloat = 10
    public static let edgeInset: CGFloat = 5
    /// Tight non-notched width: mini 16:10 live thumbnail + ring + compact status.
    public static let nonNotchedBodyWidth: CGFloat = 246
    /// Minimum height on non-notched displays (matches standard 25–30pt macOS menu bar).
    public static let minNonNotchedHeight: CGFloat = 30
    /// Width of each symmetric wing flanking a MacBook hardware notch.
    public static let notchedWingWidth: CGFloat = 48
    /// 16:10 mini live desktop preview matching the virtual display aspect ratio.
    public static let previewSize = CGSize(width: 30, height: 18.75)
    public static let previewToStatusGap: CGFloat = 8
    public static let trailingInset: CGFloat = 11

    public static var previewCornerRadius: CGFloat {
        max(3, bottomCornerRadius - edgeInset)
    }
}

/// Layout of the expanded island body. Coordinates are y-down, relative to the
/// body's top-left corner (ears excluded).
///
/// The live preview sits `edgeInset` from the left wall and the bottom edge, and
/// its corner radius is the body's bottom radius minus that inset, so the two
/// rounded corners share one center (concentric).
///
/// The details column spans exactly the preview's height: the task name and the
/// live status line hang from its top, the action row sits on its bottom edge.
public enum NotchExpandedLayout {
    public static let bodyWidth: CGFloat = 468
    public static let earRadius: CGFloat = 14
    public static let bottomCornerRadius: CGFloat = 28
    public static let edgeInset: CGFloat = 12
    /// Breathing room between the notch / menu bar band and the content.
    public static let topGap: CGFloat = 10
    /// 16:10, the aspect ratio of the virtual display.
    public static let previewSize = CGSize(width: 144, height: 90)
    public static let previewToDetailsGap: CGFloat = 18
    /// Equals the preview's distance to the bottom edge plus the action row's
    /// visual inset, so the "Stop" capsule sits as far from the right wall as
    /// from the bottom edge.
    public static let detailsTrailingInset: CGFloat = 16
    /// Height of the action row ("Check computer ↗" and "Stop").
    public static let actionRowHeight: CGFloat = 24

    public static var previewCornerRadius: CGFloat {
        bottomCornerRadius - edgeInset
    }

    public static func previewFrame(in body: NotchDimensions) -> CGRect {
        CGRect(
            x: edgeInset,
            y: body.bodyHeight - edgeInset - previewSize.height,
            width: previewSize.width,
            height: previewSize.height
        )
    }

    public static func detailsFrame(in body: NotchDimensions) -> CGRect {
        let preview = previewFrame(in: body)
        let x = preview.maxX + previewToDetailsGap
        return CGRect(
            x: x,
            y: preview.minY,
            width: max(0, body.bodyWidth - x - detailsTrailingInset),
            height: preview.height
        )
    }
}

/// Deterministic analytical sample for the Notch entrance animation (`f(t)`).
///
/// Choreography on Computer Use session start: the island grows out of the notch
/// (or the floating Dynamic Island pill / top edge) on critically damped springs —
/// no overshoot, no glow. Width spreads slightly ahead of the drop, like ink.
/// The preview rides the growing bottom-left corner and fades in (scale 0.94 → 1)
/// from 0.10s; the details fade in and rise 6pt → 0 from 0.32s, once the body is
/// within the preview–details gap of its final width, so text never crosses the preview.
public struct NotchEntranceSample: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let earRadius: CGFloat
    public let bottomCornerRadius: CGFloat
    public let previewOpacity: Double
    public let previewScale: CGFloat
    public let detailsOpacity: Double
    public let detailsOffsetY: CGFloat
    public let isSettled: Bool

    public static let totalDuration: TimeInterval = 0.62

    /// Natural frequencies (rad/s) of the critically damped springs.
    private static let heightOmega: Double = 14
    private static let widthOmega: Double = 16

    public static func sample(
        elapsed: TimeInterval,
        anchor: NotchAnchorMetrics
    ) -> NotchEntranceSample {
        let t = max(0, elapsed)
        let hidden = NotchDimensions.target(for: .hidden, anchor: anchor)
        let expanded = NotchDimensions.target(for: .expanded, anchor: anchor)
        if t >= totalDuration {
            return NotchEntranceSample(
                width: expanded.bodyWidth,
                height: expanded.bodyHeight,
                earRadius: expanded.earRadius,
                bottomCornerRadius: expanded.bottomCornerRadius,
                previewOpacity: 1,
                previewScale: 1,
                detailsOpacity: 1,
                detailsOffsetY: 0,
                isSettled: true
            )
        }

        let sh = criticallyDampedSpring(t: t, omega: heightOmega)
        let sw = criticallyDampedSpring(t: t, omega: widthOmega)
        let previewProgress: Double
        let detailsProgress: Double
        if anchor.isFloatingCapsule {
            let shellProgress = min(sw, sh)
            previewProgress = smoothstep(edge0: 0.84, edge1: 0.96, x: shellProgress)
            detailsProgress = smoothstep(edge0: 0.88, edge1: 0.98, x: shellProgress)
        } else {
            previewProgress = easeOutCubic(clamp01((t - 0.10) / 0.30))
            detailsProgress = easeOutCubic(clamp01((t - 0.32) / 0.28))
        }

        return NotchEntranceSample(
            width: lerp(hidden.bodyWidth, expanded.bodyWidth, sw),
            height: lerp(hidden.bodyHeight, expanded.bodyHeight, sh),
            earRadius: lerp(hidden.earRadius, expanded.earRadius, sh),
            bottomCornerRadius: lerp(hidden.bottomCornerRadius, expanded.bottomCornerRadius, sh),
            previewOpacity: previewProgress,
            previewScale: lerp(0.94, 1.0, previewProgress),
            detailsOpacity: detailsProgress,
            detailsOffsetY: lerp(6, 0, detailsProgress),
            isSettled: false
        )
    }

    private static func clamp01(_ v: Double) -> Double {
        min(1, max(0, v))
    }

    private static func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        let u = clamp01((x - edge0) / max(1e-6, edge1 - edge0))
        return u * u * (3.0 - 2.0 * u)
    }

    private static func easeOutCubic(_ u: Double) -> Double {
        let inv = 1.0 - clamp01(u)
        return 1.0 - inv * inv * inv
    }

    /// Step response of a critically damped spring, `1 - (1 + ωt)e^(-ωt)`, which
    /// rises monotonically without overshoot. The last 15% of the run eases the
    /// residual (< 0.5%) onto exactly 1 so settling never snaps.
    private static func criticallyDampedSpring(t: TimeInterval, omega: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= totalDuration { return 1 }
        let raw = 1.0 - (1.0 + omega * t) * exp(-omega * t)
        let tail = clamp01((t - totalDuration * 0.85) / (totalDuration * 0.15))
        let smoothTail = tail * tail * (3.0 - 2.0 * tail)
        return raw + (1.0 - raw) * smoothTail
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}
