import SwiftUI
import UIKit
import ImageIO
import CommaCore

/// The member's photo (a WebP or GIF moves), or their initials when there is no photo. Until a name is known it shows a person
/// glyph, so the avatar changes once, to the member, instead of passing through an email's or the app's
/// initial while the session and profile load.
struct UserAvatar: View {
    let store: CommaStore
    let size: CGFloat
    /// A name to take the initials from instead of the member's, such as one still being typed.
    var name: String?

    var body: some View {
        ZStack {
            if let data = store.avatarData, AvatarImage.isMoving(data) {
                MovingAvatarImage(data: data, side: size).transition(.opacity)
            } else if let data = store.avatarData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                CommaTheme.brandSolid
                if let initials {
                    // The initials fill a fixed circle, so they scale with it rather than with Dynamic Type.
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                        .transition(.opacity)
                } else {
                    CentralIcon("central-people", size: size * 0.55).foregroundStyle(.white.opacity(0.9))
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(CommaMotion.stateChange, value: initials)
        .animation(CommaMotion.stateChange, value: store.avatarData)
        .accessibilityHidden(true)
    }

    /// Up to two initials from the member's name; none while only an email is known.
    private var initials: String? {
        guard let name = name ?? store.memberName else { return nil }
        let letters = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        return letters.isEmpty ? nil : letters
    }
}

/// A WebP or GIF avatar that moves, filling its square. Its frames are decoded off the main actor at the size it shows; its
/// first frame shows until they are.
private struct MovingAvatarImage: UIViewRepresentable {
    let data: Data
    let side: CGFloat
    @Environment(\.displayScale) private var displayScale

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.data != data else { return }
        coordinator.data = data
        view.image = UIImage(data: data)
        let data = data, pixels = Int(side * displayScale)
        coordinator.decoding?.cancel()
        coordinator.decoding = Task { @MainActor in
            let image = await Task.detached(priority: .userInitiated) { Self.moving(data, maxPixels: pixels) }.value
            guard !Task.isCancelled, coordinator.data == data, let image else { return }
            view.image = image
        }
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.decoding?.cancel()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        var data: Data?
        var decoding: Task<Void, Never>?
    }

    /// The frames as one animated image. UIImage shows every frame for the same time, so each frame repeats
    /// for its own delay in units of the shortest one (at most 20 times).
    nonisolated private static func moving(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: max(maxPixels, 1)] as CFDictionary
        var frames: [(UIImage, Double)] = []
        for index in 0..<min(CGImageSourceGetCount(source), 300) {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { continue }
            frames.append((UIImage(cgImage: image), AvatarImage.delay(source, index)))
        }
        guard let unit = frames.map(\.1).min() else { return nil }
        let images = frames.flatMap { frame in Array(repeating: frame.0, count: min(20, max(1, Int((frame.1 / unit).rounded())))) }
        return UIImage.animatedImage(with: images, duration: Double(images.count) * unit)
    }
}
