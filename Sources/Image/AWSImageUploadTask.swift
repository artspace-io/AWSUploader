import Foundation
import UIKit

public enum AWSImageUploadProgress: Sendable {
    case compressing
    case uploading(AWSUploadProgress)
    case completed
}

public final class AWSImageUploadTask {
    public let id: UUID
    public let progress: AsyncStream<AWSImageUploadProgress>

    private let operation: Task<AWSUploadResult, Error>
    private let cancellation: AWSImageUploadCancellation

    fileprivate init(
        id: UUID,
        progress: AsyncStream<AWSImageUploadProgress>,
        operation: Task<AWSUploadResult, Error>,
        cancellation: AWSImageUploadCancellation
    ) {
        self.id = id
        self.progress = progress
        self.operation = operation
        self.cancellation = cancellation
    }

    public func value() async throws -> AWSUploadResult {
        try await operation.value
    }

    public func cancel() {
        cancellation.cancel()
        operation.cancel()
    }
}

public extension AWSUploader {
    func upload(
        image: UIImage,
        objectName: String,
        compression: AWSImageCompressionOptions = .default
    ) -> AWSImageUploadTask {
        makeImageUploadTask(objectName: objectName) {
            try await AWSImageCompressor().compress(image, options: compression)
        }
    }

    func uploadImage(
        data: Data,
        objectName: String,
        compression: AWSImageCompressionOptions = .default
    ) -> AWSImageUploadTask {
        makeImageUploadTask(objectName: objectName) {
            try await AWSImageCompressor().compress(data: data, options: compression)
        }
    }

    func uploadImage(
        fileURL: URL,
        objectName: String,
        compression: AWSImageCompressionOptions = .default
    ) -> AWSImageUploadTask {
        makeImageUploadTask(objectName: objectName) {
            try await AWSImageCompressor().compress(fileURL: fileURL, options: compression)
        }
    }

    private func makeImageUploadTask(
        objectName: String,
        compress: @escaping () async throws -> AWSCompressedImage
    ) -> AWSImageUploadTask {
        let id = UUID()
        let emitter = AWSImageUploadProgressEmitter()
        let cancellation = AWSImageUploadCancellation()
        let operation = Task<AWSUploadResult, Error> {
            defer { emitter.finish() }
            emitter.yield(.compressing)
            let compressed = try await compress()
            try Task.checkCancellation()

            let uploadTask = upload(
                data: compressed.data,
                objectName: objectName,
                contentType: compressed.contentType
            )
            cancellation.register(uploadTask)
            let progressForwarder = Task {
                for await progress in uploadTask.progress {
                    emitter.yield(.uploading(progress))
                }
            }
            defer { progressForwarder.cancel() }

            let result = try await withTaskCancellationHandler {
                try await uploadTask.value()
            } onCancel: {
                uploadTask.cancel()
            }
            emitter.yield(.completed)
            return result
        }

        cancellation.register(operation)
        return AWSImageUploadTask(
            id: id,
            progress: emitter.stream,
            operation: operation,
            cancellation: cancellation
        )
    }
}

private final class AWSImageUploadProgressEmitter {
    let stream: AsyncStream<AWSImageUploadProgress>
    private let continuation: AsyncStream<AWSImageUploadProgress>.Continuation

    init() {
        var capturedContinuation: AsyncStream<AWSImageUploadProgress>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }
        continuation = capturedContinuation
    }

    func yield(_ progress: AWSImageUploadProgress) {
        continuation.yield(progress)
    }

    func finish() {
        continuation.finish()
    }
}

private final class AWSImageUploadCancellation {
    private let lock = NSLock()
    private var operation: Task<AWSUploadResult, Error>?
    private var uploadTask: AWSUploadTask?
    private var cancelled = false

    func register(_ operation: Task<AWSUploadResult, Error>) {
        lock.lock()
        self.operation = operation
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            operation.cancel()
        }
    }

    func register(_ uploadTask: AWSUploadTask) {
        lock.lock()
        self.uploadTask = uploadTask
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            uploadTask.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = operation
        let uploadTask = uploadTask
        lock.unlock()
        operation?.cancel()
        uploadTask?.cancel()
    }
}
