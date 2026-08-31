import Foundation

public enum TimeZoneConversion {
    public static let beijingTimeZone = TimeZone(identifier: "Asia/Shanghai")!
    public static let pacificTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    public static func wallClockComponents(
        for date: Date,
        in timeZone: TimeZone
    ) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
    }

    public static func hourDifference(
        from source: TimeZone,
        to destination: TimeZone,
        at date: Date
    ) -> Double {
        let seconds = destination.secondsFromGMT(for: date) - source.secondsFromGMT(for: date)
        return Double(seconds) / 3_600
    }

    public static func pacificAbbreviation(at date: Date) -> String {
        pacificTimeZone.isDaylightSavingTime(for: date) ? "PDT" : "PST"
    }
}
