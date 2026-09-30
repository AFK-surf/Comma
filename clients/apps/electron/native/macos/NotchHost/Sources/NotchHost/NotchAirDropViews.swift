import AppKit
import SwiftUI

/// One AirDrop transfer as the Notch draws it, with its preview decoded once.
struct CommaNotchAirDropPresentation {
    let transfer: CommaNotchScenePayloadAirDropTransfer
    /// The received image, which takes the status icon's place once added.
    let preview: NSImage?

    init(_ transfer: CommaNotchScenePayloadAirDropTransfer) {
        self.transfer = transfer
        preview = transfer.preview.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
    }

    var notificationToken: String {
        "airdrop:\(transfer.requestId):\(transfer.phase.rawValue)"
    }
}

private enum NotchAirDropMetrics {
    static let visualSize: CGFloat = 40
    static let cardPadding: CGFloat = 8
    static let contentTopInset: CGFloat = 10
    static let contentBottomInset: CGFloat = 16
    static let contentHorizontalPadding: CGFloat = 16

    static func expandedSurfaceSize(notchHeight: CGFloat = 31) -> CGSize {
        CGSize(
            width: 480,
            height: notchHeight + contentTopInset + visualSize + cardPadding * 2
                + contentBottomInset
        )
    }
}

/// Compact: the toast's status icon and title; the image once it was added.
struct CommaNotchAirDropLeadingSlotView: View {
    private static let visualSize: CGFloat = 20
    private static let spacing: CGFloat = 8
    private static let fontSize: CGFloat = 12

    let presentation: CommaNotchAirDropPresentation
    let availableWidth: CGFloat

    /// The slot's width for a title: at least `minimum`, and wide enough for a
    /// longer sentence, such as one counting several files, up to `maximum`.
    static func width(for title: String, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let system = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let font = system.fontDescriptor.withDesign(.rounded)
            .flatMap { NSFont(descriptor: $0, size: fontSize) } ?? system
        let text = (title as NSString).size(withAttributes: [.font: font]).width
        // A little slack for SwiftUI's own text layout.
        return min(max(ceil(text) + visualSize + spacing + 2, minimum), maximum)
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            CommaNotchAirDropVisual(presentation: presentation, iconSize: 15, cornerRadius: 5)
                .frame(width: Self.visualSize, height: Self.visualSize)
            Text(presentation.transfer.title)
                .font(.system(size: Self.fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: availableWidth, alignment: .leading)
    }
}

/// Expanded: the toast's status row and the offer's decision.
struct CommaNotchAirDropExpandedView: View {
    let presentation: CommaNotchAirDropPresentation
    let onDecide: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            CommaNotchAirDropVisual(presentation: presentation, iconSize: 20, cornerRadius: 10)
                .frame(
                    width: NotchAirDropMetrics.visualSize,
                    height: NotchAirDropMetrics.visualSize
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.transfer.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                if let subtitle = presentation.transfer.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let accept = presentation.transfer.acceptLabel,
               let decline = presentation.transfer.declineLabel
            {
                CommaNotchAirDropButton(title: decline, emphasized: false) { onDecide(false) }
                CommaNotchAirDropButton(title: accept, emphasized: true) { onDecide(true) }
            }
        }
        .padding(NotchAirDropMetrics.cardPadding)
        .padding(.trailing, 4)
        // The same solid card as a task row, so the glass never shows through.
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 31 / 255, green: 31 / 255, blue: 31 / 255))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
                .allowsHitTesting(false)
        }
        .padding(.top, NotchAirDropMetrics.contentTopInset)
        .padding(.bottom, NotchAirDropMetrics.contentBottomInset)
        .padding(.horizontal, NotchAirDropMetrics.contentHorizontalPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func expandedSurfaceSize() -> CGSize {
        NotchAirDropMetrics.expandedSurfaceSize()
    }
}

/// The status icon until the upload succeeds, then the received image.
private struct CommaNotchAirDropVisual: View {
    let presentation: CommaNotchAirDropPresentation
    let iconSize: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if presentation.transfer.phase == .completed, let preview = presentation.preview {
            GeometryReader { proxy in
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            CommaNotchAirDropStatusIcon(transfer: presentation.transfer, size: iconSize)
        }
    }
}

/// The toast's status icon for each phase.
private struct CommaNotchAirDropStatusIcon: View {
    let transfer: CommaNotchScenePayloadAirDropTransfer
    let size: CGFloat

    var body: some View {
        switch transfer.phase {
        case .offer:
            CommaNotchAirDropGlyph()
                .frame(width: size, height: size)
                .foregroundStyle(.white.opacity(0.9))
        case .receiving:
            CommaNotchAirDropProgressRing(fraction: transfer.progress)
                .frame(width: size, height: size)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.red)
        }
    }
}

/// Central Icons' `IconAirdrop` (24pt grid, 2pt round strokes): a center dot
/// inside two arcs that open toward the bottom.
private struct CommaNotchAirDropGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let unit = min(proxy.size.width, proxy.size.height) / 24
            let line = StrokeStyle(lineWidth: 2 * unit, lineCap: .round)
            ZStack {
                Circle()
                    .trim(from: 0, to: 292.5 / 360)
                    .stroke(style: line)
                    .rotationEffect(.degrees(123.75))
                    .frame(width: 18 * unit, height: 18 * unit)
                Circle()
                    .trim(from: 0, to: 286.26 / 360)
                    .stroke(style: line)
                    .rotationEffect(.degrees(126.87))
                    .frame(width: 10 * unit, height: 10 * unit)
                Circle()
                    .frame(width: 4 * unit, height: 4 * unit)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// Byte progress arrives about once a second and the ring eases between
/// readings; without a known size it spins like the toast's loading icon.
private struct CommaNotchAirDropProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: Double?
    @State private var spinning = false

    var body: some View {
        GeometryReader { proxy in
            let line = StrokeStyle(lineWidth: max(1.5, proxy.size.width * 0.15), lineCap: .round)
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.2), style: line)
                Circle()
                    .trim(from: 0, to: fraction ?? 0.28)
                    .stroke(.white.opacity(0.92), style: line)
                    .rotationEffect(.degrees(fraction == nil && spinning ? 270 : -90))
            }
            .padding(line.lineWidth / 2)
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.9), value: fraction)
        .onAppear {
            guard fraction == nil, !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
    }
}

private struct CommaNotchAirDropButton: View {
    let title: String
    let emphasized: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(emphasized ? .white.opacity(0.2) : .clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
