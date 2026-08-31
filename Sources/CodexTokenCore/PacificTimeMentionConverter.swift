import Foundation

public struct PacificTimeMentionConversion: Equatable {
    public let sourceText: String
    public let sourceDate: Date
    public let beijingDate: Date
    public let sourceAbbreviation: String

    public init(
        sourceText: String,
        sourceDate: Date,
        beijingDate: Date,
        sourceAbbreviation: String
    ) {
        self.sourceText = sourceText
        self.sourceDate = sourceDate
        self.beijingDate = beijingDate
        self.sourceAbbreviation = sourceAbbreviation
    }
}

public enum PacificTimeMentionConverter {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?i)\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(Pacific(?:\s+Standard|\s+Daylight)?\s+Time|PST|PDT|PT)\b"#
    )

    private static let weekdayNames: [(name: String, weekday: Int)] = [
        ("sunday", 1), ("monday", 2), ("tuesday", 3), ("wednesday", 4),
        ("thursday", 5), ("friday", 6), ("saturday", 7)
    ]

    public static func conversions(
        in text: String,
        anchoredAt anchorDate: Date
    ) -> [PacificTimeMentionConversion] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard
                let hourText = substring(text, range: match.range(at: 1)),
                let rawHour = Int(hourText),
                let zoneText = substring(text, range: match.range(at: 4)),
                let sourceText = substring(text, range: match.range)
            else { return nil }

            let minute = substring(text, range: match.range(at: 2)).flatMap(Int.init) ?? 0
            guard minute < 60, let hour = normalizedHour(
                rawHour,
                meridiem: substring(text, range: match.range(at: 3))
            ) else { return nil }

            let sourceTimeZone = timeZone(for: zoneText)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = sourceTimeZone

            let nearbyText = context(before: match.range.location, in: text).lowercased()
            guard let sourceDate = resolvedDate(
                anchorDate: anchorDate,
                hour: hour,
                minute: minute,
                nearbyText: nearbyText,
                calendar: calendar
            ) else { return nil }

            let abbreviation: String
            switch zoneText.uppercased() {
            case "PST", "PACIFIC STANDARD TIME": abbreviation = "PST"
            case "PDT", "PACIFIC DAYLIGHT TIME": abbreviation = "PDT"
            default: abbreviation = TimeZoneConversion.pacificAbbreviation(at: sourceDate)
            }

            return PacificTimeMentionConversion(
                sourceText: sourceText,
                sourceDate: sourceDate,
                beijingDate: sourceDate,
                sourceAbbreviation: abbreviation
            )
        }
    }

    private static func normalizedHour(_ hour: Int, meridiem: String?) -> Int? {
        guard hour >= 0, hour <= 23 else { return nil }
        guard let meridiem = meridiem?.lowercased() else { return hour }
        if hour > 12 { return hour } // Tolerate informal text such as “14pm PT”.
        guard hour >= 1 else { return nil }
        if meridiem == "am" { return hour == 12 ? 0 : hour }
        return hour == 12 ? 12 : hour + 12
    }

    private static func timeZone(for zoneText: String) -> TimeZone {
        switch zoneText.uppercased() {
        case "PST", "PACIFIC STANDARD TIME":
            return TimeZone(secondsFromGMT: -8 * 3_600)!
        case "PDT", "PACIFIC DAYLIGHT TIME":
            return TimeZone(secondsFromGMT: -7 * 3_600)!
        default:
            return TimeZoneConversion.pacificTimeZone
        }
    }

    private static func resolvedDate(
        anchorDate: Date,
        hour: Int,
        minute: Int,
        nearbyText: String,
        calendar: Calendar
    ) -> Date? {
        var dayOffset = 0
        if nearbyText.range(of: #"\btomorrow\b"#, options: .regularExpression) != nil {
            dayOffset = 1
        } else if nearbyText.range(of: #"\byesterday\b"#, options: .regularExpression) != nil {
            dayOffset = -1
        } else if let weekday = weekdayNames.last(where: {
            nearbyText.range(of: #"\b\#($0.name)\b"#, options: .regularExpression) != nil
        })?.weekday {
            let anchorWeekday = calendar.component(.weekday, from: anchorDate)
            dayOffset = (weekday - anchorWeekday + 7) % 7
            if nearbyText.range(of: #"\bnext\s+\w+$"#, options: .regularExpression) != nil,
               dayOffset == 0 {
                dayOffset = 7
            }
        }

        guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: anchorDate) else {
            return nil
        }
        var components = calendar.dateComponents([.year, .month, .day], from: targetDay)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)
    }

    private static func context(before utf16Location: Int, in text: String) -> String {
        let nsText = text as NSString
        let start = max(0, utf16Location - 48)
        return nsText.substring(with: NSRange(location: start, length: utf16Location - start))
    }

    private static func substring(_ text: String, range: NSRange) -> String? {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }
}
