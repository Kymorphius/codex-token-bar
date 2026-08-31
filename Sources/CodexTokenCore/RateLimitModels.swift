import Foundation

public struct UsageWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let windowDurationMinutes: Int?
    public let resetsAt: Date?

    public init(usedPercent: Double, windowDurationMinutes: Int?, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }
}

public struct UsageBucket: Equatable, Sendable {
    public let id: String
    public let name: String?
    public let primary: UsageWindow?
    public let secondary: UsageWindow?
    public let planType: String?
    public let hasCredits: Bool?
    public let unlimitedCredits: Bool?
    public let creditBalance: String?
    public let rateLimitReachedType: String?

    public init(
        id: String,
        name: String?,
        primary: UsageWindow?,
        secondary: UsageWindow?,
        planType: String?,
        hasCredits: Bool?,
        unlimitedCredits: Bool?,
        creditBalance: String?,
        rateLimitReachedType: String?
    ) {
        self.id = id
        self.name = name
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.hasCredits = hasCredits
        self.unlimitedCredits = unlimitedCredits
        self.creditBalance = creditBalance
        self.rateLimitReachedType = rateLimitReachedType
    }

    public var headlineWindow: UsageWindow? {
        primary ?? secondary
    }
}

public struct RateLimitResetCredit: Equatable, Sendable {
    public let id: String
    public let resetType: String?
    public let status: String?
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?
    public let description: String?

    public init(
        id: String,
        resetType: String?,
        status: String?,
        grantedAt: Date?,
        expiresAt: Date?,
        title: String?,
        description: String?
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let buckets: [UsageBucket]
    public let availableResetCredits: Int?
    public let resetCredits: [RateLimitResetCredit]
    public let updatedAt: Date

    public init(
        buckets: [UsageBucket],
        availableResetCredits: Int?,
        resetCredits: [RateLimitResetCredit] = [],
        updatedAt: Date
    ) {
        self.buckets = buckets
        self.availableResetCredits = availableResetCredits
        self.resetCredits = resetCredits
        self.updatedAt = updatedAt
    }

    public var headlineBucket: UsageBucket? {
        if let codex = buckets.first(where: { $0.id == "codex" && $0.headlineWindow != nil }) {
            return codex
        }

        return buckets
            .filter { $0.headlineWindow != nil }
            .min {
                ($0.headlineWindow?.remainingPercent ?? 100) <
                    ($1.headlineWindow?.remainingPercent ?? 100)
            }
    }
}

public enum ResetCountdownFormatter {
    public static func string(until resetDate: Date, now: Date = Date()) -> String {
        let remainingSeconds = resetDate.timeIntervalSince(now)

        guard remainingSeconds > 0 else {
            return "正在重置"
        }

        let totalHours = max(1, Int(ceil(remainingSeconds / 3_600)))
        let days = totalHours / 24
        let hours = totalHours % 24

        if days > 0, hours > 0 {
            return "还有 \(days) 天 \(hours) 小时"
        }
        if days > 0 {
            return "还有 \(days) 天"
        }
        return "还有 \(hours) 小时"
    }
}

public enum DailyAllowanceCalculator {
    public static func percentPerDay(
        remainingPercent: Double,
        until resetDate: Date,
        now: Date = Date()
    ) -> Double? {
        let remainingSeconds = resetDate.timeIntervalSince(now)
        guard remainingSeconds > 0, remainingPercent > 0 else {
            return nil
        }

        let remainingDays = remainingSeconds / 86_400
        return remainingPercent / remainingDays
    }
}

public enum RateLimitParseError: LocalizedError {
    case invalidEnvelope
    case noRateLimits

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Codex 返回了无法识别的数据。"
        case .noRateLimits:
            return "Codex 没有返回可显示的额度。"
        }
    }
}

public enum RateLimitParser {
    public static func parseResponse(data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RateLimitParseError.invalidEnvelope
        }
        guard root["error"] == nil else { throw RateLimitParseError.invalidEnvelope }

