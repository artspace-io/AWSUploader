import XCTest
@testable import AWSUploader

/// 这些用例锁死的是一个真实线上事故：进入 Loading 页后切后台，上传被取消，
/// 但 AWS SDK 对已取消的 upload task 不再回调 completionHandler，
/// continuation 永久悬挂 → 整个页面永久卡在 Loading。
/// 核心约束是「取消必须在有限时间内产生结论」，而不是挂起。
final class AWSContinuationBoxTests: XCTestCase {
    func testResultArrivingBeforeInstallIsDeliveredOnInstall() async throws {
        let box = AWSContinuationBox<Int>()
        // 先出结果，后装 continuation —— onCancel 早于 body 时就是这个次序
        box.succeed(42)

        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            XCTAssertFalse(box.install(continuation), "结果早于安装时 install 必须返回 false")
        }

        XCTAssertEqual(value, 42)
    }

    func testSecondResolveIsIgnoredInsteadOfCrashing() async throws {
        let box = AWSContinuationBox<Int>()

        async let pending: Int = withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            box.install(continuation)
        }

        box.succeed(1)
        // AWSS3TransferUtility.register 会把同一个 completionHandler 交给 init 和 recover:，
        // 裸 continuation 二次 resume 会直接崩
        box.succeed(2)
        box.fail(CancellationError())

        let value = try await pending
        XCTAssertEqual(value, 1)
    }

    func testFailurePropagates() async throws {
        let box = AWSContinuationBox<Int>()

        async let pending: Int = withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            box.install(continuation)
        }

        box.fail(AWSUploaderError.cancelled)

        do {
            _ = try await pending
            XCTFail("应当抛出 cancelled")
        } catch let error as AWSUploaderError {
            guard case .cancelled = error else {
                return XCTFail("期望 .cancelled，实际 \(error)")
            }
        }
    }
}

final class AWSTimeoutTests: XCTestCase {
    /// 最关键的一条：操作完全不响应取消时，超时仍然必须生效。
    /// 旧实现用 withThrowingTaskGroup，任务组要等所有子任务结束，这里会永久挂起。
    func testTimeoutFiresEvenWhenOperationIgnoresCancellation() async throws {
        struct Marker: Error {}

        let start = Date()
        do {
            _ = try await AWSTimeout.run(
                seconds: 0.2,
                onTimeout: Marker()
            ) { () async throws -> Int in
                // 不响应取消：sleep 被打断也继续睡，模拟 AWS 那个永不回调的 continuation
                while true {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            XCTFail("应当超时")
        } catch is Marker {
            XCTAssertLessThan(Date().timeIntervalSince(start), 3, "超时必须及时返回，不能等操作结束")
        }
    }

    func testSuccessBeforeTimeoutReturnsValue() async throws {
        let value = try await AWSTimeout.run(
            seconds: 5,
            onTimeout: AWSUploaderError.cancelled
        ) {
            try await Task.sleep(nanoseconds: 10_000_000)
            return 7
        }

        XCTAssertEqual(value, 7)
    }

    func testOperationFailurePropagatesInsteadOfTimeout() async throws {
        struct Boom: Error {}

        do {
            _ = try await AWSTimeout.run(
                seconds: 5,
                onTimeout: AWSUploaderError.cancelled
            ) { () async throws -> Int in
                throw Boom()
            }
            XCTFail("应当抛出 Boom")
        } catch is Boom {
            // 期望路径
        }
    }

    /// 计时任务被取消时不能误报超时。
    func testCancellingCallerThrowsCancellationNotTimeout() async throws {
        struct Marker: Error {}

        let task = Task { () async throws -> Int in
            try await AWSTimeout.run(seconds: 10, onTimeout: Marker()) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("应当抛出 CancellationError")
        } catch is CancellationError {
            // 期望路径
        } catch is Marker {
            XCTFail("取消被误报成了超时")
        }
    }
}
