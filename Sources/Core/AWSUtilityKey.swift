import Foundation

/// 后台 URLSession 标识符的推导。单独成文件、只依赖 Foundation，
/// 这样它可以脱离 AWSS3 依赖做单元测试 —— 本次 bug 的核心就是这个推导不稳定。
public enum AWSUtilityKey {
    /// utilityKey 决定后台 URLSession 的 identifier
    /// （SDK 会拼成 `com.amazonaws.AWSS3TransferUtility.Default.Identifier.<key>`，
    /// 再交给 `backgroundSessionConfigurationWithIdentifier:`），所以它**必须跨启动稳定**。
    ///
    /// 这里曾经用的是 `UUID().uuidString`，代价是每次冷启动都新建一个后台 session、
    /// 遗弃上一个（后台 session 由系统的 nsurlsessiond 持有，遗弃不等于释放），
    /// 并且在全局传输记录库里按新的 `ns_url_session_id` 写一批再也不会被读回、
    /// 也没有任何路径会清理的孤儿行。同时 `handleEventsForBackgroundURLSession`
    /// 传进来的 identifier 永远匹配不上任何已注册的 utility。
    ///
    /// 改用 bucket + region 推导：后台 session identifier 本来就按 App 隔离，
    /// 掺 bundleID 并不增加唯一性；而 bucket + region 恰好表达了"这是哪一个传输目标"，
    /// 换 bucket 时自然换 session，语义是对的。
    public static func makeUtilityKey(configuration: AWSUploadConfiguration) -> String {
        let rawSuffix = configuration.sessionIdentifierSuffix
            ?? "\(configuration.bucket).\(configuration.region)"
        return "com.artspace.AWSUploader.\(sanitizedIdentifierComponent(rawSuffix))"
    }

    /// bucket 和 region 本身就是 DNS 安全字符集，清洗纯属防御 ——
    /// 防止调用方传进奇怪的 bucket 名或自定义后缀污染 session identifier。
    private static func sanitizedIdentifierComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
            .union(CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"))
        let cleaned = String(
            value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        )
        return cleaned.isEmpty ? "default" : cleaned
    }
}
