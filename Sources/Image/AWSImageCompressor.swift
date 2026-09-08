import CoreGraphics
import Foundation
import ImageIO
import UIKit

public final class AWSImageCompressor {
    private let queue: DispatchQueue

    public init() {
        queue = DispatchQueue(
            label: "com.artspace.AWSUploader.image-compression",
            qos: .userInitiated
        )
    }

    public func compress(
        _ image: UIImage,
        options: AWSImageCompressionOptions = .default
    ) async throws -> AWSCompressedImage {
        let cancellation = AWSImageCompressionCancellation()
        return try await withTaskCancellationHandler {
            try await runOnCompressionQueue(cancellation: cancellation) {
                if let frames = image.images, frames.count > 1 {
                    throw AWSImageCompressionError.unsupportedAnimatedImage
                }
                return try Self.compressSynchronously(
                    image: image,
                    options: options,
                    cancellation: cancellation
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func compress(
        data: Data,
        options: AWSImageCompressionOptions = .default
    ) async throws -> AWSCompressedImage {
        guard !data.isEmpty else {
            throw AWSImageCompressionError.emptyData
        }
        let cancellation = AWSImageCompressionCancellation()
        return try await withTaskCancellationHandler {
            try await runOnCompressionQueue(cancellation: cancellation) {
                try options.validate()
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw AWSImageCompressionError.decodingFailed
                }
                let image = try Self.downsampledImage(
                    source: source,
                    maximumLongSide: options.maximumLongSide
                )
                return try Self.compressSynchronously(
                    image: image,
                    options: options,
                    cancellation: cancellation
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func compress(
        fileURL: URL,
        options: AWSImageCompressionOptions = .default
    ) async throws -> AWSCompressedImage {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AWSImageCompressionError.fileNotFound(fileURL)
        }
        let cancellation = AWSImageCompressionCancellation()
        return try await withTaskCancellationHandler {
            try await runOnCompressionQueue(cancellation: cancellation) {
                try options.validate()
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                    throw AWSImageCompressionError.decodingFailed
                }
                let image = try Self.downsampledImage(
                    source: source,
                    maximumLongSide: options.maximumLongSide
                )
                return try Self.compressSynchronously(
                    image: image,
                    options: options,
                    cancellation: cancellation
                )
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func runOnCompressionQueue(
        cancellation: AWSImageCompressionCancellation,
        operation: @escaping () throws -> AWSCompressedImage
    ) async throws -> AWSCompressedImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try cancellation.checkCancellation()
                    let result = try autoreleasepool(invoking: operation)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func downsampledImage(
        source: CGImageSource,
        maximumLongSide: Int
    ) throws -> UIImage {
        guard CGImageSourceGetCount(source) == 1 else {
            throw AWSImageCompressionError.unsupportedAnimatedImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maximumLongSide
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AWSImageCompressionError.decodingFailed
        }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    private static func compressSynchronously(
        image: UIImage,
        options: AWSImageCompressionOptions,
        cancellation: AWSImageCompressionCancellation
    ) throws -> AWSCompressedImage {
        try options.validate()
        try cancellation.checkCancellation()

        let sourceWidth = image.size.width * image.scale
        let sourceHeight = image.size.height * image.scale
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw AWSImageCompressionError.invalidPixelSize
        }

        let originalLongSide = max(sourceWidth, sourceHeight)
        var currentLongSide = min(Double(options.maximumLongSide), originalLongSide)

        while true {
            try cancellation.checkCancellation()
            let rendered = try autoreleasepool {
                try render(
                    image: image,
                    sourceSize: CGSize(width: sourceWidth, height: sourceHeight),
                    maximumLongSide: currentLongSide
                )
            }
            let encoded = try adaptiveJPEGData(
                image: rendered,
                options: options,
                cancellation: cancellation
            )
            let width = Int(rendered.size.width.rounded(.down))
            let height = Int(rendered.size.height.rounded(.down))
            let meetsTarget = encoded.data.count <= options.targetByteCount

            if meetsTarget || max(width, height) <= options.minimumLongSide {
                if !meetsTarget, options.overflowBehavior == .fail {
                    throw AWSImageCompressionError.targetByteCountNotReached(
                        actual: encoded.data.count,
                        target: options.targetByteCount
                    )
                }
                return AWSCompressedImage(
                    data: encoded.data,
                    pixelWidth: width,
                    pixelHeight: height,
                    compressionQuality: encoded.quality,
                    didMeetTargetByteCount: meetsTarget
                )
            }

            let reduced = floor(currentLongSide * options.dimensionReductionFactor)
            currentLongSide = max(Double(options.minimumLongSide), reduced)
        }
    }

    private static func render(
        image: UIImage,
        sourceSize: CGSize,
        maximumLongSide: Double
    ) throws -> UIImage {
        let scaleRatio = min(1, maximumLongSide / max(sourceSize.width, sourceSize.height))
        let targetSize = CGSize(
            width: max(1, floor(sourceSize.width * scaleRatio)),
            height: max(1, floor(sourceSize.height * scaleRatio))
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard rendered.size.width > 0, rendered.size.height > 0 else {
            throw AWSImageCompressionError.renderingFailed
        }
        return rendered
    }

    private static func adaptiveJPEGData(
        image: UIImage,
        options: AWSImageCompressionOptions,
        cancellation: AWSImageCompressionCancellation
    ) throws -> (data: Data, quality: Double) {
        try cancellation.checkCancellation()
        guard let initialData = autoreleasepool(invoking: {
            image.jpegData(compressionQuality: options.initialQuality)
        }) else {
            throw AWSImageCompressionError.encodingFailed
        }
        if initialData.count <= options.targetByteCount {
            return (initialData, options.initialQuality)
        }

        var lowerQuality = options.minimumQuality
        var upperQuality = options.initialQuality
        var bestResult: (data: Data, quality: Double)?

        for _ in 0..<options.qualitySearchIterations {
            try cancellation.checkCancellation()
            let quality = (lowerQuality + upperQuality) / 2
            guard let data = autoreleasepool(invoking: {
                image.jpegData(compressionQuality: quality)
            }) else {
                throw AWSImageCompressionError.encodingFailed
            }
            if data.count <= options.targetByteCount {
                bestResult = (data, quality)
                lowerQuality = quality
            } else {
                upperQuality = quality
            }
        }

        if let bestResult {
            return bestResult
        }
        guard let minimumData = autoreleasepool(invoking: {
            image.jpegData(compressionQuality: options.minimumQuality)
        }) else {
            throw AWSImageCompressionError.encodingFailed
        }
        return (minimumData, options.minimumQuality)
    }
}

private final class AWSImageCompressionCancellation {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            throw AWSImageCompressionError.cancelled
        }
    }
}
