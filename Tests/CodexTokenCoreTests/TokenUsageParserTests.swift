import XCTest
@testable import CodexTokenCore

final class TokenUsageParserTests: XCTestCase {
    func testParsesOfficialDailyBucketsAndLargeLifetimeTotal() throws {
        let json = #"""
        {
          "id": 7,
          "result": {
            "summary": { "lifetimeTokens": 12345678901 },
            "dailyUsageBuckets": [
              { "startDate": "2026-08-20", "tokens": 123456789 },
              { "startDate": "2026-08-19", "tokens": 98765432 }
            ]
          }
        }
        """#.data(using: .utf8)!

        let now = Date(timeIntervalSince1970: 1_787_325_100)
        let snapshot = try TokenUsageParser.parseResponse(data: json, now: now)

        XCTAssertEqual(snapshot.lifetimeTokens, 12_345_678_901)
        XCTAssertEqual(snapshot.dailyUsage.map(\.startDate), ["2026-08-19", "2026-08-20"])
        XCTAssertEqual(snapshot.tokens(on: "2026-08-20"), 123_456_789)
        XCTAssertEqual(snapshot.latestStartDate, "2026-08-20")
        XCTAssertEqual(snapshot.updatedAt, now)
    }

    func testAcceptsNullDailyBucketsWithoutInventingZeroes() throws {
        let json = #"""
        {
          "result": {
            "summary": { "lifetimeTokens": null },
            "dailyUsageBuckets": null
          }
        }
        """#.data(using: .utf8)!

        let snapshot = try TokenUsageParser.parseResponse(data: json)

        XCTAssertNil(snapshot.lifetimeTokens)
        XCTAssertTrue(snapshot.dailyUsage.isEmpty)
        XCTAssertNil(snapshot.latestStartDate)
    }

    func testParsesSnakeCaseAndSkipsInvalidBuckets() throws {
        let json = #"""
        {
          "daily_usage_buckets": [
            { "start_date": "2026-08-18", "tokens": "246813579" },
            { "start_date": "", "tokens": 123 },
            { "start_date": "2026-08-17", "tokens": -1 }
          ]
        }
        """#.data(using: .utf8)!

        let snapshot = try TokenUsageParser.parseResponse(data: json)

        XCTAssertEqual(
            snapshot.dailyUsage,
            [DailyTokenUsage(startDate: "2026-08-18", tokens: 246_813_579)]
        )
    }
}
