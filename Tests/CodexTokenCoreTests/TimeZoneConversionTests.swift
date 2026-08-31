import XCTest
@testable import CodexTokenCore

final class TimeZoneConversionTests: XCTestCase {
    func testPacificTimeUsesPSTInWinter() throws {
        let date = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")
        )

        XCTAssertEqual(
            TimeZoneConversion.hourDifference(
                from: TimeZoneConversion.beijingTimeZone,
                to: TimeZoneConversion.pacificTimeZone,
                at: date
            ),
            -16
        )
        XCTAssertEqual(TimeZoneConversion.pacificAbbreviation(at: date), "PST")

        let components = TimeZoneConversion.wallClockComponents(
            for: date,
            in: TimeZoneConversion.pacificTimeZone
        )
        XCTAssertEqual(components.hour, 4)
        XCTAssertEqual(components.day, 15)
    }

    func testPacificTimeUsesPDTInSummer() throws {
        let date = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")
        )

        XCTAssertEqual(
            TimeZoneConversion.hourDifference(
                from: TimeZoneConversion.beijingTimeZone,
                to: TimeZoneConversion.pacificTimeZone,
                at: date
            ),
            -15
        )
        XCTAssertEqual(TimeZoneConversion.pacificAbbreviation(at: date), "PDT")

        let components = TimeZoneConversion.wallClockComponents(
            for: date,
            in: TimeZoneConversion.pacificTimeZone
        )
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.day, 15)
    }

    func testTweetPTTimeConvertsToBeijingUsingSummerTime() throws {
        let anchor = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-30T18:00:00Z")
        )
        let result = try XCTUnwrap(
            PacificTimeMentionConverter.conversions(
                in: "Office hours today at 2:30pm PT.",
                anchoredAt: anchor
            ).first
        )

        XCTAssertEqual(result.sourceAbbreviation, "PDT")
        let components = TimeZoneConversion.wallClockComponents(
            for: result.beijingDate,
            in: TimeZoneConversion.beijingTimeZone
        )
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 31)
        XCTAssertEqual(components.hour, 5)
        XCTAssertEqual(components.minute, 30)
    }

    func testTweetTomorrowPTUsesPacificAnchorDate() throws {
        let anchor = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-31T06:00:00Z")
        )
        let result = try XCTUnwrap(
            PacificTimeMentionConverter.conversions(
                in: "See you tomorrow at 10am PT!",
                anchoredAt: anchor
            ).first
        )
        let components = TimeZoneConversion.wallClockComponents(
            for: result.beijingDate,
            in: TimeZoneConversion.beijingTimeZone
        )
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 1)
    }

    func testExplicitPSTKeepsStandardOffsetEvenInSummer() throws {
        let anchor = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-30T18:00:00Z")
        )
        let result = try XCTUnwrap(
            PacificTimeMentionConverter.conversions(
                in: "Starts at 2pm PST",
                anchoredAt: anchor
            ).first
        )
        let components = TimeZoneConversion.wallClockComponents(
            for: result.beijingDate,
            in: TimeZoneConversion.beijingTimeZone
        )
        XCTAssertEqual(result.sourceAbbreviation, "PST")
        XCTAssertEqual(components.hour, 6)
    }

    func testTweetWithoutPacificZoneIsNotConverted() throws {
        let anchor = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-30T18:00:00Z")
        )
        XCTAssertTrue(
            PacificTimeMentionConverter.conversions(
                in: "Starts at 2pm tomorrow",
                anchoredAt: anchor
            ).isEmpty
        )
    }
}
