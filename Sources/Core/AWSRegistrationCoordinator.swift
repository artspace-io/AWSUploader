import AWSS3
import Foundation

actor AWSRegistrationCoordinator {
    private let configuration: AWSUploadConfiguration
    private let credentialProvider: AWSDynamicCredentialsProvider
    private let utilityKey: String
    private var registrationTask: Task<Void, Error>?
    private var registered = false

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
        if let registrationTask {
            return try await registrationTask.value
        }

        let configuration = self.configuration
        let credentialProvider = self.credentialProvider
        let utilityKey = self.utilityKey
        let task = Task<Void, Error> {
            let serviceConfiguration = try Self.makeServiceConfiguration(
                configuration: configuration,
                credentialProvider: credentialProvider
            )
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                AWSS3TransferUtility.register(
                    with: serviceConfiguration,
                    forKey: utilityKey
                ) { error in
                    if let error {
                        continuation.resume(throwing: AWSUploaderError.registrationFailed(error))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        registrationTask = task

        do {
            try await task.value
            registered = true
            registrationTask = nil
        } catch {
            registrationTask = nil
            throw error
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
