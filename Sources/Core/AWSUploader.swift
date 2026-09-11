import AWSS3
import Foundation
import UIKit

public final class AWSUploader {
    private let configuration: AWSUploadConfiguration
    private let credentialStore: AWSCredentialStore
    private let registrationCoordinator: AWSRegistrationCoordinator
    private let uploadRegistry = AWSUploadRegistry()

    /// 本实例使用的 transfer utility key，也就是后台 URLSession 身份的来源。
    /// 暴露出来供调用方排查问题 —— 它**必须跨启动稳定**，冷启动两次打出来应当一模一样。
    /// 库本身不做日志，要核对请在调用方打印它。
    public let utilityKey: String

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
        let utilityKey = AWSUtilityKey.makeUtilityKey(configuration: configuration)
        self.utilityKey = utilityKey
        registrationCoordinator = AWSRegistrationCoordinator(
            configuration: configuration,
            credentialProvider: provider,
            utilityKey: utilityKey
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
        // box 必须建在 withTaskCancellationHandler 外面，否则 onCancel 够不到 continuation
        let box = AWSContinuationBox<Void>()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // 取消早于安装时 install 返回 false，此时不要再去创建 AWS 任务：
                // 那是一次注定要被丢弃的真实上传
                guard box.install(continuation) else { return }
                let creationTask = makeAWSTask(context: context, box: box)
                observeCreation(task: creationTask, context: context, box: box)
            }
        } onCancel: {
            // AWS SDK 对已取消的 upload task 会在 didCompleteWithError 里直接
            // cleanupForUploadTask 然后 return，completionHandler 永远不会被调用
            // （AWSS3TransferUtility.m）。所以取消时必须由我们自己给 continuation 收尾，
            // 否则它永久悬挂 —— 这正是"切后台后永久卡在 Loading 页"的根因。
            context.cancellationController.cancel()
            box.fail(AWSUploaderError.cancelled)
        }
    }

    private func makeAWSTask(
        context: AWSUploadContext,
        box: AWSContinuationBox<Void>
    ) -> AWSTask<AWSS3TransferUtilityUploadTask> {
        let expression = AWSS3TransferUtilityUploadExpression()
        expression.progressBlock = { _, progress in
            context.progressEmitter.yield(progress)
        }
        let completion: AWSS3TransferUtilityUploadCompletionHandlerBlock = { _, error in
            Self.completeUpload(
                error: error,
                cancellationController: context.cancellationController,
                box: box
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
        box: AWSContinuationBox<Void>
    ) {
        if cancellationController.isCancelled {
            box.fail(AWSUploaderError.cancelled)
        } else if let error {
            box.fail(AWSUploaderError.uploadFailed(error))
        } else {
            box.succeed(())
        }
    }

    private func observeCreation(
        task: AWSTask<AWSS3TransferUtilityUploadTask>,
        context: AWSUploadContext,
        box: AWSContinuationBox<Void>
    ) {
        task.continueWith { task in
            if let uploadTask = task.result {
                context.cancellationController.register(uploadTask)
            }
            if context.cancellationController.isCancelled || task.isCancelled {
                box.fail(AWSUploaderError.cancelled)
            } else if let error = task.error {
                box.fail(AWSUploaderError.uploadFailed(error))
            } else if task.result == nil {
                let error = NSError(
                    domain: "AWSUploader",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "AWS did not create an upload task."]
                )
                box.fail(AWSUploaderError.uploadFailed(error))
            }
            // 任务创建成功且未取消时这里什么都不做：后续由 completion block 收尾，
            // 取消则由 uploadOnce 的 onCancel 收尾
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
