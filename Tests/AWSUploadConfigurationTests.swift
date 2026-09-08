import XCTest
@testable import AWSUploader

final class AWSUploadConfigurationTests: XCTestCase {
    func testObjectKeyJoinsPrefixWithOneSlash() throws {
        XCTAssertEqual(
            try AWSUploader.objectKey(prefix: "/users/42/", objectName: "/photo.jpeg"),
            "users/42/photo.jpeg"
        )
    }

    func testObjectKeyWithoutPrefixUsesObjectName() throws {
        XCTAssertEqual(
            try AWSUploader.objectKey(prefix: nil, objectName: "folder/photo.jpeg"),
            "folder/photo.jpeg"
        )
    }

    func testObjectKeyRejectsOnlySlashes() {
        XCTAssertThrowsError(
            try AWSUploader.objectKey(prefix: "users/42", objectName: "///")
        )
    }

    func testDefaultCompressionOptionsAreValid() throws {
        XCTAssertNoThrow(try AWSImageCompressionOptions.default.validate())
    }

    func testCompressionOptionsRejectInvalidQualityRange() {
        var options = AWSImageCompressionOptions.default
        options.minimumQuality = 0.9
        options.initialQuality = 0.8
        XCTAssertThrowsError(try options.validate())
    }
}