        let result = (root["result"] as? [String: Any]) ?? root
        return try parseResult(result, now: now)
    }

    public static func parseResult(_ result: [String: Any], now: Date = Date()) throws -> UsageSnapshot {
        var buckets: [UsageBucket] = []

        if let byID = dictionary(result["rateLimitsByLimitId"] ?? result["rate_limits_by_limit_id"]) {
            for (fallbackID, value) in byID {
                guard let rawBucket = dictionary(value) else { continue }
                if let bucket = parseBucket(rawBucket, fallbackID: fallbackID) {
                    buckets.append(bucket)
                }
            }
        }

        if buckets.isEmpty,
           let rawBucket = dictionary(result["rateLimits"] ?? result["rate_limits"]),
           let bucket = parseBucket(rawBucket, fallbackID: "codex") {
            buckets.append(bucket)
        }

        guard !buckets.isEmpty else {
            throw RateLimitParseError.noRateLimits
        }

        buckets.sort { lhs, rhs in
            if lhs.id == "codex" { return rhs.id != "codex" }
            if rhs.id == "codex" { return false }
            return displayName(for: lhs).localizedCaseInsensitiveCompare(displayName(for: rhs)) == .orderedAscending
        }

        let resetCredits = dictionary(result["rateLimitResetCredits"] ?? result["rate_limit_reset_credits"])
        let availableCount = integer(
            resetCredits?["availableCount"] ?? resetCredits?["available_count"]
        ).map { max(0, $0) }
        var resetCreditDetails = array(resetCredits?["credits"])
            .compactMap(dictionary)
            .compactMap(parseResetCredit)
        resetCreditDetails.sort(by: resetCreditSort)

        return UsageSnapshot(
            buckets: buckets,
            availableResetCredits: availableCount,
            resetCredits: resetCreditDetails,
            updatedAt: now
        )
    }

    private static func parseResetCredit(_ raw: [String: Any]) -> RateLimitResetCredit? {
        guard let id = nonEmptyString(raw["id"]) else { return nil }

        let grantedTimestamp = number(raw["grantedAt"] ?? raw["granted_at"])
        let expiryTimestamp = number(raw["expiresAt"] ?? raw["expires_at"])

        return RateLimitResetCredit(
            id: id,
            resetType: nonEmptyString(raw["resetType"] ?? raw["reset_type"]),
            status: nonEmptyString(raw["status"]),
            grantedAt: grantedTimestamp.map(Date.init(timeIntervalSince1970:)),
            expiresAt: expiryTimestamp.map(Date.init(timeIntervalSince1970:)),
            title: nonEmptyString(raw["title"]),
            description: nonEmptyString(raw["description"])
        )
    }

    private static func resetCreditSort(
        _ lhs: RateLimitResetCredit,
        _ rhs: RateLimitResetCredit
    ) -> Bool {
        switch (lhs.expiresAt, rhs.expiresAt) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate { return lhsDate < rhsDate }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
        return lhs.id < rhs.id
    }

    private static func parseBucket(_ raw: [String: Any], fallbackID: String) -> UsageBucket? {
        let id = string(raw["limitId"] ?? raw["limit_id"]) ?? fallbackID
        let primary = parseWindow(dictionary(raw["primary"]))
        let secondary = parseWindow(dictionary(raw["secondary"]))

        guard primary != nil || secondary != nil else { return nil }

        let credits = dictionary(raw["credits"])
        return UsageBucket(
            id: id,
            name: nonEmptyString(raw["limitName"] ?? raw["limit_name"]),
            primary: primary,
            secondary: secondary,
            planType: nonEmptyString(raw["planType"] ?? raw["plan_type"]),
            hasCredits: boolean(credits?["hasCredits"] ?? credits?["has_credits"]),
            unlimitedCredits: boolean(credits?["unlimited"]),
            creditBalance: string(credits?["balance"]),
            rateLimitReachedType: nonEmptyString(raw["rateLimitReachedType"] ?? raw["rate_limit_reached_type"])
        )
    }

    private static func parseWindow(_ raw: [String: Any]?) -> UsageWindow? {
        guard let raw, let usedPercent = number(raw["usedPercent"] ?? raw["used_percent"]) else {
            return nil
        }

        let duration = integer(
            raw["windowDurationMins"] ?? raw["window_duration_mins"] ?? raw["window_minutes"]
        )
        let resetTimestamp = number(raw["resetsAt"] ?? raw["resets_at"])

        return UsageWindow(
            usedPercent: usedPercent,
            windowDurationMinutes: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func displayName(for bucket: UsageBucket) -> String {
        bucket.name ?? bucket.id
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
