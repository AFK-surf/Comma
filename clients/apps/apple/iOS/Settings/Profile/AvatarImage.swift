import UIKit
import ImageIO
import CommaCore

/// The member's new photo on its way to their profile: decoded off the main actor at a size Move and Scale can
/// show, then cut to the chosen square as a JPEG under the server's limit.
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
}
