import UIKit
import ImageIO
import CommaCore

/// The member's new photo on its way to their profile: decoded off the main actor at a size Move and Scale can
/// show, then cut to the chosen square as a JPEG under the server's limit. A GIF that moves is cut frame by frame and
/// goes up as a moving WebP.
enum AvatarImage {
    /// The longest side decoded for Move and Scale, which leaves room to zoom in on a 512-pixel avatar.
    private static let workingSide = 2048
    /// The avatar's side, in pixels.
    private static let side: CGFloat = 512

    /// The photo upright, at most `workingSide` pixels on its longer side, so a 48-megapixel photo never
    /// decodes whole.
    static func load(_ data: Data) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceShouldCacheImmediately: true,
                           kCGImageSourceThumbnailMaxPixelSize: workingSide] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw CommaError.invalidInput(String(localized: "That photo couldn’t be read."))
            }
            return UIImage(cgImage: image)
        }.value
    }

    /// A camera photo, upright and at the same working size as one from the library.
    static func load(_ photo: UIImage) async throws -> UIImage {
        let data = try await Task.detached(priority: .userInitiated) {
            guard let data = photo.jpegData(compressionQuality: 0.95) else {
                throw CommaError.invalidInput(String(localized: "That photo couldn’t be read."))
            }
            return data
        }.value
        return try await load(data)
    }

    /// `crop`, a square in `image`'s points, at most 512 pixels a side, as a JPEG under the server's limit.
    static func jpeg(from image: UIImage, crop: CGRect) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let target = max(1, min(side, crop.width * image.scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let bounds = CGRect(x: 0, y: 0, width: target, height: target)
            let rendered = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
                // A transparent photo sits on white rather than JPEG's black.
                UIColor.white.setFill()
                context.fill(bounds)
                let scale = target / crop.width
                image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                                      width: image.size.width * scale, height: image.size.height * scale))
            }
            for quality in [0.85, 0.7, 0.5] {
                if let jpeg = rendered.jpegData(compressionQuality: quality), jpeg.count <= UserProfile.maxAvatarBytes {
                    return jpeg
                }
            }
            throw CommaError.invalidInput(String(localized: "That photo is too large."))
        }.value
    }

    /// Sides a moving avatar is drawn at, largest first, until it fits.
    private static let movingSides: [CGFloat] = [256, 192, 128, 96]
    /// WebP qualities a moving avatar is encoded at, highest first.
    private static let movingQualities: [Float] = [80, 60]
    /// Frames read at most; a longer GIF keeps its first ones.
    private static let maxFrames = 300

    /// Whether `data` is a GIF of more than one frame.
    static func isMovingGIF(_ data: Data) -> Bool {
        data.starts(with: Array("GIF8".utf8)) && frameCount(data) > 1
    }

    /// Whether `data` is a GIF or WebP of more than one frame: an avatar that moves.
    static func isMoving(_ data: Data) -> Bool {
        let webp = data.count >= 12 && data.prefix(4) == Data("RIFF".utf8) && data[8..<12] == Data("WEBP".utf8)
        return (webp || data.starts(with: Array("GIF8".utf8))) && frameCount(data) > 1
    }

    private static func frameCount(_ data: Data) -> Int {
        CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
    }

    /// `crop`, a square in the points of `image` (the GIF's first frame as `load` decoded it), cut from every frame
    /// of the GIF `data` and written as a looping WebP under the server's limit, which keeps no GIF: smaller, at
    /// lower quality, then with fewer frames, until it fits.
    static func webp(fromGIF data: Data, image: UIImage, crop: CGRect) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CommaError.invalidInput(String(localized: "That photo couldn’t be read."))
            }
            let width = CGFloat(first.width), height = CGFloat(first.height)
            let scale = width / (image.size.width * image.scale)
            let pixels = CGRect(x: crop.minX * image.scale * scale, y: crop.minY * image.scale * scale,
                                width: crop.width * image.scale * scale, height: crop.height * image.scale * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let count = min(CGImageSourceGetCount(source), maxFrames)
            // ImageIO hands each frame of a GIF already composed over the ones before it.
            let frames = (0..<count).compactMap { index -> (image: CGImage, delay: Double)? in
                CGImageSourceCreateImageAtIndex(source, index, nil).flatMap { frame in
                    frame.cropping(to: pixels).map { ($0, delay(source, index)) }
                }
            }
            guard !frames.isEmpty else { throw CommaError.invalidInput(String(localized: "That photo couldn’t be read.")) }
            let sides = movingSides.filter { $0 <= pixels.width }
            for side in sides.isEmpty ? [movingSides.last!] : sides {
                for quality in movingQualities {
                    for step in 1...3 {
                        if let webp = MovingWebP.encode(everyNth(frames, step), side: Int(side), quality: quality),
                           webp.count <= UserProfile.maxAvatarBytes { return webp }
                    }
                }
            }
            throw CommaError.invalidInput(String(localized: "That photo is too large."))
        }.value
    }

    /// How long frame `index` shows, in seconds; under 0.02 s shows as 0.1 s, as browsers show it.
    static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double) ?? 0.1
        return seconds < 0.02 ? 0.1 : seconds
    }

    /// Every `step`th frame, each shown as long as the frames it stands for.
    private static func everyNth(_ frames: [(image: CGImage, delay: Double)], _ step: Int) -> [(image: CGImage, delay: Double)] {
        var kept: [(image: CGImage, delay: Double)] = []
        for (index, frame) in frames.enumerated() {
            if index % step == 0 || kept.isEmpty { kept.append(frame) } else { kept[kept.count - 1].delay += frame.delay }
        }
        return kept
    }
}
