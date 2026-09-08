import AWSS3
import Foundation
import UIKit

public final class AWSUploader {
    private let configuration: AWSUploadConfiguration
    private let credentialStore: AWSCredentialStore
    private let registrationCoordinator: AWSRegistrationCoordinator
    private let uploadRegistry = AWSUploadRegistry()

    public init(
        configuration: AWSUploadConfiguration,
        credentialsFetcher: @escaping AWSCredentialsFetcher
    ) {
        self.configuration = configuration
        let credentialStore = AWSCredentialStore(
            refreshAhead: configuration.credentialRefreshAhead,
            fetcher: credentialsFetcher
        )
        self.credentialStore = credentialStore
        let provider = AWSDynamicCredentialsProvider(credentialStore: credentialStore)
        registrationCoordinator = AWSRegistrationCoordinator(
            configuration: configuration,
            credentialProvider: provider,
            utilityKey: "com.artspace.AWSUploader.\(UUID().uuidString)"
        )
    }

    public func upload(
        data: Data,
        objectName: String,
        contentType: String
    ) -> AWSUploadTask {
        makeUploadTask(source: .data(data), objectName: objectName, contentType: contentType)
    }

    public func upload(
        fileURL: URL,
        objectName: String,
        contentType: String
    ) -> AWSUploadTask {
        makeUploadTask(source: .file(fileURL), objectName: objectName, contentType: contentType)
    }

    public func cancelAll() {
        uploadRegistry.cancelAll()
    }

    public static func handleEvents(
        application: UIApplication,
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        AWSS3TransferUtility.interceptApplication(
            application,
            handleEventsForBackgroundURLSession: identifier,
            completionHandler: completionHandler
        )
    }

    private func makeUploadTask(
        source: AWSUploadSource,
        objectName: String,
        contentType: String
    ) -> AWSUploadTask {
        let id = UUID()
        let progressEmitter = AWSUploadProgressEmitter()
        let cancellationController = AWSUploadCancellationController()
        uploadRegistry.insert(cancellationController, id: id)

        let operation = Task<AWSUploadResult, Error> { [weak self] in
            guard let self else {
                throw AWSUploaderError.cancelled
            }
            defer {
                cancellationController.finish()
                progressEmitter.finish()
                uploadRegistry.remove(id: id)
            }
            return try await performUpload(
                source: source,
                objectName: objectName,
                contentType: contentType,
                progressEmitter: progressEmitter,
                cancellationController: cancellationController
            )
        }

        return AWSUploadTask(
            id: id,
            progress: progressEmitter.stream,
            operation: operation,
            cancellationController: cancellationController
        )
    }
}

extension AWSUploader {
    private func performUpload(
        source: AWSUploadSource,
        objectName: String,
        contentType: String,
        progressEmitter: AWSUploadProgressEmitter,
        cancellationController: AWSUploadCancellationController
    ) async throws -> AWSUploadResult {
        try Task.checkCancellation()
        try validate(source: source, objectName: objectName, contentType: contentType)
        let utility = try await registrationCoordinator.utility()

        for attempt in 0...1 {
            try Task.checkCancellation()
            let credentials = try await credentialStore.credentials(forceRefresh: attempt > 0)
            let objectKey = try Self.objectKey(prefix: credentials.keyPrefix, objectName: objectName)
            let context = AWSUploadContext(
                source: source,
                utility: utility,
                objectKey: objectKey,
                contentType: contentType,
                progressEmitter: progressEmitter,
                cancellationController: cancellationController
            )

            do {
                try await uploadOnce(context: context)
                return AWSUploadResult(bucket: configuration.bucket, objectKey: objectKey)
            } catch {
                if attempt == 0, Self.isAuthenticationError(error) {
                    await credentialStore.invalidate()
                    continue
                }
                throw error
            }
        }

        throw AWSUploaderError.invalidCredentials
    }

