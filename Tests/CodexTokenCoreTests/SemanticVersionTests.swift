import XCTest
@testable import CodexTokenCore

final class SemanticVersionTests: XCTestCase {
    func testRecognizesNewerVersions() {
        XCTAssertTrue(SemanticVersion.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(SemanticVersion.isNewer("v2.0", than: "1.99.99"))
        XCTAssertTrue(SemanticVersion.isNewer("1.10.0", than: "1.9.9"))
    }

    func testRejectsEqualAndOlderVersions() {
        XCTAssertFalse(SemanticVersion.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(SemanticVersion.isNewer("1.0.9", than: "1.1.0"))
    }

    func testIgnoresLeadingVAndPrereleaseSuffixForNumericComparison() {
        XCTAssertEqual(SemanticVersion.normalized(" v1.2.3 "), "1.2.3")
        XCTAssertTrue(SemanticVersion.isNewer("1.2.4-beta", than: "1.2.3"))
    }
}
