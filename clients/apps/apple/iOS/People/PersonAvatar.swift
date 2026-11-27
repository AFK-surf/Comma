import SwiftUI
import UIKit
import CommaCore

@MainActor private enum PersonAvatarCache {
    static let images: NSCache<NSString, UIImage> = {
        // Bounded by decoded size, not count: a photo may be large.
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
}

/// Another person's face: their photo where the core has one for them (`source`, a `files.read` source), else their
/// initials on a tint taken from their name, so the same person keeps one colour on every list.
struct PersonAvatar: View {
    let store: CommaStore
    let name: String
    var source: NSDictionary?
    let size: CGFloat
    @State private var image: UIImage?

    private var cacheKey: String? {
        guard let source = source as? [String: Any], !source.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: source, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            } else {
                tint
                if let initials {
                    // The initials fill a fixed circle, so they scale with it rather than with Dynamic Type.
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                } else {
                    CentralIcon("central-people", size: size * 0.55).foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(CommaMotion.stateChange, value: image)
        .accessibilityHidden(true)
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        guard let key = cacheKey, let source = source as? [String: Any] else { image = nil; return }
        if let cached = PersonAvatarCache.images.object(forKey: key as NSString) {
            image = cached
            return
        }
        guard let answer = try? await store.core.object("files.read", source),
              let data = CoreBytes.read(answer["bytes"]), let decoded = UIImage(data: data) else { return }
        let cost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale) * 4
        PersonAvatarCache.images.setObject(decoded, forKey: key as NSString, cost: cost)
        image = decoded
    }

    /// Up to two initials from the name; none for an address alone.
    private var initials: String? {
        let words = name.contains("@") ? [Substring(name.prefix(1))] : name.split(separator: " ").prefix(2).map { $0 }
        let letters = String(words.compactMap(\.first)).uppercased()
        return letters.isEmpty ? nil : letters
    }

    /// One of the design's avatar tints, the same for the same name.
    private var tint: Color {
        let tints = PersonAvatar.tints
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tints[sum % tints.count]
    }

    static let tints: [Color] = [CommaTheme.brandSolid, .indigo, .teal, .orange, .pink, .green, .purple]
}

/// Faces in a row, each over the one before, with a ring of the page's colour between them; past `max`, a count.
struct PersonAvatarStack: View {
    let store: CommaStore
    let people: [(name: String, source: NSDictionary?)]
    var size: CGFloat = 24
    var max = 4
    var ring = CommaTheme.bgPrimary

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(people.prefix(max).enumerated()), id: \.offset) { _, person in
                PersonAvatar(store: store, name: person.name, source: person.source, size: size)
                    .padding(1.5).background(ring, in: Circle())
            }
            if people.count > max {
                Text(verbatim: "+\(people.count - max)").font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(CommaTheme.textSecondary)
                    .frame(width: size, height: size).background(CommaTheme.bgTertiary, in: Circle())
                    .padding(1.5).background(ring, in: Circle())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ListFormatter.localizedString(byJoining: people.map(\.name))))
    }
}
