import CoreGraphics
import Foundation

/// Slot of a card in the collapsed fan-stack deck, 1:1 with `ChatPanelImageGroupStackSlot`.
enum ChatMediaImageGroupSlot: String, Equatable, Sendable {
    case front = "0"
    case r1
    case r2
    case l1
    case l2
    case hiddenRight = "hidden-right"
    case hiddenLeft = "hidden-left"

    var isVisible: Bool {
        self != .hiddenRight && self != .hiddenLeft
    }

    /// Paint-order depth from back (0) to front (3), matching `stackDepthForSlot`.
    var stackDepth: Int {
        switch self {
        case .front: 3
        case .r1, .l1: 2
        case .r2, .l2: 1
        case .hiddenRight, .hiddenLeft: 0
        }
    }

    var geometry: ChatMediaImageGroupSlotGeometry {
        let shift = CommaTheme.imageGroupStackShiftStep
        let rot = CommaTheme.imageGroupStackRotationStep
        let scaleStep = CommaTheme.imageGroupStackScaleStep
        switch self {
        case .front:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 5,
                translateX: 0,
                rotationDegrees: 0,
                scale: 1.0,
                dimOpacity: 0,
                opacity: 1.0,
                stackDepth: 3
            )
        case .r1:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 4,
                translateX: shift,
                rotationDegrees: rot,
                scale: 1.0 - scaleStep,
                dimOpacity: 0.08,
                opacity: 1.0,
                stackDepth: 2
            )
        case .l1:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 4,
                translateX: -shift,
                rotationDegrees: -rot,
                scale: 1.0 - scaleStep,
                dimOpacity: 0.08,
                opacity: 1.0,
                stackDepth: 2
            )
        case .r2:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 3,
                translateX: shift * 2,
                rotationDegrees: rot * 2,
                scale: 1.0 - scaleStep * 2,
                dimOpacity: 0.16,
                opacity: 1.0,
                stackDepth: 1
            )
        case .l2:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 3,
                translateX: -shift * 2,
                rotationDegrees: -rot * 2,
                scale: 1.0 - scaleStep * 2,
                dimOpacity: 0.16,
                opacity: 1.0,
                stackDepth: 1
            )
        case .hiddenRight:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 0,
                translateX: shift * 2,
                rotationDegrees: rot * 2,
                scale: 1.0 - scaleStep * 2,
                dimOpacity: 0.16,
                opacity: 0,
                stackDepth: 0
            )
        case .hiddenLeft:
            return ChatMediaImageGroupSlotGeometry(
                zIndex: 0,
                translateX: -shift * 2,
                rotationDegrees: -rot * 2,
                scale: 1.0 - scaleStep * 2,
                dimOpacity: 0.16,
                opacity: 0,
                stackDepth: 0
            )
        }
    }
}

struct ChatMediaImageGroupSlotGeometry: Equatable, Sendable {
    let zIndex: Double
    let translateX: CGFloat
    let rotationDegrees: Double
    let scale: CGFloat
    let dimOpacity: Double
    let opacity: Double
    let stackDepth: Int
}

/// Cyclic two-pile browse state machine, 1:1 with `imageGroupBrowseReducer` and `stackSlotForDistance`.
struct ChatMediaImageGroupBrowseState: Equatable, Sendable {
    var frontIndex: Int = 0
    var leftCount: Int = 0

    static func normalizedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index % count) + count) % count
    }

    func normalizedFront(count: Int) -> Int {
        Self.normalizedIndex(frontIndex, count: count)
    }

    func clampedLeftCount(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(leftCount, 0), count - 1)
    }

    /// `step == +1` throws the front card onto the left history pile and reveals the next image.
    /// `step == -1` returns the front card onto the right pile and brings the previous image back.
    mutating func rotate(step: Int, count: Int) {
        guard count > 0 else {
            frontIndex = 0
            leftCount = 0
            return
        }
        let direction = step >= 0 ? 1 : -1
        let clampedLeft = min(max(leftCount, 0), count - 1)
        frontIndex = Self.normalizedIndex(frontIndex + direction, count: count)
        leftCount = direction == 1
            ? min(clampedLeft + 1, count - 1)
            : max(clampedLeft - 1, 0)
    }

    /// Aligns the deck with a chosen preview image, preserving `leftCount` if already at that card.
    mutating func alignPreview(index: Int, count: Int) {
        guard count > 0 else {
            frontIndex = 0
            leftCount = 0
            return
        }
        let clamped = min(max(index, 0), count - 1)
        if Self.normalizedIndex(frontIndex, count: count) == clamped {
            frontIndex = clamped
            leftCount = min(max(leftCount, 0), count - 1)
            return
        }
        frontIndex = clamped
        leftCount = clamped
    }

    /// Clamped linear navigation inside the full-screen viewer.
    mutating func navigatePreview(step: Int, count: Int) {
        guard count > 0 else {
            frontIndex = 0
            leftCount = 0
            return
        }
        let current = Self.normalizedIndex(frontIndex, count: count)
        let next = min(max(current + step, 0), count - 1)
        frontIndex = next
        leftCount = next
    }

    func slot(for index: Int, count: Int) -> ChatMediaImageGroupSlot {
        guard count > 0 else { return .hiddenRight }
        let front = Self.normalizedIndex(frontIndex, count: count)
        let distance = (((index - front) % count) + count) % count
        if distance == 0 { return .front }
        let rightSpan = count - 1 - min(max(leftCount, 0), count - 1)
        if distance <= rightSpan {
            if distance == 1 { return .r1 }
            if distance == 2 { return .r2 }
            return .hiddenRight
        }
        let leftDepth = count - distance
        if leftDepth == 1 { return .l1 }
        if leftDepth == 2 { return .l2 }
        return .hiddenLeft
    }

    /// Depth-ordered cascade delay: expanding leads with the front card (`12ms`/layer),
    /// collapsing tucks deepest cards in first (`8ms`/layer).
    func staggerDelay(for index: Int, count: Int, expanding: Bool) -> Double {
        let depth = slot(for: index, count: count).stackDepth
        let maxOrder = ChatMediaImageGroupSlot.front.stackDepth
        let order = maxOrder - depth
        if expanding {
            return Double(order) * CommaTheme.imageGroupExpandStagger
        } else {
            return Double(maxOrder - order) * CommaTheme.imageGroupCollapseStagger
        }
    }
}

