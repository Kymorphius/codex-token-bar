import XCTest
@testable import CodexTokenCore

final class RateLimitParserTests: XCTestCase {
    func testParsesMultipleBucketsAndPrefersCodexForHeadline() throws {
        let json = #"""
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": { "usedPercent": 77, "windowDurationMins": 10080, "resetsAt": 1787013641 }
            },
            "rateLimitsByLimitId": {
              "codex_bengalfox": {
                "limitId": "codex_bengalfox",
                "limitName": "GPT-5.3-Codex-Spark",
                "primary": { "usedPercent": 72, "windowDurationMins": 10080, "resetsAt": 1787014740 }
              },
              "codex": {
                "limitId": "codex",
                "primary": { "usedPercent": 77, "windowDurationMins": 10080, "resetsAt": 1787013641 },
                "planType": "pro"
              }
            },
            "rateLimitResetCredits": { "availableCount": 0, "credits": [] }
          }
        }
        """#.data(using: .utf8)!

        let snapshot = try RateLimitParser.parseResponse(
            data: json,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(snapshot.buckets.map(\.id), ["codex", "codex_bengalfox"])
        XCTAssertEqual(snapshot.headlineBucket?.id, "codex")
        XCTAssertEqual(snapshot.headlineBucket?.primary?.remainingPercent, 23)
        XCTAssertEqual(snapshot.buckets[1].primary?.remainingPercent, 28)
        XCTAssertEqual(snapshot.availableResetCredits, 0)
    }

    func testParsesBackwardCompatibleSingleBucket() throws {
        let json = #"""
        {
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "limitName": null,
              "primary": { "usedPercent": 25.5, "windowDurationMins": 300, "resetsAt": 1730947200 },
              "secondary": null,
              "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" },
              "planType": "plus"
            }
          }
        }
        """#.data(using: .utf8)!

        let snapshot = try RateLimitParser.parseResponse(data: json)
        let bucket = try XCTUnwrap(snapshot.headlineBucket)

        XCTAssertEqual(snapshot.buckets.count, 1)
        XCTAssertEqual(bucket.primary?.remainingPercent, 74.5)
        XCTAssertEqual(bucket.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(bucket.hasCredits, true)
        XCTAssertEqual(bucket.creditBalance, "12.50")
        XCTAssertEqual(bucket.planType, "plus")
    }

    func testParsesAndSortsResetCreditExpiryDetails() throws {
        let json = #"""
        {
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": { "usedPercent": 25, "windowDurationMins": 10080 }
            },
            "rateLimitResetCredits": {
              "availableCount": 3,
              "credits": [
                {
                  "id": "later",
                  "resetType": "codexRateLimits",
                  "status": "available",
                  "grantedAt": 1781654400,
                  "expiresAt": 1784246400,
                  "title": "Rate-limit reset",
                  "description": "Reset an eligible Codex rate-limit window."
                },
                {
                  "id": "unknown-expiry",
                  "status": "available",
                  "expiresAt": null
                },
                {
                  "id": "sooner",
                  "status": "available",
                  "expiresAt": 1783036800
                }
              ]
            }
          }
        }
        """#.data(using: .utf8)!

        let snapshot = try RateLimitParser.parseResponse(data: json)

        XCTAssertEqual(snapshot.availableResetCredits, 3)
        XCTAssertEqual(snapshot.resetCredits.map(\.id), ["sooner", "later", "unknown-expiry"])
        XCTAssertEqual(
            snapshot.resetCredits[0].expiresAt,
            Date(timeIntervalSince1970: 1_783_036_800)
        )
        XCTAssertEqual(snapshot.resetCredits[1].resetType, "codexRateLimits")
        XCTAssertEqual(snapshot.resetCredits[1].title, "Rate-limit reset")
        XCTAssertNil(snapshot.resetCredits[2].expiresAt)
    }

    func testKeepsAuthoritativeResetCountWhenDetailsAreMissing() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 25]
            ],
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": NSNull()
            ]
        ]

        let snapshot = try RateLimitParser.parseResult(result)

        XCTAssertEqual(snapshot.availableResetCredits, 2)
        XCTAssertTrue(snapshot.resetCredits.isEmpty)
    }

    func testParsesSnakeCaseSessionShapeAndClampsRemainingPercent() throws {
        let result: [String: Any] = [
            "rate_limits": [
                "limit_id": "codex",
                "primary": [
                    "used_percent": 104,
                    "window_minutes": 60,
                    "resets_at": 1_730_947_200
                ],
                "plan_type": "pro"
            ]
        ]

        let snapshot = try RateLimitParser.parseResult(result)
        XCTAssertEqual(snapshot.headlineBucket?.primary?.remainingPercent, 0)
        XCTAssertEqual(snapshot.headlineBucket?.primary?.windowDurationMinutes, 60)
    }

    func testRejectsResponseWithoutAnyWindow() {
        XCTAssertThrowsError(try RateLimitParser.parseResult(["rateLimits": ["limitId": "codex"]]))
    }

    func testResetCountdownShowsDaysAndHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval((5 * 24 + 13) * 3_600)

        XCTAssertEqual(
            ResetCountdownFormatter.string(until: reset, now: now),
            "还有 5 天 13 小时"
        )
    }

    func testResetCountdownRoundsPartialHoursUp() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            ResetCountdownFormatter.string(until: now.addingTimeInterval(3_601), now: now),
            "还有 2 小时"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(until: now.addingTimeInterval(60), now: now),
            "还有 1 小时"
        )
    }

    func testResetCountdownHandlesWholeDaysAndExpiredWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            ResetCountdownFormatter.string(until: now.addingTimeInterval(2 * 24 * 3_600), now: now),
            "还有 2 天"
        )
        XCTAssertEqual(
            ResetCountdownFormatter.string(until: now, now: now),
            "正在重置"
        )
    }

    func testDailyAllowanceUsesFractionalDaysUntilReset() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = now.addingTimeInterval((6 * 24 + 12) * 3_600)

        let allowance = try XCTUnwrap(
            DailyAllowanceCalculator.percentPerDay(
                remainingPercent: 91,
                until: reset,
                now: now
            )
        )

        XCTAssertEqual(allowance, 14, accuracy: 0.000_1)
    }

    func testDailyAllowanceReturnsNilAfterResetOrWithNoRemainingUsage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(
            DailyAllowanceCalculator.percentPerDay(
                remainingPercent: 50,
                until: now,
                now: now
            )
        )
        XCTAssertNil(
            DailyAllowanceCalculator.percentPerDay(
                remainingPercent: 0,
                until: now.addingTimeInterval(86_400),
                now: now
            )
        )
    }
}
