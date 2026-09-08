import Foundation

public struct AWSUploadConfiguration: Sendable {
    public let bucket: String
    public let region: String
    public let credentialRefreshAhead: TimeInterval
    public let requestTimeout: TimeInterval
    public let resourceTimeout: TimeInterval

    public init(
        bucket: String,
        region: String,
        credentialRefreshAhead: TimeInterval = 300,
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 100
    ) {
        self.bucket = bucket
        self.region = region
        self.credentialRefreshAhead = credentialRefreshAhead
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
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
