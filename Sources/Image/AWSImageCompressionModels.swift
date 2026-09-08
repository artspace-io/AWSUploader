import Foundation

public struct AWSImageCompressionOptions: Sendable {
    public enum OverflowBehavior: Sendable {
        case bestEffort
        case fail
    }

    public var targetByteCount: Int
    public var maximumLongSide: Int
    public var minimumLongSide: Int
    public var initialQuality: Double
    public var minimumQuality: Double
    public var dimensionReductionFactor: Double
    public var qualitySearchIterations: Int
    public var overflowBehavior: OverflowBehavior

    public init(
        targetByteCount: Int = 2 * 1024 * 1024,
        maximumLongSide: Int = 2048,
        minimumLongSide: Int = 1280,
        initialQuality: Double = 0.85,
        minimumQuality: Double = 0.68,
        dimensionReductionFactor: Double = 0.85,
        qualitySearchIterations: Int = 6,
        overflowBehavior: OverflowBehavior = .bestEffort
    ) {
        self.targetByteCount = targetByteCount
        self.maximumLongSide = maximumLongSide
        self.minimumLongSide = minimumLongSide
        self.initialQuality = initialQuality
        self.minimumQuality = minimumQuality
        self.dimensionReductionFactor = dimensionReductionFactor
        self.qualitySearchIterations = qualitySearchIterations
        self.overflowBehavior = overflowBehavior
    }

    public static let `default` = AWSImageCompressionOptions()

    func validate() throws {
        guard targetByteCount > 0,
              maximumLongSide > 0,
              minimumLongSide > 0,
              minimumLongSide <= maximumLongSide,
              (0...1).contains(initialQuality),
              (0...1).contains(minimumQuality),
              minimumQuality <= initialQuality,
              dimensionReductionFactor > 0,
              dimensionReductionFactor < 1,
              qualitySearchIterations > 0 else {
            throw AWSImageCompressionError.invalidOptions
        }
    }
}

public struct AWSCompressedImage: Sendable {
    public let data: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let compressionQuality: Double
    public let didMeetTargetByteCount: Bool
    public let contentType: String
    public let fileExtension: String

    public init(
        data: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        compressionQuality: Double,
        didMeetTargetByteCount: Bool,
        contentType: String = "image/jpeg",
        fileExtension: String = "jpeg"
    ) {
        self.data = data
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.compressionQuality = compressionQuality
        self.didMeetTargetByteCount = didMeetTargetByteCount
        self.contentType = contentType
        self.fileExtension = fileExtension
    }
}

public enum AWSImageCompressionError: LocalizedError {
    case invalidOptions
    case emptyData
    case fileNotFound(URL)
    case decodingFailed
    case invalidPixelSize
    case unsupportedAnimatedImage
    case renderingFailed
    case encodingFailed
    case targetByteCountNotReached(actual: Int, target: Int)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "The image compression options are invalid."
        case .emptyData:
            return "The image data is empty."
        case .fileNotFound(let url):
            return "The image file does not exist: \(url.path)"
        case .decodingFailed:
            return "The image could not be decoded."
        case .invalidPixelSize:
            return "The image has an invalid pixel size."
        case .unsupportedAnimatedImage:
            return "Animated images are not supported."
        case .renderingFailed:
            return "The image could not be rendered."
        case .encodingFailed:
            return "The image could not be encoded as JPEG."
        case let .targetByteCountNotReached(actual, target):
            return "The compressed image is \(actual) bytes, exceeding the \(target)-byte limit."
        case .cancelled:
            return "Image compression was cancelled."
        }
    }
}
