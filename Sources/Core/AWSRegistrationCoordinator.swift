import AWSS3
import Foundation

actor AWSRegistrationCoordinator {
    private let configuration: AWSUploadConfiguration
    private let credentialProvider: AWSDynamicCredentialsProvider
    private let utilityKey: String
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
        let configuration = self.configuration
        let credentialProvider = self.credentialProvider
        try await AWSTransferUtilityRegistrar.shared.register(
            key: utilityKey,
            timeout: registrationTimeout
        ) {
            try Self.makeServiceConfiguration(
                configuration: configuration,
                credentialProvider: credentialProvider
            )
        }
        guard let utility = AWSS3TransferUtility.s3TransferUtility(forKey: utilityKey) else {
            throw AWSUploaderError.invalidConfiguration("Transfer Utility is unavailable.")
        }
        return utility
    }

    /// `AWSS3TransferUtility.register` 的 completionHandler 最终是在后台 URLSession 的
    /// `getTasksWithCompletionHandler` 回调里被调用的（见 AWSS3TransferUtility.m 的 `recover:`）。
    /// App 挂起期间这个回调不保证到达，没有超时就会让 continuation 永久悬挂，
    /// 进而拖死整条上传链路。
    ///
    /// 另外 SDK 把同一个 completionHandler 同时交给了 `init` 和 `recover:`，
    /// 存在被调用两次的可能 —— 裸 continuation 遇到会直接崩，`AWSContinuationBox` 顺带拆掉这个雷。
    static func register(
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

    static func makeServiceConfiguration(
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

/// 进程级的 transfer utility 注册表。
///
/// 为什么必须有它：utilityKey 现在是由 bucket + region 推导的**稳定值**，
/// 两个配置相同的 `AWSUploader` 实例会算出同一个 key。而用同一个 identifier
/// 创建第二个后台 URLSession 会直接抛异常
/// （`A background URLSession with identifier ... already exists!`）——
/// 也就是说，key 固定之后不加这层去重，等于把原先只是浪费的情况变成崩溃。
///
/// 注册状态必须是**进程级**而不是每个 coordinator 实例一份：两个实例各自持有
/// `registered` 标记的话，"先查后注册"这两步在两个 actor 之间不是原子的，
/// 双方都可能查到 nil 然后各注册一次。
///
/// 代价：配置完全相同的两个实例会共用同一个 transfer utility，也就共用**先注册那一方**
/// 的凭证 provider。需要各自独立的调用方，用 `AWSUploadConfiguration.sessionIdentifierSuffix`
/// 显式区分。
actor AWSTransferUtilityRegistrar {
    static let shared = AWSTransferUtilityRegistrar()

    private var registrations: [String: Task<Void, Error>] = [:]

    func register(
        key: String,
        timeout: TimeInterval,
        makeConfiguration: @Sendable @escaping () throws -> AWSServiceConfiguration
    ) async throws {
        // 已经注册过就直接复用。未命中且没有 AWSInfo 配置时这个取值器返回 nil，
        // 拿来做预检是安全的。
        if AWSS3TransferUtility.s3TransferUtility(forKey: key) != nil {
            return
        }

        let task: Task<Void, Error>
        if let existing = registrations[key] {
            task = existing
        } else {
            let newTask = Task<Void, Error> {
                let serviceConfiguration = try makeConfiguration()
                try await AWSRegistrationCoordinator.register(
                    serviceConfiguration: serviceConfiguration,
                    utilityKey: key,
                    timeout: timeout
                )
            }
            registrations[key] = newTask
            task = newTask
        }

        do {
            try await task.value
        } catch {
            // 等待方被取消不代表注册本身失败，共享 Task 留给其他等待方；
            // 只有注册真的失败才清空，好让下次调用能重新注册
            if !(error is CancellationError) {
                registrations[key] = nil
            }
            throw error
        }
    }
}