/// Pure geometry calculations for single image, collapsed fan stack, and expanded wrapping grid.
enum ChatMediaImageGroupLayout {
    static let wideLayoutThreshold: CGFloat = 520
    static let flightApexWidthFactor: CGFloat = 0.7
    static let flightApexRotationDegrees: Double = 9.0
    static let flightApexScale: CGFloat = 0.96
    static let flightApexOffset: Double = 0.4
    static let flightLayerSwapOffset: Double = 0.6

    static func isStackable(count: Int) -> Bool {
        count > CommaTheme.imageGroupStackThreshold
    }

    static func singleMaxWidth(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return CommaTheme.imageGroupSingleMaxWidth }
        return min(floor(availableWidth * 0.75), CommaTheme.imageGroupSingleMaxWidth)
    }

    /// Preserves the image's natural aspect ratio inside `(singleMaxWidth, 320pt)`.
    /// Falls back to `4:3` when dimensions are missing so height never jumps before decode.
    static func singleSize(aspectWidth: CGFloat?, aspectHeight: CGFloat?, availableWidth: CGFloat) -> CGSize {
        let maxW = max(singleMaxWidth(availableWidth: availableWidth), 1)
        let maxH = CommaTheme.imageGroupSingleMaxHeight
        let ratio: CGFloat
        if let w = aspectWidth, let h = aspectHeight, w > 0, h > 0 {
            ratio = w / h
        } else {
            ratio = 4.0 / 3.0
        }
        if ratio >= maxW / maxH {
            return CGSize(width: maxW, height: max(1, round(maxW / ratio)))
        } else {
            return CGSize(width: max(1, round(maxH * ratio)), height: maxH)
        }
    }

    /// Card size for `2...3` images or `4+` expanded images (`3:4` portrait ratio).
    static func expandedCardSize(count: Int, availableWidth: CGFloat) -> CGSize {
        let gap = CommaTheme.imageGroupCardGap
        let width: CGFloat
        if availableWidth <= 0 || availableWidth >= wideLayoutThreshold {
            width = CommaTheme.imageGroupCardWidth
        } else if count <= 2 {
            width = min(CommaTheme.imageGroupCardWidth, floor((availableWidth - gap) / 2))
        } else {
            width = min(CommaTheme.imageGroupCardWidth, floor((availableWidth - gap * 2) / 3))
        }
        let clampedWidth = max(width, 60)
        return CGSize(width: clampedWidth, height: round(clampedWidth * 4.0 / 3.0))
    }

    static func expandedColumns(count: Int, availableWidth: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let gap = CommaTheme.imageGroupCardGap
        if availableWidth <= 0 || availableWidth >= wideLayoutThreshold {
            let effectiveWidth = availableWidth > 0 ? availableWidth : CommaTheme.imageGroupCardWidth * CGFloat(min(count, 3)) + gap * CGFloat(max(min(count, 3) - 1, 0))
            let fit = Int(floor((effectiveWidth + gap) / (CommaTheme.imageGroupCardWidth + gap)))
            return max(1, min(count, fit))
        }
        if count <= 2 {
            return count
        }
        return 3
    }

    static func collapsedDeckCardSize() -> CGSize {
        let width = CommaTheme.imageGroupCardWidth
        return CGSize(width: width, height: round(width * 4.0 / 3.0))
    }

    static func collapsedDeckContainerSize() -> CGSize {
        let card = collapsedDeckCardSize()
        return CGSize(
            width: card.width + CommaTheme.imageGroupFanAllowanceHorizontal * 2,
            height: card.height + CommaTheme.imageGroupFanAllowanceVertical * 2
        )
    }

    /// Computes exact per-card frames in the expanded wrapping grid, aligned left (Agent) or right (User).
    static func expandedGrid(count: Int, availableWidth: CGFloat, isUser: Bool) -> (frames: [CGRect], containerSize: CGSize) {
        guard count > 0 else { return ([], .zero) }
        let card = expandedCardSize(count: count, availableWidth: availableWidth)
        let columns = expandedColumns(count: count, availableWidth: availableWidth)
        let gap = CommaTheme.imageGroupCardGap
        let rowCount = (count + columns - 1) / columns
        let maxColsInAnyRow = min(count, columns)
        let containerWidth = CGFloat(maxColsInAnyRow) * card.width + CGFloat(max(maxColsInAnyRow - 1, 0)) * gap
        let containerHeight = CGFloat(rowCount) * card.height + CGFloat(max(rowCount - 1, 0)) * gap

        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let row = index / columns
            let col = index % columns
            let itemsInRow = row == rowCount - 1 ? count - row * columns : columns
            let rowWidth = CGFloat(itemsInRow) * card.width + CGFloat(max(itemsInRow - 1, 0)) * gap
            let rowStartX = isUser ? (containerWidth - rowWidth) : 0
            let x = rowStartX + CGFloat(col) * (card.width + gap)
            let y = CGFloat(row) * (card.height + gap)
            frames.append(CGRect(x: x, y: y, width: card.width, height: card.height))
        }
        return (frames, CGSize(width: containerWidth, height: containerHeight))
    }
}
