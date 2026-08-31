import Foundation

public struct DailyTokenUsage: Equatable, Sendable {
    public let startDate: String
    public let tokens: Int64

    public init(startDate: String, tokens: Int64) {
        self.startDate = startDate
        self.tokens = tokens
    }
}

public struct TokenUsageSnapshot: Equatable, Sendable {
    public let dailyUsage: [DailyTokenUsage]
    public let lifetimeTokens: Int64?
    public let updatedAt: Date

    public init(dailyUsage: [DailyTokenUsage], lifetimeTokens: Int64?, updatedAt: Date) {
        self.dailyUsage = dailyUsage
        self.lifetimeTokens = lifetimeTokens
        self.updatedAt = updatedAt
    }

    public var latestStartDate: String? {
        dailyUsage.last?.startDate
    }

    public func tokens(on startDate: String) -> Int64? {
        dailyUsage.first(where: { $0.startDate == startDate })?.tokens
    }
}

public enum TokenUsageParseError: LocalizedError {
    case invalidEnvelope

    public var errorDescription: String? {
        "Codex 返回了无法识别的 token 用量数据。"
    }
}

public enum TokenUsageParser {
    public static func parseResponse(data: Data, now: Date = Date()) throws -> TokenUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil else {
            throw TokenUsageParseError.invalidEnvelope
        }

        let result = (root["result"] as? [String: Any]) ?? root
        let summary = dictionary(result["summary"])
        let lifetimeTokens = nonnegativeInteger64(
            summary?["lifetimeTokens"] ?? summary?["lifetime_tokens"]
        )

        let rawBuckets = array(
            result["dailyUsageBuckets"] ?? result["daily_usage_buckets"]
        ) ?? []

        var bucketsByDate: [String: DailyTokenUsage] = [:]
        for value in rawBuckets {
            guard let bucket = dictionary(value),
                  let startDate = nonEmptyString(bucket["startDate"] ?? bucket["start_date"]),
                  let tokens = nonnegativeInteger64(bucket["tokens"]) else {
                continue
            }

            bucketsByDate[startDate] = DailyTokenUsage(startDate: startDate, tokens: tokens)
        }

        return TokenUsageSnapshot(
            dailyUsage: bucketsByDate.values.sorted { $0.startDate < $1.startDate },
            lifetimeTokens: lifetimeTokens,
            updatedAt: now
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any]? {
        value as? [Any]
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonnegativeInteger64(_ value: Any?) -> Int64? {
        let parsed: Int64?
        if let number = value as? NSNumber {
            parsed = number.int64Value
        } else if let string = value as? String {
            parsed = Int64(string)
        } else {
            parsed = nil
        }

        guard let parsed, parsed >= 0 else { return nil }
        return parsed
    }
}
