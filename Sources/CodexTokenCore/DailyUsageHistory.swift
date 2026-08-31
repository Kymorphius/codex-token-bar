import Foundation

public struct RateLimitUsageSample: Codable, Equatable, Hashable, Sendable {
    public let timestamp: Date
    public let usedPercent: Double
    public let resetsAt: Date
    public let windowDurationMinutes: Int

    public init(
        timestamp: Date,
        usedPercent: Double,
        resetsAt: Date,
        windowDurationMinutes: Int
    ) {
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
    }
}

public struct DailyUsageEstimate: Equatable, Sendable {
    public let date: Date
    public let usedPercent: Double?

    public init(date: Date, usedPercent: Double?) {
        self.date = date
        self.usedPercent = usedPercent
    }
}

public enum DailyUsageAggregator {
    public static func aggregate(
        samples: [RateLimitUsageSample],
        endingAt now: Date = Date(),
        dayCount: Int = 7,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [DailyUsageEstimate] {
        guard dayCount > 0 else { return [] }

        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else {
            return []
        }

        let days = (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: firstDay)
        }
        var totals = Dictionary(uniqueKeysWithValues: days.map { ($0, 0.0) })
        var observedDays = Set<Date>()

        let sortedSamples = samples
            .filter { $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }

        var cycleReset: Date?
        var cycleWindowMinutes: Int?
        var highWaterMark: Double?
        var hasSeenCycle = false

        for sample in sortedSamples {
            let sampleDay = calendar.startOfDay(for: sample.timestamp)
            if sampleDay >= firstDay, sampleDay <= today {
                observedDays.insert(sampleDay)
            }

            let sameCycle: Bool
            if let cycleReset, let cycleWindowMinutes {
                sameCycle = abs(cycleReset.timeIntervalSince(sample.resetsAt)) <= 300
                    && cycleWindowMinutes == sample.windowDurationMinutes
            } else {
                sameCycle = false
            }

            if !sameCycle {
                if hasSeenCycle, sampleDay >= firstDay, sampleDay <= today {
                    totals[sampleDay, default: 0] += max(0, sample.usedPercent)
                }
                cycleReset = sample.resetsAt
                cycleWindowMinutes = sample.windowDurationMinutes
                highWaterMark = sample.usedPercent
                hasSeenCycle = true
                continue
            }

            let previousHighWaterMark = highWaterMark ?? sample.usedPercent
            if sample.usedPercent > previousHighWaterMark {
                if sampleDay >= firstDay, sampleDay <= today {
                    totals[sampleDay, default: 0] += sample.usedPercent - previousHighWaterMark
                }
                highWaterMark = sample.usedPercent
            }
        }

        return days.map { day in
            DailyUsageEstimate(
                date: day,
                usedPercent: observedDays.contains(day) ? totals[day, default: 0] : nil
            )
        }
    }

    public static func compact(
        samples: [RateLimitUsageSample],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [RateLimitUsageSample] {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var result: [RateLimitUsageSample] = []

        for sample in sorted {
            guard let previous = result.last else {
                result.append(sample)
                continue
            }

            let sameDay = calendar.isDate(previous.timestamp, inSameDayAs: sample.timestamp)
            let sameUsage = abs(previous.usedPercent - sample.usedPercent) < 0.001
            let sameWindow = previous.windowDurationMinutes == sample.windowDurationMinutes
                && abs(previous.resetsAt.timeIntervalSince(sample.resetsAt)) <= 300

            if sameDay, sameUsage, sameWindow {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }

        return result
    }
}
