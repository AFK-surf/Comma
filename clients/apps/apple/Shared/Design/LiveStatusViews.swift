#if os(iOS)
import SwiftUI

/// Visual style resolved from `LiveStatusAttributes.ContentState` for both Dynamic Island (obsidian dark)
/// and Lock Screen / Watch Smart Stack (adaptive light & dark).
struct LiveStatusVisualStyle: Sendable {
    let state: LiveStatusAttributes.ContentState

    var symbolName: String {
        switch state.category {
        case "car": "car.fill"
        case "delivery": "bicycle"
        case "flight": "airplane"
        case "train": "tram.fill"
        case "transit": "bus.fill"
        case "package": "shippingbox.fill"
        case "order": "cup.and.saucer.fill"
        case "timer": "timer"
        default: "sparkles"
        }
    }

    var resolvedStatusLabel: String {
        if let step = trimmed(state.stepLabel) { return step }
        switch state.status {
        case "attention": return String(localized: "Action needed")
        case "done": return String(localized: "Completed")
        case "cancelled": return String(localized: "Cancelled")
        case "failed": return String(localized: "Failed")
        default: return categoryDisplayName
        }
    }

    var categoryDisplayName: String {
        switch state.category {
        case "car": return String(localized: "Ride")
        case "delivery": return String(localized: "Delivery")
        case "flight": return String(localized: "Flight")
        case "train": return String(localized: "Train")
        case "transit": return String(localized: "Transit")
        case "package": return String(localized: "Package")
        case "order": return String(localized: "Order")
        case "timer": return String(localized: "Timer")
        case "progress": return String(localized: "Progress")
        default: return String(localized: "Status")
        }
    }

    /// Leading header label that automatically falls back to `categoryDisplayName` when the trailing
    /// solid pill already displays the exact same string (e.g. "已到达"), preventing duplicate copy.
    func leadingHeaderLabel(isStale: Bool, now: Date) -> String {
        let statusLabel = resolvedStatusLabel
        if !isStale,
           activeFutureETA(now: now) == nil,
           !prefersRingGauge,
           let compact = trimmed(state.compactLabel),
           compact.caseInsensitiveCompare(statusLabel) == .orderedSame {
            return categoryDisplayName
        }
        return statusLabel
    }

    /// Vibrant accent color tuned for pure black Dynamic Island & obsidian dark Lock Screen surfaces.
    var islandAccent: Color {
        accentColor(dark: true)
    }

    /// Accent color tuned for adaptive Lock Screen cards (high contrast in both Light and Dark modes).
    func surfaceAccent(for colorScheme: ColorScheme) -> Color {
        accentColor(dark: colorScheme == .dark)
    }

    /// High-contrast ink color for text/glyphs drawn directly on top of a solid-fill accent pill or bar.
    func pillInk(dark: Bool) -> Color {
        if !dark { return .white }
        if state.status == "cancelled" || state.status == "failed" { return .white }
        if state.status == "attention" || state.status == "done" { return Color(hex: 0x0B0C0E) }
        switch state.accent {
        case "brand", "red": return .white
        case "green", "amber", "blue", "neutral": return Color(hex: 0x0B0C0E)
        default:
            switch state.category {
            case "train", "timer", "progress": return .white
            default: return Color(hex: 0x0B0C0E)
            }
        }
    }

