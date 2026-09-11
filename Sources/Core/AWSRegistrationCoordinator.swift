import AWSS3
import Foundation

actor AWSRegistrationCoordinator {
    private let configuration: AWSUploadConfiguration
    private let credentialProvider: AWSDynamicCredentialsProvider
    private let utilityKey: String
    private var registrationTask: Task<Void, Error>?
    private var registered = false
    private let registrationTimeout: TimeInterval = 30

    init(
        configuration: AWSUploadConfiguration,
        credentialProvider: AWSDynamicCredentialsProvider,
        utilityKey: String
    ) {
        self.configuration = configuration
        self.credentialProvider = credentialProvider
        self.utilityKey = utilityKey
    }

    func utility() async throws -> AWSS3TransferUtility {
        if !registered {
            try await registerIfNeeded()
        }
        guard let utility = AWSS3TransferUtility.s3TransferUtility(forKey: utilityKey) else {
            throw AWSUploaderError.invalidConfiguration("Transfer Utility is unavailable.")
        }
        return utility
    }

    private func registerIfNeeded() async throws {
        let task: Task<Void, Error>
        if let registrationTask {
            task = registrationTask
        } else {
            let configuration = self.configuration
            let credentialProvider = self.credentialProvider
            let utilityKey = self.utilityKey
            let timeout = self.registrationTimeout
            task = Task<Void, Error> {
                let serviceConfiguration = try Self.makeServiceConfiguration(
                    configuration: configuration,
                    credentialProvider: credentialProvider
                )
                try await Self.register(
                    serviceConfiguration: serviceConfiguration,
                    utilityKey: utilityKey,
                    timeout: timeout
                )
            }
            registrationTask = task
        }

        do {
            try await task.value
            registered = true
            registrationTask = nil
        } catch {
            // 等待方被取消不代表注册本身失败，共享 task 留给其他等待方；
            // 只有注册真的失败才清空，好让下次调用能重新注册
            if !(error is CancellationError) {
                registrationTask = nil
            }
            throw error
        }
    }

    /// `AWSS3TransferUtility.register` 的 completionHandler 最终是在后台 URLSession 的
    /// `getTasksWithCompletionHandler` 回调里被调用的（见 AWSS3TransferUtility.m 的 `recover:`）。
    /// App 挂起期间这个回调不保证到达，没有超时就会让 continuation 永久悬挂，
    /// 进而拖死整条上传链路。
    ///
    /// 另外 SDK 把同一个 completionHandler 同时交给了 `init` 和 `recover:`，
    /// 存在被调用两次的可能 —— 裸 continuation 遇到会直接崩，`AWSContinuationBox` 顺带拆掉这个雷。
    private static func register(
        serviceConfiguration: AWSServiceConfiguration,
        utilityKey: String,
        timeout: TimeInterval
    ) async throws {
        let box = AWSContinuationBox<Void>()

        let timer = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return
            }
            let error = NSError(
                domain: "AWSUploader",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Registering the S3 transfer utility timed out after \(Int(timeout))s."
                ]
            )
            box.fail(AWSUploaderError.registrationFailed(error))
        }
        defer { timer.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard box.install(continuation) else { return }
            AWSS3TransferUtility.register(
                with: serviceConfiguration,
                forKey: utilityKey
            ) { error in
                if let error {
                    box.fail(AWSUploaderError.registrationFailed(error))
                } else {
                    box.succeed(())
                }
            }
        }
    }

    private static func makeServiceConfiguration(
        configuration: AWSUploadConfiguration,
        credentialProvider: AWSDynamicCredentialsProvider
    ) throws -> AWSServiceConfiguration {
        let region = configuration.region.aws_regionTypeValue()
        guard region != .Unknown else {
            throw AWSUploaderError.invalidConfiguration("Unknown AWS region: \(configuration.region)")
        }
        guard !configuration.bucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AWSUploaderError.invalidConfiguration("Bucket must not be empty.")
        }
        guard configuration.credentialRefreshAhead >= 0,
              configuration.requestTimeout > 0,
              configuration.resourceTimeout > 0 else {
            throw AWSUploaderError.invalidConfiguration("Timeout and refresh values are invalid.")
        }
        guard let serviceConfiguration = AWSServiceConfiguration(
            region: region,
            credentialsProvider: credentialProvider
        ) else {
            throw AWSUploaderError.invalidConfiguration("AWS service configuration could not be created.")
        }
        serviceConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        serviceConfiguration.timeoutIntervalForResource = configuration.resourceTimeout
        return serviceConfiguration
    }
}
