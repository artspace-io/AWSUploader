import AWSS3
import Foundation

public final class AWSUploadTask {
    public let id: UUID
    public let progress: AsyncStream<AWSUploadProgress>

    private let operation: Task<AWSUploadResult, Error>
    private let cancellationController: AWSUploadCancellationController

    init(
        id: UUID,
        progress: AsyncStream<AWSUploadProgress>,
        operation: Task<AWSUploadResult, Error>,
        cancellationController: AWSUploadCancellationController
    ) {
        self.id = id
        self.progress = progress
        self.operation = operation
        self.cancellationController = cancellationController
    }

    public func value() async throws -> AWSUploadResult {
        try await operation.value
    }

    public func cancel() {
        cancellationController.cancel()
        operation.cancel()
    }
}

final class AWSUploadCancellationController {
    private let lock = NSLock()
    private var uploadTask: AWSS3TransferUtilityUploadTask?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ task: AWSS3TransferUtilityUploadTask) {
        lock.lock()
        uploadTask = task
        let shouldCancel = cancelled
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = uploadTask
        lock.unlock()
        task?.cancel()
    }

    func finish() {
        lock.lock()
        uploadTask = nil
        lock.unlock()
    }
}

final class AWSUploadProgressEmitter {
    let stream: AsyncStream<AWSUploadProgress>

    private let continuation: AsyncStream<AWSUploadProgress>.Continuation
    private let lock = NSLock()
    private var greatestFraction = 0.0

    init() {
        var capturedContinuation: AsyncStream<AWSUploadProgress>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        guard let capturedContinuation else {
            preconditionFailure("AsyncStream did not provide a continuation")
        }
        continuation = capturedContinuation
    }

    func yield(_ progress: Progress) {
        let total = progress.totalUnitCount
        let sent = progress.completedUnitCount
        let rawFraction = total > 0 ? Double(sent) / Double(total) : 0

        lock.lock()
        greatestFraction = max(greatestFraction, min(1, rawFraction))
        let fraction = greatestFraction
        lock.unlock()

        continuation.yield(
            AWSUploadProgress(
                bytesSent: sent,
                totalBytes: total,
                fractionCompleted: fraction
            )
        )
    }

    func finish() {
        continuation.finish()
    }
}

final class AWSUploadRegistry {
    private let lock = NSLock()
    private var controllers: [UUID: AWSUploadCancellationController] = [:]

    func insert(_ controller: AWSUploadCancellationController, id: UUID) {
        lock.lock()
        controllers[id] = controller
        lock.unlock()
    }

    func remove(id: UUID) {
        lock.lock()
        controllers[id] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let activeControllers = Array(controllers.values)
        lock.unlock()
        activeControllers.forEach { $0.cancel() }
    }
}
