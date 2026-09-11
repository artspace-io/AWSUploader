// 普通 import，不用 @testable：这是对外可见的推导，App 侧也可能拿它来打日志核对。
import XCTest
import AWSUploader

/// 锁死一个真实线上缺陷：utilityKey 曾经是 `UUID().uuidString`，每次冷启动都变。
/// 它决定后台 URLSession 的 identifier，不稳定会导致每次启动遗弃一个后台 session、
/// 传输记录库里堆积永不回收的孤儿行，且 handleEventsForBackgroundURLSession 永远匹配不上。
final class AWSUtilityKeyTests: XCTestCase {
    private func configuration(
        bucket: String = "hairstylea",
        region: String = "ap-northeast-1",
        suffix: String? = nil
    ) -> AWSUploadConfiguration {
        AWSUploadConfiguration(
            bucket: bucket,
            region: region,
            sessionIdentifierSuffix: suffix
        )
    }

    /// 本次 bug 的直接回归：同一份配置反复推导必须得到同一个 key。
    func testKeyIsStableAcrossRepeatedDerivations() {
        let config = configuration()
        let first = AWSUtilityKey.makeUtilityKey(configuration: config)
        let second = AWSUtilityKey.makeUtilityKey(configuration: config)
        let third = AWSUtilityKey.makeUtilityKey(
            configuration: configuration()
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, third, "相同配置的两个独立实例也必须算出同一个 key")

        // 直接盯死旧实现：key 里不允许再出现 UUID 形状的片段
        let uuidShape = try? NSRegularExpression(
            pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        )
        let range = NSRange(first.startIndex..<first.endIndex, in: first)
        XCTAssertEqual(
            uuidShape?.numberOfMatches(in: first, range: range),
            0,
            "key 里不应再含 UUID"
        )
    }

    func testKeyIsDerivedFromBucketAndRegion() {
        XCTAssertEqual(
            AWSUtilityKey.makeUtilityKey(configuration: configuration()),
            "com.artspace.AWSUploader.hairstylea.ap-northeast-1"
        )
    }

    func testDifferentTargetsGetDifferentKeys() {
        let a = AWSUtilityKey.makeUtilityKey(configuration: configuration(bucket: "bucket-a"))
        let b = AWSUtilityKey.makeUtilityKey(configuration: configuration(bucket: "bucket-b"))
        let c = AWSUtilityKey.makeUtilityKey(configuration: configuration(region: "us-east-1"))

        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testExplicitSuffixOverridesDerivation() {
        XCTAssertEqual(
            AWSUtilityKey.makeUtilityKey(configuration: configuration(suffix: "avatars")),
            "com.artspace.AWSUploader.avatars"
        )
    }

    func testIllegalCharactersAreReplaced() {
        let key = AWSUtilityKey.makeUtilityKey(configuration: configuration(suffix: "a b/c#d中文"))
        XCTAssertEqual(key, "com.artspace.AWSUploader.a-b-c-d--")
    }

    func testEmptySuffixFallsBackToPlaceholder() {
        XCTAssertEqual(
            AWSUtilityKey.makeUtilityKey(configuration: configuration(suffix: "")),
            "com.artspace.AWSUploader.default"
        )
    }
}