    private func uploadOnce(context: AWSUploadContext) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let completionGate = AWSCompletionGate()
                let creationTask = makeAWSTask(
                    context: context,
                    completionGate: completionGate,
                    continuation: continuation
                )
                observeCreation(
                    task: creationTask,
                    context: context,
                    completionGate: completionGate,
                    continuation: continuation
                )
            }
        } onCancel: {
            context.cancellationController.cancel()
        }
    }

    private func makeAWSTask(
        context: AWSUploadContext,
        completionGate: AWSCompletionGate,
        continuation: CheckedContinuation<Void, Error>
    ) -> AWSTask<AWSS3TransferUtilityUploadTask> {
        let expression = AWSS3TransferUtilityUploadExpression()
        expression.progressBlock = { _, progress in
            context.progressEmitter.yield(progress)
        }
        let completion: AWSS3TransferUtilityUploadCompletionHandlerBlock = { _, error in
            Self.completeUpload(
                error: error,
                cancellationController: context.cancellationController,
                completionGate: completionGate,
                continuation: continuation
            )
        }

        switch context.source {
        case .data(let data):
            return context.utility.uploadData(
                data,
                bucket: configuration.bucket,
                key: context.objectKey,
                contentType: context.contentType,
                expression: expression,
                completionHandler: completion
            )
        case .file(let fileURL):
            return context.utility.uploadFile(
                fileURL,
                bucket: configuration.bucket,
                key: context.objectKey,
                contentType: context.contentType,
                expression: expression,
                completionHandler: completion
            )
        }
    }

    private static func completeUpload(
        error: Error?,
        cancellationController: AWSUploadCancellationController,
        completionGate: AWSCompletionGate,
        continuation: CheckedContinuation<Void, Error>
    ) {
        completionGate.finish {
            if cancellationController.isCancelled {
                continuation.resume(throwing: AWSUploaderError.cancelled)
            } else if let error {
                continuation.resume(throwing: AWSUploaderError.uploadFailed(error))
            } else {
                continuation.resume()
            }
        }
    }

    private func observeCreation(
        task: AWSTask<AWSS3TransferUtilityUploadTask>,
        context: AWSUploadContext,
        completionGate: AWSCompletionGate,
        continuation: CheckedContinuation<Void, Error>
    ) {
        task.continueWith { task in
            if let uploadTask = task.result {
                context.cancellationController.register(uploadTask)
            }
            if context.cancellationController.isCancelled || task.isCancelled {
                completionGate.finish {
                    continuation.resume(throwing: AWSUploaderError.cancelled)
                }
            } else if let error = task.error {
                completionGate.finish {
                    continuation.resume(throwing: AWSUploaderError.uploadFailed(error))
                }
            } else if task.result == nil {
                completionGate.finish {
                    let error = NSError(
                        domain: "AWSUploader",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "AWS did not create an upload task."]
                    )
                    continuation.resume(throwing: AWSUploaderError.uploadFailed(error))
                }
            }
            return nil
        }
    }

    private func validate(source: AWSUploadSource, objectName: String, contentType: String) throws {
        guard !objectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AWSUploaderError.invalidObjectName
        }
        guard !contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AWSUploaderError.invalidConfiguration("Content type must not be empty.")
        }
        if case .file(let url) = source,
           !FileManager.default.fileExists(atPath: url.path) {
            throw AWSUploaderError.fileNotFound(url)
        }
    }

    static func objectKey(prefix: String?, objectName: String) throws -> String {
        let name = objectName.drop(while: { $0 == "/" })
        guard !name.isEmpty else {
            throw AWSUploaderError.invalidObjectName
        }
        let cleanPrefix = prefix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return cleanPrefix.isEmpty ? String(name) : "\(cleanPrefix)/\(name)"
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        let error = error as NSError
        let details = "\(error.domain) \(error.localizedDescription) \(error.userInfo)".lowercased()
        let markers = [
            "expiredtoken",
            "invalidaccesskeyid",
            "invalidtoken",
            "requestexpired",
            "signaturedoesnotmatch",
            "tokenrefreshrequired"
        ]
        return markers.contains { details.contains($0) }
    }
}

private enum AWSUploadSource {
    case data(Data)
    case file(URL)
}

private struct AWSUploadContext {
    let source: AWSUploadSource
    let utility: AWSS3TransferUtility
    let objectKey: String
    let contentType: String
    let progressEmitter: AWSUploadProgressEmitter
    let cancellationController: AWSUploadCancellationController
}

private final class AWSCompletionGate {
    private let lock = NSLock()
    private var completed = false

    func finish(_ completion: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        completion()
    }
}
