import AWSCore
import Foundation

actor AWSCredentialStore {
    private let refreshAhead: TimeInterval
    private let fetcher: AWSCredentialsFetcher
    private var cachedCredentials: AWSTemporaryCredentials?
    private var refreshTask: Task<AWSTemporaryCredentials, Error>?

    init(refreshAhead: TimeInterval, fetcher: @escaping AWSCredentialsFetcher) {
        self.refreshAhead = refreshAhead
        self.fetcher = fetcher
    }

    func credentials(forceRefresh: Bool = false) async throws -> AWSTemporaryCredentials {
        if !forceRefresh,
           let cachedCredentials,
           isValid(cachedCredentials) {
            return cachedCredentials
        }

        if let refreshTask {
            return try await refreshTask.value
        }

        let fetcher = self.fetcher
        let task = Task<AWSTemporaryCredentials, Error> {
            do {
                return try await fetcher()
            } catch {
                throw AWSUploaderError.credentialFetchFailed(error)
            }
        }
        refreshTask = task

        do {
            let credentials = try await task.value
            guard Self.hasRequiredValues(credentials), credentials.expiration > Date() else {
                refreshTask = nil
                throw AWSUploaderError.invalidCredentials
            }
            cachedCredentials = credentials
            refreshTask = nil
            return credentials
        } catch {
            refreshTask = nil
            throw error
        }
    }

    func invalidate() {
        cachedCredentials = nil
    }

    private func isValid(_ credentials: AWSTemporaryCredentials) -> Bool {
        credentials.expiration.timeIntervalSinceNow > refreshAhead
            && Self.hasRequiredValues(credentials)
    }

    private static func hasRequiredValues(_ credentials: AWSTemporaryCredentials) -> Bool {
        !credentials.accessKey.isEmpty
            && !credentials.secretKey.isEmpty
            && !credentials.sessionToken.isEmpty
    }
}

final class AWSDynamicCredentialsProvider: NSObject, AWSCredentialsProvider {
    private let credentialStore: AWSCredentialStore

    init(credentialStore: AWSCredentialStore) {
        self.credentialStore = credentialStore
    }

    func credentials() -> AWSTask<AWSCredentials> {
        let source = AWSTaskCompletionSource<AWSCredentials>()
        Task {
            do {
                let credentials = try await credentialStore.credentials()
                let awsCredentials = AWSCredentials(
                    accessKey: credentials.accessKey,
                    secretKey: credentials.secretKey,
                    sessionKey: credentials.sessionToken,
                    expiration: credentials.expiration
                )
                source.trySet(result: awsCredentials)
            } catch {
                source.trySet(error: error as NSError)
            }
        }
        return source.task
    }

    func invalidateCachedTemporaryCredentials() {
        Task {
            await credentialStore.invalidate()
        }
    }
}
