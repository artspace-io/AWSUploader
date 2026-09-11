import Foundation

/// 把 `CheckedContinuation` 的所有权从 `withCheckedThrowingContinuation` 的闭包里提出来，
/// 让取消回调、完成回调、超时三个来源都能安全地 resume 同一个 continuation。
///
/// 为什么必须这样做：`AWSS3TransferUtility` 对**已取消**的 upload task 会在
/// `URLSession:task:didCompleteWithError:` 里直接 `cleanupForUploadTask` 然后 `return`，
/// 不再回调 completionHandler。裸 continuation 只挂在 completionHandler 上时，
/// 取消一次就永久悬挂，而且 AWS 仍强持有着 block，连运行时的
/// "leaked its continuation" 警告都不会打印，问题完全静默。
///
/// 同时它自带两层保护：
/// - **结果早于安装**：`withTaskCancellationHandler` 的 `onCancel` 可能在 body 走到
///   `withCheckedThrowingContinuation` 之前就触发，此时结果先存下来，安装时立刻兑现。
/// - **重复 resume**：`AWSS3TransferUtility.register` 会把同一个 completionHandler
///   同时交给 `init` 和 `recover:`，存在被调用两次的可能；裸 continuation 遇到这种情况
///   会直接崩（SWIFT TASK CONTINUATION MISUSE），这里第二次起静默丢弃。
final class AWSContinuationBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isFinished = false

    /// - Returns: `false` 表示结果早于 continuation 抵达，方法内部已经 resume，
    ///   调用方应当直接返回，不要再启动真正的异步操作。
    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let pendingResult {
            isFinished = true
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        // pendingResult 也要挡：结果早于安装时同样是"第一个结果胜出"，
        // 否则 onCancel 先存下的 .cancelled 会被随后到达的回调覆盖掉
        guard !isFinished, pendingResult == nil else {
            lock.unlock()
            return
        }
        if let continuation {
            isFinished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        pendingResult = result
        lock.unlock()
    }

    func succeed(_ value: Value) {
        resolve(.success(value))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }
}
