import Foundation
import CodexTokenCore

final class UsageHistoryStore {
    var onChange: (() -> Void)?

    private(set) var entries: [DailyUsageEstimate] = []
    private(set) var heatmapEntries: [DailyUsageEstimate] = []
    private(set) var isLoading = false

    private let calendar = Calendar.autoupdatingCurrent
    private let ioQueue = DispatchQueue(label: "dev.333.codex-token-bar.usage-history", qos: .utility)
    private let historyURL: URL
    private var samples: [RateLimitUsageSample]
    private var completedFullSessionScan: Bool

    init() {
        historyURL = Self.makeHistoryURL()
        let archive = Self.loadHistory(from: historyURL)
        samples = archive.samples
        completedFullSessionScan = archive.completedFullSessionScan
        recalculate()
    }

    func start() {
        guard !isLoading else { return }
        isLoading = true
        onChange?()

        let scanDate = Date()
        let needsFullScan = !completedFullSessionScan

        ioQueue.async { [weak self] in
            let reader = SessionRateLimitHistoryReader()
            let discovered = needsFullScan
                ? reader.readAllSamples()
                : reader.readRecentSamples(dayCount: 3, endingAt: scanDate)

            DispatchQueue.main.async {
                guard let self else { return }
                if needsFullScan {
                    self.completedFullSessionScan = true
                }
                self.merge(discovered, persist: true)
                self.isLoading = false
                self.onChange?()
            }
        }
    }

    func record(snapshot: UsageSnapshot) {
        guard
            let bucket = snapshot.buckets.first(where: { $0.id == "codex" }),
            let window = bucket.primary,
            let resetsAt = window.resetsAt,
            let windowMinutes = window.windowDurationMinutes,
            windowMinutes >= 1_440
        else {
            return
        }

        let sample = RateLimitUsageSample(
            timestamp: snapshot.updatedAt,
            usedPercent: window.usedPercent,
            resetsAt: resetsAt,
            windowDurationMinutes: windowMinutes
        )

        if let latest = samples.last,
           calendar.isDate(latest.timestamp, inSameDayAs: sample.timestamp),
           abs(latest.usedPercent - sample.usedPercent) < 0.001,
           latest.windowDurationMinutes == sample.windowDurationMinutes,
           abs(latest.resetsAt.timeIntervalSince(sample.resetsAt)) <= 300 {
            return
        }

        merge([sample], persist: true)
        onChange?()
    }

    private func merge(_ newSamples: [RateLimitUsageSample], persist: Bool) {
        samples = DailyUsageAggregator.compact(
            samples: samples + newSamples,
            calendar: calendar
        )
        recalculate()

        if persist {
            saveHistory(samples)
        }
    }

    private func recalculate() {
        entries = DailyUsageAggregator.aggregate(
            samples: samples,
            endingAt: Date(),
            dayCount: 7,
            calendar: calendar
        )
        heatmapEntries = DailyUsageAggregator.aggregate(
            samples: samples,
            endingAt: Date(),
            dayCount: 365,
            calendar: calendar
        )
    }

    private func saveHistory(_ samples: [RateLimitUsageSample]) {
        let url = historyURL
        let didCompleteFullScan = completedFullSessionScan
        ioQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                let archive = StoredUsageHistory(
                    schemaVersion: 2,
                    completedFullSessionScan: didCompleteFullScan,
                    samples: samples
                )
                let data = try encoder.encode(archive)
                try data.write(to: url, options: .atomic)
            } catch {
                // History is an optional enhancement; live quota display must keep working.
            }
        }
    }

    private static func loadHistory(from url: URL) -> StoredUsageHistory {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        if let archive = try? decoder.decode(StoredUsageHistory.self, from: data) {
            return archive
        }
        if let legacySamples = try? decoder.decode([RateLimitUsageSample].self, from: data) {
            return StoredUsageHistory(
                schemaVersion: 2,
                completedFullSessionScan: false,
                samples: legacySamples
            )
        }
        return .empty
    }

    private static func makeHistoryURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        return applicationSupport
            .appendingPathComponent("Codex Token Bar", isDirectory: true)
            .appendingPathComponent("usage-history.json")
    }
}

private struct StoredUsageHistory: Codable {
    let schemaVersion: Int
    let completedFullSessionScan: Bool
    let samples: [RateLimitUsageSample]

    static let empty = StoredUsageHistory(
        schemaVersion: 2,
        completedFullSessionScan: false,
        samples: []
    )
}

private struct SessionRateLimitHistoryReader {
    private let tokenCountNeedle = Data(#""type":"token_count""#.utf8)
    private let rateLimitsNeedle = Data(#""rate_limits""#.utf8)
    private let fractionalTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeSecondsTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func readRecentSamples(
        dayCount: Int,
        endingAt now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [RateLimitUsageSample] {
        let sessionsRoot = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        var files: [URL] = []

        for offset in stride(from: -(dayCount - 1), through: 0, by: 1) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            let components = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = components.year, let month = components.month, let day = components.day else {
                continue
            }

            let directory = sessionsRoot
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", day), isDirectory: true)

            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
                files.append(fileURL)
            }
        }

        var samples: [RateLimitUsageSample] = []
        for file in files {
            readLines(from: file) { line in
                guard
                    line.range(of: tokenCountNeedle) != nil,
                    line.range(of: rateLimitsNeedle) != nil,
                    let sample = parseSample(from: line)
                else {
                    return
                }
                samples.append(sample)
            }
        }

        return samples
    }

    func readAllSamples() -> [RateLimitUsageSample] {
        let sessionsRoot = codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var samples: [RateLimitUsageSample] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            readLines(from: fileURL) { line in
                guard
                    line.range(of: tokenCountNeedle) != nil,
                    line.range(of: rateLimitsNeedle) != nil,
                    let sample = parseSample(from: line)
                else {
                    return
                }
                samples.append(sample)
            }
        }
        return samples
    }

    private var codexHomeURL: URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func readLines(from url: URL, body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: 128 * 1_024), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)

            var lineStart = buffer.startIndex
            while
                lineStart < buffer.endIndex,
                let newline = buffer[lineStart...].firstIndex(of: 0x0A)
            {
                let line = buffer.subdata(in: lineStart..<newline)
                if !line.isEmpty { body(line) }
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        if !buffer.isEmpty { body(buffer) }
    }

    private func parseSample(from data: Data) -> RateLimitUsageSample? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestampString = root["timestamp"] as? String,
            let timestamp = parseTimestamp(timestampString),
            let payload = root["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let limits = payload["rate_limits"] as? [String: Any],
            (limits["limit_id"] as? String) == "codex",
            let primary = limits["primary"] as? [String: Any],
            let usedPercent = number(primary["used_percent"] ?? primary["usedPercent"]),
            let resetTimestamp = number(primary["resets_at"] ?? primary["resetsAt"]),
            let windowMinutes = integer(
                primary["window_minutes"]
                    ?? primary["window_duration_mins"]
                    ?? primary["windowDurationMins"]
            ),
            windowMinutes >= 1_440
        else {
            return nil
        }

        return RateLimitUsageSample(
            timestamp: timestamp,
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetTimestamp),
            windowDurationMinutes: windowMinutes
        )
    }

    private func parseTimestamp(_ value: String) -> Date? {
        fractionalTimestampFormatter.date(from: value)
            ?? wholeSecondsTimestampFormatter.date(from: value)
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }
}
