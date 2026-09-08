import ImageIO
import UIKit
import XCTest
@testable import AWSUploader

final class AWSImageCompressorTests: XCTestCase {
    func testCompressionLimitsLongSideAndProducesJPEG() async throws {
        let image = makeImage(size: CGSize(width: 3000, height: 1500), color: .red)
        let result = try await AWSImageCompressor().compress(image)

        XCTAssertEqual(result.pixelWidth, 2048)
        XCTAssertEqual(result.pixelHeight, 1024)
        XCTAssertEqual(result.contentType, "image/jpeg")
        XCTAssertEqual(result.fileExtension, "jpeg")
        XCTAssertFalse(result.data.isEmpty)
    }

    func testCompressionUsesWhiteBackgroundForTransparency() async throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 20, height: 20),
            format: format
        ).image { _ in }

        let result = try await AWSImageCompressor().compress(image)
        let output = try XCTUnwrap(UIImage(data: result.data))
        let color = try XCTUnwrap(
            pixelColor(image: output, xCoordinate: 10, yCoordinate: 10)
        )
        XCTAssertGreaterThan(color.red, 0.9)
        XCTAssertGreaterThan(color.green, 0.9)
        XCTAssertGreaterThan(color.blue, 0.9)
    }

    func testStrictOverflowThrows() async {
        let image = makeImage(size: CGSize(width: 64, height: 64), color: .blue)
        let options = AWSImageCompressionOptions(
            targetByteCount: 1,
            maximumLongSide: 64,
            minimumLongSide: 64,
            overflowBehavior: .fail
        )

        do {
            _ = try await AWSImageCompressor().compress(image, options: options)
            XCTFail("Expected strict overflow to throw")
        } catch let error as AWSImageCompressionError {
            guard case .targetByteCountNotReached = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixelColor(
        image: UIImage,
        xCoordinate: Int,
        yCoordinate: Int
    ) -> PixelComponents? {
        guard let cgImage = image.cgImage,
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }
        let offset = yCoordinate * cgImage.bytesPerRow
            + xCoordinate * cgImage.bitsPerPixel / 8
        guard offset + 2 < CFDataGetLength(data) else { return nil }
        return PixelComponents(
            red: CGFloat(bytes[offset]) / 255,
            green: CGFloat(bytes[offset + 1]) / 255,
            blue: CGFloat(bytes[offset + 2]) / 255
        )
    }

    private struct PixelComponents {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
    }
}