    private func accentColor(dark: Bool) -> Color {
        if state.status == "attention" {
            return dark ? Color(hex: 0xFBBF24) : Color(hex: 0xB45309)
        }
        if state.status == "done" {
            return dark ? Color(hex: 0x34D399) : Color(hex: 0x059669)
        }
        if state.status == "cancelled" || state.status == "failed" {
            return dark ? Color(hex: 0xF87171) : Color(hex: 0xDC2626)
        }
        switch state.accent {
        case "brand": return dark ? Color(hex: 0x3B82F6) : Color(hex: 0x205BFF)
        case "green": return dark ? Color(hex: 0x34D399) : Color(hex: 0x059669)
        case "amber": return dark ? Color(hex: 0xFBBF24) : Color(hex: 0xB45309)
        case "blue": return dark ? Color(hex: 0x38BDF8) : Color(hex: 0x0284C7)
        case "red": return dark ? Color(hex: 0xF87171) : Color(hex: 0xDC2626)
        case "neutral": return dark ? Color(hex: 0xD1D5DB) : Color(hex: 0x4A4C50)
        default:
            switch state.category {
            case "car": return dark ? Color(hex: 0x34D399) : Color(hex: 0x059669)
            case "delivery": return dark ? Color(hex: 0xFB923C) : Color(hex: 0xC2410C)
            case "flight": return dark ? Color(hex: 0x38BDF8) : Color(hex: 0x0284C7)
            case "train": return dark ? Color(hex: 0x3B82F6) : Color(hex: 0x205BFF)
            case "transit": return dark ? Color(hex: 0x2DD4BF) : Color(hex: 0x0F766E)
            case "package": return dark ? Color(hex: 0xF59E0B) : Color(hex: 0xB45309)
            case "order": return dark ? Color(hex: 0xFBBF24) : Color(hex: 0xB45309)
            case "timer": return dark ? Color(hex: 0x3B82F6) : Color(hex: 0x205BFF)
            default: return dark ? Color(hex: 0x3B82F6) : Color(hex: 0x205BFF)
            }
        }
    }

    func activeFutureETA(now: Date) -> Date? {
        guard !state.isTerminal, let eta = state.etaDate, eta > now else { return nil }
        return eta
    }

    /// Returns `compactLabel` only when it adds a distinct code alongside an active ETA countdown
    /// (e.g. gate `B12`), suppressing redundant time strings such as `3分钟` or `12m`.
    func distinctBadgeAlongsideETA() -> String? {
        guard let label = trimmed(state.compactLabel) else { return nil }
        let lower = label.lowercased()
        let timeSuffixes = ["分钟", "分", "秒", "小时", "min", "mins", "m", "sec", "s", "hr", "h"]
        if lower.contains(":") { return nil }
        for suffix in timeSuffixes {
            if lower.hasSuffix(suffix) {
                let prefix = lower.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty && prefix.allSatisfy({ $0.isNumber || $0 == "." }) {
                    return nil
                }
            }
        }
        return label
    }

    var prefersRingGauge: Bool {
        !state.hasSegmentedSteps && state.clampedProgress != nil
    }

    /// Whether `LiveStatusHeroTrailing` draws the ring gauge for this state.
    func heroShowsRing(isStale: Bool, now: Date) -> Bool {
        guard !isStale, activeFutureETA(now: now) == nil, state.clampedProgress != nil else { return false }
        return prefersRingGauge || trimmed(state.compactLabel) == nil
    }

    /// The progress track repeats the ring's value for continuous progress, so it is shown only when the
    /// hero does not already show that value (HIG: show only the information people need at a glance).
    func showsProgressTrack(isStale: Bool, now: Date) -> Bool {
        guard state.hasProgressIndicator else { return false }
        return state.hasSegmentedSteps || !heroShowsRing(isStale: isStale, now: now)
    }

    /// The subtitle, unless a progress track and the detail dock are both shown: then the title alone keeps the
    /// presentation inside the 160 pt height limit of the expanded and Lock Screen presentations.
    func visibleSubtitle(showsTrack: Bool) -> String? {
        if showsTrack && state.hasFooterDetails { return nil }
        return trimmed(state.subtitle)
    }

