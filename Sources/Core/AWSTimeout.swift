import Foundation

enum AWSTimeout {
    /// 给一个可能不响应取消的异步操作加上真正生效的超时。
    ///
    /// 不能用 `withThrowingTaskGroup`：结构化任务组在 body 退出前必须隐式 await
    /// **全部**子任务结束，所以只要操作子任务不返回，超时子任务先抛错也没用 ——
    /// 任务组会卡在析构处一起等，超时形同虚设。
    ///
    /// 这里改成「谁先给结果用谁，输的那个直接弃置」：等的是结果盒而不是工作 Task 本身。
    /// 代价是超时后被弃置的 Task 会泄漏到它自己结束为止，这是刻意的取舍 ——
    /// 宁可泄漏一个后台任务，也不能让调用方永久挂起。
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        onTimeout: @autoclosure @escaping @Sendable () -> Error,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let box = AWSContinuationBox<Value>()

        let work = Task {
            do {
                box.succeed(try await operation())
            } catch {
                box.fail(error)
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                // 计时任务自己被取消，说明操作已经有结论，不能再报超时
                return
            }
            box.fail(onTimeout())
        }
        defer {
            work.cancel()
            timer.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
                box.install(continuation)
            }
        } onCancel: {
            box.fail(CancellationError())
            work.cancel()
        }
    }
}
