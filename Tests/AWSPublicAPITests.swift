// 故意用普通 import（而不是 @testable）：@testable 会绕过访问控制，
// 测不出 public 是否真的加对了。App 侧就是靠这层公共 API 复用这两个件的，
// 谁把 public 去掉或漏了 public init，这里会直接编译失败。
import XCTest
import AWSUploader

final class AWSPublicAPITests: XCTestCase {
    func testContinuationBoxIsUsableFromOutsideTheModule() async throws {
        let box = AWSContinuationBox<Int>()

        async let pending: Int = withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
            box.install(continuation)
        }
        box.succeed(9)
        box.succeed(10)

        let value = try await pending
        XCTAssertEqual(value, 9, "对外契约是第一个结果胜出")
    }

    func testTimeoutIsUsableFromOutsideTheModule() async throws {
        struct CallerError: Error {}

        do {
            _ = try await AWSTimeout.run(
                seconds: 0.1,
                onTimeout: CallerError()
            ) { () async throws -> Int in
                // 不响应取消，模拟真实的悬挂 continuation
                while true {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            XCTFail("应当超时")
        } catch is CallerError {
            // 期望路径：调用方自带的错误类型能原样传出来
        }
    }
}