    func trimmed(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Countdown / Metric Helpers

/// Renders a live native countdown (`Text(timerInterval:countsDown:)`) in production, and freezes cleanly
/// at `referenceDate` during deterministic snapshot verification.
///
/// In the widget extension a live countdown takes all the width it is offered and has no width of its own:
/// `fixedSize` on it gives an infinite width, which empties the Lock Screen card and ends an activity whose
/// presentation has a `GeometryReader`. So the width comes from hidden text as wide as the countdown can
/// be, and the countdown is drawn over it. A caller may then size this view to its content.
struct LiveStatusCountdownText: View {
    let targetDate: Date
    let referenceDate: Date?

    var body: some View {
        let start = referenceDate ?? Date()
        if let referenceDate {
            Text(timerInterval: referenceDate...targetDate, pauseTime: referenceDate, countsDown: true,
                 showsHours: targetDate.timeIntervalSince(referenceDate) >= 3600)
                .monospacedDigit()
        } else {
            let remaining = targetDate.timeIntervalSince(start)
            Text(verbatim: Self.widestText(remaining: remaining))
                .monospacedDigit()
                .hidden()
                .accessibilityHidden(true)
                .overlay(alignment: .trailing) {
                    Text(timerInterval: start...targetDate, countsDown: true, showsHours: remaining >= 3600)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
        }
    }

    /// The widest text the countdown shows from `remaining` seconds down to zero. Digits have one width.
    static func widestText(remaining: TimeInterval) -> String {
        if remaining >= 36_000 { return "00:00:00" }
        if remaining >= 3_600 { return "0:00:00" }
        if remaining >= 600 { return "00:00" }
        return "0:00"
    }
}

/// Sleek circular ring gauge for continuous progress states (inspired by native Apple activity rings).
struct LiveStatusRingGauge: View {
    let progress: Double
    let accent: Color
    let dark: Bool
    var size: CGFloat = 42
    var lineWidth: CGFloat = 4

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        let pct = Int((clamped * 100).rounded())
        ZStack {
            Circle()
                .stroke(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    accent,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(pct)%")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(dark ? Color.white : Color.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: size, height: size)
        .accessibilityValue("\(pct)%")
    }
}

/// Tactile leading status header: vibrant category glyph (with glowing halo ring on attention) + crisp label.
private struct LiveStatusLeadingHeader: View {
    let style: LiveStatusVisualStyle
    let accent: Color
    let dark: Bool
    let isStale: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            if style.state.needsAttention {
                ZStack {
                    Circle()
                        .fill(accent.opacity(dark ? 0.16 : 0.12))
                        .frame(width: 30, height: 30)
                    Circle()
                        .fill(accent.opacity(dark ? 0.28 : 0.20))
                        .frame(width: 22, height: 22)
                    Image(systemName: style.symbolName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(accent)
                }
            } else {
                Image(systemName: style.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(style.leadingHeaderLabel(isStale: isStale, now: now))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    style.state.needsAttention
                        ? accent
                        : (dark ? Color.white.opacity(0.80) : Color.secondary)
                )
                .lineLimit(1)
        }
    }
}

/// Hero trailing instrument: massive tabular countdown, circular ring gauge, or vivid solid-fill accent pill.
private struct LiveStatusHeroTrailing: View {
    let style: LiveStatusVisualStyle
    let accent: Color
    let isStale: Bool
    let dark: Bool
    let referenceDate: Date?
    var ringSize: CGFloat = 42

    var body: some View {
        let now = referenceDate ?? Date()
        if isStale {
            Label("Last known state", systemImage: "clock")
                .labelStyle(.iconOnly)
                .font(.subheadline)
                .foregroundStyle(dark ? Color.white.opacity(0.60) : Color.secondary)
        } else if let eta = style.activeFutureETA(now: now) {
            HStack(alignment: .center, spacing: 6) {
                if let badge = style.distinctBadgeAlongsideETA() {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(accent.opacity(dark ? 0.20 : 0.14), in: Capsule())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                LiveStatusCountdownText(targetDate: eta, referenceDate: referenceDate)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(style.state.needsAttention ? accent : (dark ? Color.white : Color.primary))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        } else if style.prefersRingGauge, let progress = style.state.clampedProgress {
            LiveStatusRingGauge(progress: progress, accent: accent, dark: dark, size: ringSize)
        } else if let label = style.trimmed(style.state.compactLabel) {
            Text(label)
                .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(style.pillInk(dark: dark))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(accent, in: Capsule())
                .shadow(color: accent.opacity(dark ? 0.34 : 0.18), radius: 8, x: 0, y: 2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else if let progress = style.state.clampedProgress {
            LiveStatusRingGauge(progress: progress, accent: accent, dark: dark, size: ringSize)
        }
    }
}

/// Recessed bottom detail dock (subtle rounded surface, zero divider lines).
private struct LiveStatusDetailDock: View {
    let style: LiveStatusVisualStyle
    let dark: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let left = style.trimmed(style.state.detailLeft) {
                Text(left)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(dark ? Color.white.opacity(0.68) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let right = style.trimmed(style.state.detailRight) {
                Text(right)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.88))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(dark ? Color.white.opacity(0.07) : Color.black.opacity(0.045))
        )
    }
}

// MARK: - Tactile Progress & Bar Meter

struct LiveStatusProgressTrack: View {
    let state: LiveStatusAttributes.ContentState
    let accent: Color
    let dark: Bool

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        if let total = state.stepTotal, (2...8).contains(total), let current = state.stepCurrent {
            chunkyStepPillBar(style: style, filled: min(max(current, 0), total), total: total)
        } else if let progress = state.clampedProgress {
            verticalPillMeter(progress: progress)
        }
    }

    private func chunkyStepPillBar(style: LiveStatusVisualStyle, filled: Int, total: Int) -> some View {
        let railHeight: CGFloat = 22
        let ink = style.pillInk(dark: dark)
        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let ratio = total > 0 ? CGFloat(filled) / CGFloat(total) : 0
            let minFill: CGFloat = min(width, 64)
            let fillWidth = filled >= total ? width : max(minFill, min(width - 20, width * ratio))
            let remaining = max(0, total - filled)

            ZStack(alignment: .leading) {
                // Recessed capsule rail
                Capsule()
                    .fill(dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                    .frame(height: railHeight)

                // Milestone dots in remaining unfilled track
                if remaining > 0 {
                    let remainingWidth = max(0, width - fillWidth)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(0..<remaining, id: \.self) { _ in
                            Circle()
                                .fill(dark ? Color.white.opacity(0.26) : Color.black.opacity(0.18))
                                .frame(width: 5, height: 5)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(width: remainingWidth, height: railHeight)
                    .offset(x: fillWidth)
                }

                // Solid vibrant filled pill: step ratio on left, moving category glyph at leading tip
                ZStack {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.86)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: accent.opacity(dark ? 0.28 : 0.16), radius: 6, x: 0, y: 1)
                    HStack(spacing: 4) {
                        Text("\(filled)/\(total)")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(ink.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: filled >= total ? "checkmark.circle.fill" : style.symbolName)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(ink)
                    }
                    .padding(.horizontal, 10)
                }
                .frame(width: fillWidth, height: railHeight)
            }
            .frame(height: railHeight)
        }
        .frame(height: railHeight)
        .accessibilityLabel("\(filled) of \(total)")
    }

    private func verticalPillMeter(progress: Double) -> some View {
        let barCount = 26
        let litCount = max(1, min(barCount, Int((progress * Double(barCount)).rounded())))
        return HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                let isLit = index < litCount
                let isLeading = index == litCount - 1
                let fraction = Double(index + 1) / Double(max(litCount, 1))
                let barFill: Color = {
                    if !isLit {
                        return dark ? Color.white.opacity(0.12) : Color.black.opacity(0.09)
                    }
                    if isLeading {
                        return accent
                    }
                    return accent.opacity(0.62 + 0.34 * fraction)
                }()
                Capsule()
                    .fill(barFill)
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                    .shadow(color: isLeading ? accent.opacity(dark ? 0.45 : 0.22) : .clear, radius: 4, x: 0, y: 0)
            }
        }
        .frame(height: 20)
        .accessibilityValue("\(Int((progress * 100).rounded()))%")
    }
}

// MARK: - Dynamic Island Compact & Minimal

struct LiveStatusCompactLeadingView: View {
    let state: LiveStatusAttributes.ContentState

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        DynamicIslandCompactSymbol(systemName: style.symbolName, maxSize: 13, weight: .semibold)
            .foregroundStyle(style.islandAccent)
            .accessibilityHidden(true)
    }
}

struct LiveStatusCompactTrailingView: View {
    let state: LiveStatusAttributes.ContentState
    let isStale: Bool
    var referenceDate: Date? = nil

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        let now = referenceDate ?? Date()
        Group {
            if isStale {
                DynamicIslandCompactSymbol(systemName: "clock", maxSize: 12, weight: .medium)
                    .foregroundStyle(.secondary)
            } else if let eta = style.activeFutureETA(now: now) {
                LiveStatusCountdownText(targetDate: eta, referenceDate: referenceDate)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(style.islandAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 52, alignment: .trailing)
            } else if let label = style.trimmed(state.compactLabel) {
                Text(label)
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(style.islandAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: 56, alignment: .trailing)
            } else if let progress = state.clampedProgress {
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(style.islandAccent)
                    .lineLimit(1)
                    .frame(maxWidth: 44, alignment: .trailing)
            } else {
                DynamicIslandCompactMark()
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }
}

struct LiveStatusMinimalView: View {
    let state: LiveStatusAttributes.ContentState

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        DynamicIslandCompactSymbol(systemName: style.symbolName, maxSize: 13, weight: .semibold)
            .foregroundStyle(style.islandAccent)
            .accessibilityHidden(true)
    }
}

// MARK: - Dynamic Island Expanded Regions

struct LiveStatusExpandedLeadingView: View {
    let state: LiveStatusAttributes.ContentState
    var isStale: Bool = false
    var referenceDate: Date? = nil

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        LiveStatusLeadingHeader(
            style: style,
            accent: style.islandAccent,
            dark: true,
            isStale: isStale,
            now: referenceDate ?? Date()
        )
        .frame(minHeight: LiveStatusIslandMetrics.headerHeight)
        .padding(.leading, LiveStatusIslandMetrics.inset)
        .padding(.top, LiveStatusIslandMetrics.headerTop)
    }
}

struct LiveStatusExpandedTrailingView: View {
    let state: LiveStatusAttributes.ContentState
    let isStale: Bool
    var referenceDate: Date? = nil

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        LiveStatusHeroTrailing(
            style: style,
            accent: style.islandAccent,
            isStale: isStale,
            dark: true,
            referenceDate: referenceDate,
            ringSize: LiveStatusIslandMetrics.headerHeight
        )
        .frame(minHeight: LiveStatusIslandMetrics.headerHeight)
        .padding(.trailing, LiveStatusIslandMetrics.inset)
        .padding(.top, LiveStatusIslandMetrics.headerTop)
    }
}

