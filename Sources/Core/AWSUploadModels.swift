import Foundation

public struct AWSUploadConfiguration: Sendable {
    public let bucket: String
    public let region: String
    public let credentialRefreshAhead: TimeInterval
    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval

    /// 后台 URLSession 标识符的后缀。留空时由 `bucket` + `region` 推导。
    ///
    /// 只有在**同一个 App 内需要多个 bucket/region 完全相同、但要各自独立的
    /// AWSUploader** 时才需要显式指定：标识符相同的两个实例会共用同一个
    /// transfer utility（也就共用先注册那一方的凭证 provider）。
    ///
    /// 它决定的是后台 session 的身份，**必须跨启动稳定**。
    /// 千万不要传 UUID 之类每次启动都变的值 —— 那会让每次启动都遗弃一个后台 session，
    /// 并在传输记录库里留下永远不会被回收的孤儿行。
    public let sessionIdentifierSuffix: String?

    public init(
        bucket: String,
        region: String,
        credentialRefreshAhead: TimeInterval = 300,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 100,
        sessionIdentifierSuffix: String? = nil
    ) {
        self.bucket = bucket
        self.region = region
        self.credentialRefreshAhead = credentialRefreshAhead
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.sessionIdentifierSuffix = sessionIdentifierSuffix
    }
}

public struct AWSTemporaryCredentials: Sendable {
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String
    public let expiration: Date
    public let keyPrefix: String?

    public init(
        accessKey: String,
        secretKey: String,
        sessionToken: String,
        expiration: Date,
        keyPrefix: String? = nil
    ) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.sessionToken = sessionToken
        self.expiration = expiration
        self.keyPrefix = keyPrefix
    }
}

public typealias AWSCredentialsFetcher = @Sendable () async throws -> AWSTemporaryCredentials

public struct AWSUploadProgress: Sendable {
    public let bytesSent: Int64
    public let totalBytes: Int64
    public let fractionCompleted: Double

    public init(bytesSent: Int64, totalBytes: Int64, fractionCompleted: Double) {
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
        self.fractionCompleted = fractionCompleted
    }
}

public struct AWSUploadResult: Sendable {
    public let bucket: String
    public let objectKey: String

    public init(bucket: String, objectKey: String) {
        self.bucket = bucket
        self.objectKey = objectKey
    }
}
