import Foundation

enum DisplayTimeZoneSettings {
    private static let key = "display-time-zone-identifier-v1"

    static var manualIdentifier: String? {
        get {
            guard let identifier = UserDefaults.standard.string(forKey: key),
                  TimeZone(identifier: identifier) != nil
            else { return nil }
            return identifier
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    static var timeZone: TimeZone {
        manualIdentifier.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
    }

    static var name: String {
        displayName(for: timeZone)
    }

    static func displayName(for timeZone: TimeZone, at date: Date = Date()) -> String {
        let localized = timeZone.localizedName(
            for: timeZone.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard,
            locale: .current
        ) ?? timeZone.identifier
        return "\(localized)（\(utcOffset(for: timeZone, at: date))）"
    }

    static func utcOffset(for timeZone: TimeZone, at date: Date = Date()) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        if seconds == 0 { return "UTC" }
        let sign = seconds >= 0 ? "+" : "−"
        let absolute = abs(seconds)
        let hours = absolute / 3_600
        let minutes = (absolute % 3_600) / 60
        return minutes == 0
            ? "UTC\(sign)\(hours)"
            : String(format: "UTC%@%d:%02d", sign, hours, minutes)
    }
}