/// Shared expanded Dynamic Island metrics: the leading and trailing regions use one header height and one
/// top inset so their content centres on one line, and every region uses one side inset so content stays
/// concentric with the island's corners.
enum LiveStatusIslandMetrics {
    static let headerHeight: CGFloat = 34
    static let headerTop: CGFloat = 6
    static let inset: CGFloat = 10
    static let stackSpacing: CGFloat = 8
}

struct LiveStatusExpandedBottomView: View {
    let state: LiveStatusAttributes.ContentState
    var isStale: Bool = false
    var referenceDate: Date? = nil

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        let showsTrack = style.showsProgressTrack(isStale: isStale, now: referenceDate ?? Date())
        let subtitle = style.visibleSubtitle(showsTrack: showsTrack)
        let dense = showsTrack && state.hasFooterDetails
        VStack(alignment: .leading, spacing: LiveStatusIslandMetrics.stackSpacing) {
            VStack(alignment: .leading, spacing: 2.5) {
                Text(state.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(dense || subtitle != nil ? 1 : 2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(1)
                }
            }
            if showsTrack {
                LiveStatusProgressTrack(
                    state: state,
                    accent: style.islandAccent,
                    dark: true
                )
            }
            if state.hasFooterDetails {
                LiveStatusDetailDock(style: style, dark: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.horizontal, LiveStatusIslandMetrics.inset)
        .padding(.bottom, LiveStatusIslandMetrics.inset)
    }
}

// MARK: - Lock Screen Card

struct LiveStatusCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: LiveStatusAttributes.ContentState
    let isStale: Bool
    var referenceDate: Date? = nil

    var body: some View {
        let dark = colorScheme == .dark
        let style = LiveStatusVisualStyle(state: state)
        let accent = style.surfaceAccent(for: colorScheme)
        let now = referenceDate ?? Date()
        let showsTrack = style.showsProgressTrack(isStale: isStale, now: now)
        let subtitle = style.visibleSubtitle(showsTrack: showsTrack)
        let dense = showsTrack && state.hasFooterDetails

        VStack(alignment: .leading, spacing: LiveStatusIslandMetrics.stackSpacing) {
            HStack(alignment: .center, spacing: 10) {
                LiveStatusLeadingHeader(style: style, accent: accent, dark: dark, isStale: isStale, now: now)
                Spacer(minLength: 8)
                LiveStatusHeroTrailing(
                    style: style,
                    accent: accent,
                    isStale: isStale,
                    dark: dark,
                    referenceDate: referenceDate,
                    ringSize: LiveStatusIslandMetrics.headerHeight
                )
            }
            .frame(minHeight: LiveStatusIslandMetrics.headerHeight)

            VStack(alignment: .leading, spacing: 2.5) {
                Text(state.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(dark ? Color.white : Color.primary)
                    .lineLimit(dense || subtitle != nil ? 1 : 2)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(dark ? Color.white.opacity(0.66) : Color.secondary)
                        .lineLimit(1)
                }
            }

            if showsTrack {
                LiveStatusProgressTrack(
                    state: state,
                    accent: accent,
                    dark: dark
                )
            }

            if state.hasFooterDetails {
                LiveStatusDetailDock(style: style, dark: dark)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(dark ? Color.white : Color.primary)
        .background(
            RadialGradient(
                colors: [
                    accent.opacity(dark ? 0.14 : 0.08),
                    accent.opacity(dark ? 0.03 : 0.015),
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 210
            )
        )
    }
}

// MARK: - Small Family (Apple Watch Smart Stack & CarPlay)

struct LiveStatusSmallCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: LiveStatusAttributes.ContentState
    let isStale: Bool
    var referenceDate: Date? = nil

    var body: some View {
        let style = LiveStatusVisualStyle(state: state)
        let accent = style.surfaceAccent(for: colorScheme)
        let now = referenceDate ?? Date()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: style.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(style.leadingHeaderLabel(isStale: isStale, now: now))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.needsAttention ? accent : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isStale {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let eta = style.activeFutureETA(now: now) {
                    LiveStatusCountdownText(targetDate: eta, referenceDate: referenceDate)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if let label = style.trimmed(state.compactLabel) {
                    Text(label)
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else if let progress = state.clampedProgress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(state.title)
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            if let subtitle = style.trimmed(state.subtitle) {
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - Dynamic Island Frame Wrappers (for Previews & Snapshot Verification)

/// Composes the exact production Expanded Dynamic Island region views inside a pure `#000000`
/// obsidian hardware shell with subtle ambient radial glow (zero wireframe border).
struct LiveStatusExpandedIslandPreview: View {
    let state: LiveStatusAttributes.ContentState
    var isStale: Bool = false
    var referenceDate: Date? = nil

    var body: some View {
        let accent = LiveStatusVisualStyle(state: state).islandAccent
        let shape = RoundedRectangle(cornerRadius: 44, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                LiveStatusExpandedLeadingView(state: state, isStale: isStale, referenceDate: referenceDate)
                Spacer(minLength: 8)
                LiveStatusExpandedTrailingView(state: state, isStale: isStale, referenceDate: referenceDate)
            }
            LiveStatusExpandedBottomView(state: state, isStale: isStale, referenceDate: referenceDate)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: 368)
        .background {
            ZStack {
                Color.black
                RadialGradient(
                    colors: [accent.opacity(0.18), accent.opacity(0.04), .clear],
                    center: .topTrailing,
                    startRadius: 12,
                    endRadius: 230
                )
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.32), radius: 24, x: 0, y: 12)
        .environment(\.colorScheme, .dark)
    }
}

/// Composes the exact production Compact Dynamic Island leading/trailing views inside a pure `#000000`
/// pill framed by an authentic iOS status bar strip.
struct LiveStatusCompactIslandPreview: View {
    let state: LiveStatusAttributes.ContentState
    var isStale: Bool = false
    var referenceDate: Date? = nil

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                Text("9:41")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Image(systemName: "location.fill")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(Color(hex: 0x111214))

            HStack(spacing: 0) {
                LiveStatusCompactLeadingView(state: state)
                    .frame(minWidth: 26, alignment: .leading)
                Spacer(minLength: 74)
                LiveStatusCompactTrailingView(state: state, isStale: isStale, referenceDate: referenceDate)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(minWidth: 196, maxWidth: 220)
            .background(Color.black, in: Capsule())
            .environment(\.colorScheme, .dark)

            HStack(spacing: 5) {
                Image(systemName: "wifi")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "battery.75percent")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color(hex: 0x111214))
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(Color.white.opacity(0.76), in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}
#endif
