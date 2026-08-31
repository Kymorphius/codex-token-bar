import XCTest
@testable import CodexTokenCore

final class DailyUsageHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testAggregatesIncreasesByCalendarDayAndIgnoresRegressions() throws {
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let day2 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day1))
        let reset = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: day1))
        let samples = [
            sample(day1.addingTimeInterval(-3_600), used: 20, reset: reset),
            sample(day1.addingTimeInterval(3_600), used: 22, reset: reset),
            sample(day1.addingTimeInterval(7_200), used: 21, reset: reset),
            sample(day1.addingTimeInterval(10_800), used: 23, reset: reset),
            sample(day2.addingTimeInterval(3_600), used: 26, reset: reset)
        ]

        let result = DailyUsageAggregator.aggregate(
            samples: samples,
            endingAt: day2.addingTimeInterval(12 * 3_600),
            dayCount: 2,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.usedPercent), [3, 3])
    }

    func testCountsUsageBeforeAndAfterAResetOnTheSameDay() throws {
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let oldReset = day.addingTimeInterval(12 * 3_600)
        let newReset = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: oldReset))
        let samples = [
            sample(day.addingTimeInterval(-3_600), used: 98, reset: oldReset),
            sample(day.addingTimeInterval(2 * 3_600), used: 100, reset: oldReset),
            sample(day.addingTimeInterval(13 * 3_600), used: 0, reset: newReset),
            sample(day.addingTimeInterval(16 * 3_600), used: 4, reset: newReset)
        ]

        let result = DailyUsageAggregator.aggregate(
            samples: samples,
            endingAt: day.addingTimeInterval(20 * 3_600),
            dayCount: 1,
            calendar: calendar
        )

        XCTAssertEqual(result.first?.usedPercent, 6)
    }

    func testMarksDatesWithoutSnapshotsAsUnavailable() throws {
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 19)))
        let day3 = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: day1))
        let reset = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: day1))
        let samples = [
            sample(day1.addingTimeInterval(3_600), used: 10, reset: reset),
            sample(day3.addingTimeInterval(3_600), used: 12, reset: reset)
        ]

        let result = DailyUsageAggregator.aggregate(
            samples: samples,
            endingAt: day3.addingTimeInterval(2 * 3_600),
            dayCount: 3,
            calendar: calendar
        )

        XCTAssertEqual(result[0].usedPercent, 0)
        XCTAssertNil(result[1].usedPercent)
        XCTAssertEqual(result[2].usedPercent, 2)
    }

    func testCompactsUnchangedSamplesButKeepsDayBoundariesAndChanges() throws {
        let day1 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20)))
        let day2 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day1))
        let reset = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: day1))
        let samples = [
            sample(day1.addingTimeInterval(3_600), used: 5, reset: reset),
            sample(day1.addingTimeInterval(7_200), used: 5, reset: reset.addingTimeInterval(2)),
            sample(day1.addingTimeInterval(10_800), used: 6, reset: reset),
            sample(day2.addingTimeInterval(3_600), used: 6, reset: reset)
        ]

        let compacted = DailyUsageAggregator.compact(samples: samples, calendar: calendar)

        XCTAssertEqual(compacted.count, 3)
        XCTAssertEqual(compacted[0].timestamp, samples[1].timestamp)
        XCTAssertEqual(compacted[1].usedPercent, 6)
        XCTAssertEqual(compacted[2].timestamp, samples[3].timestamp)
    }

    private func sample(_ timestamp: Date, used: Double, reset: Date) -> RateLimitUsageSample {
        RateLimitUsageSample(
            timestamp: timestamp,
            usedPercent: used,
            resetsAt: reset,
            windowDurationMinutes: 10_080
        )
    }
}
