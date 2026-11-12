import ImageIO
import UIKit
import XCTest
@testable import Comma

/// A moving GIF goes up as a moving WebP: the server keeps no GIF.
final class AvatarImageTests: XCTestCase {
    /// A 40 px GIF of three frames: red for 100 ms, blue for 200 ms, green for 300 ms.
    private static let movingGIF = Data(base64Encoded:
        "R0lGODlhKAAoAPcAAAAA/wD/AP8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQFCgD/ACwAAAAAKAAoAAAIQwAFCBxI" +
        "sKDBgwgTKlzIsKHDhxAjSpxIsaLFixgzatzIsaPHjyBDihxJsqTJkyhTqlzJsqXLlzBjypxJs6bNmzgJBgQAIfkEBRQA/wAsAAAA" +
        "ACgAKAAACEMAAQgcSLCgwYMIEypcyLChw4cQI0qcSLGixYsYM2rcyLGjx48gQ4ocSbKkyZMoU6pcybKly5cwY8qcSbOmzZs4CQYE" +
        "ACH5BAUeAP8ALAAAAAAoACgAAAhDAAMIHEiwoMGDCBMqXMiwocOHECNKnEixosWLGDNq3Mixo8ePIEOKHEmypMmTKFOqXMmypcuX" +
        "MGPKnEmzps2bOAkGBAA7")!

    func testAMovingGIFBecomesACroppedMovingWebP() async throws {
        let image = try await AvatarImage.load(Self.movingGIF)
        XCTAssertTrue(AvatarImage.isMovingGIF(Self.movingGIF))

        let webp = try await AvatarImage.webp(fromGIF: Self.movingGIF, image: image,
                                              crop: CGRect(x: 5, y: 5, width: 30, height: 30))

        XCTAssertEqual(String(decoding: webp[8..<12], as: UTF8.self), "WEBP")
        XCTAssertTrue(AvatarImage.isMoving(webp))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(webp as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
        for (index, seconds) in [0.1, 0.2, 0.3].enumerated() {
            XCTAssertEqual(AvatarImage.delay(source, index), seconds, accuracy: 0.001)
        }
        let colours = try (0..<3).map { index in try centre(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))) }
        XCTAssertEqual(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)).width, 96)
        for (colour, expected) in zip(colours, [[255, 0, 0], [0, 0, 255], [0, 255, 0]]) {
            XCTAssertTrue(zip(colour, expected).allSatisfy { abs($0 - $1) < 24 }, "\(colours)")
        }
    }

    /// The red, green and blue of the middle pixel.
    private func centre(_ image: CGImage) -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -CGFloat(image.width / 2), y: -CGFloat(image.height / 2),
                                           width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return pixel.prefix(3).map(Int.init)
    }
}
