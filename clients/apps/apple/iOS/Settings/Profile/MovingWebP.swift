import CoreGraphics
import Foundation
import libwebp

/// Frames written as one animated WebP with libwebp, which ImageIO cannot write.
enum MovingWebP {
    /// `frames`, each drawn into a `side`-pixel square, as one WebP that loops for ever, at `quality` (0 to 100).
    static func encode(_ frames: [(image: CGImage, delay: Double)], side: Int, quality: Float) -> Data? {
        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else { return nil }
        options.anim_params.loop_count = 0
        guard let encoder = WebPAnimEncoderNew(Int32(side), Int32(side), &options) else { return nil }
        defer { WebPAnimEncoderDelete(encoder) }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { return nil }
        config.quality = quality
        var milliseconds: Int32 = 0
        for frame in frames {
            guard let pixels = rgba(frame.image, side: side) else { return nil }
            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else { return nil }
            picture.width = Int32(side)
            picture.height = Int32(side)
            picture.use_argb = 1
            let added = pixels.withUnsafeBufferPointer { buffer in
                WebPPictureImportRGBA(&picture, buffer.baseAddress, Int32(side * 4)) != 0
                    && WebPAnimEncoderAdd(encoder, &picture, milliseconds, &config) != 0
            }
            WebPPictureFree(&picture)
            guard added else { return nil }
            milliseconds += Int32((frame.delay * 1000).rounded())
        }
        guard WebPAnimEncoderAdd(encoder, nil, milliseconds, nil) != 0 else { return nil }
        var data = WebPData()
        WebPDataInit(&data)
        defer { WebPDataClear(&data) }
        guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else { return nil }
        return Data(bytes: bytes, count: data.size)
    }

    /// `image` drawn into a `side`-pixel square as RGBA with straight alpha, which libwebp takes; clear where it is clear.
    private static func rgba(_ image: CGImage, side: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Core Graphics draws premultiplied colour.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in index..<index + 3 {
                pixels[channel] = UInt8(min(255, (Int(pixels[channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return pixels
    }
}
