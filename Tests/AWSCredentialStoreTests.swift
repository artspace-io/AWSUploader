import XCTest
@testable import AWSUploader

final class AWSCredentialStoreTests: XCTestCase {
    func testConcurrentCredentialRequestsShareOneRefresh() async throws {
        let counter = CredentialFetchCounter()
        let store = AWSCredentialStore(refreshAhead: 300) {
            await counter.increment()
            try await Task.sleep(nanoseconds: 20_000_000)
            return Self.validCredentials()
        }

        async let first = store.credentials()
        async let second = store.credentials()
        async let third = store.credentials()
        _ = try await [first, second, third]

        let fetchCount = await counter.value
        XCTAssertEqual(fetchCount, 1)
    }

    func testCredentialInsideRefreshWindowIsFetchedAgain() async throws {
        let counter = CredentialFetchCounter()
        let store = AWSCredentialStore(refreshAhead: 300) {
            let call = await counter.increment()
            return AWSTemporaryCredentials(
                accessKey: "key",
                secretKey: "secret",
                sessionToken: "token",
                expiration: Date().addingTimeInterval(call == 1 ? 60 : 3_600)
            )
        }

        _ = try await store.credentials()
        _ = try await store.credentials()

        let fetchCount = await counter.value
        XCTAssertEqual(fetchCount, 2)
    }

    func testInvalidCredentialIsRejected() async {
        let store = AWSCredentialStore(refreshAhead: 300) {
            AWSTemporaryCredentials(
                accessKey: "",
                secretKey: "secret",
                sessionToken: "token",
                expiration: Date().addingTimeInterval(3_600)
            )
        }

        do {
            _ = try await store.credentials()
            XCTFail("Expected invalid credentials to throw")
        } catch AWSUploaderError.invalidCredentials {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func validCredentials() -> AWSTemporaryCredentials {
        AWSTemporaryCredentials(
            accessKey: "key",
            secretKey: "secret",
            sessionToken: "token",
            expiration: Date().addingTimeInterval(3_600)
        )
    }
}

private actor CredentialFetchCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
