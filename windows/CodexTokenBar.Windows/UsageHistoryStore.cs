using System.Text.Json;

namespace CodexTokenBar.Windows;

internal sealed record UsageHistoryEntry(DateOnly Date, double? UsedPercent);

internal sealed record StoredUsageSample(
    DateTimeOffset Timestamp,
    double UsedPercent,
    DateTimeOffset ResetsAt,
    int WindowDurationMinutes);

internal sealed class UsageHistoryStore
{
    private readonly string _filePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Codex Token Bar",
        "usage-history.json");
    private readonly object _lock = new();
    private List<StoredUsageSample> _samples;

    public UsageHistoryStore()
    {
        _samples = Load();
    }

    public IReadOnlyList<UsageHistoryEntry> Entries
    {
        get
        {
            lock (_lock) return Aggregate(7);
        }
    }

    public IReadOnlyList<UsageHistoryEntry> HeatmapEntries
    {
        get
        {
            lock (_lock) return Aggregate(365);
        }
    }

    public void Record(UsageSnapshot snapshot)
    {
        var bucket = snapshot.Buckets.FirstOrDefault(item => item.Id == "codex");
        var window = bucket?.Primary;
        if (window?.ResetsAt is not { } resetsAt || window.WindowDurationMinutes is not { } minutes || minutes < 1_440)
            return;

        lock (_lock)
        {
            var sample = new StoredUsageSample(snapshot.UpdatedAt, window.UsedPercent, resetsAt, minutes);
            var latest = _samples.LastOrDefault();
            if (latest is not null &&
                DateOnly.FromDateTime(latest.Timestamp.LocalDateTime) == DateOnly.FromDateTime(sample.Timestamp.LocalDateTime) &&
                Math.Abs(latest.UsedPercent - sample.UsedPercent) < 0.001 &&
                latest.WindowDurationMinutes == sample.WindowDurationMinutes &&
                Math.Abs((latest.ResetsAt - sample.ResetsAt).TotalMinutes) <= 5)
                return;

            _samples.Add(sample);
            _samples = Compact(_samples);
            Save();
        }
    }

    private IReadOnlyList<UsageHistoryEntry> Aggregate(int dayCount)
    {
        var today = DateOnly.FromDateTime(DateTime.Now);
        var firstDay = today.AddDays(-(dayCount - 1));
        var totals = Enumerable.Range(0, dayCount)
            .ToDictionary(offset => firstDay.AddDays(offset), _ => 0d);
        var observed = new HashSet<DateOnly>();
        StoredUsageSample? previous = null;
        double? highWaterMark = null;

        foreach (var sample in _samples.OrderBy(item => item.Timestamp))
        {
            var day = DateOnly.FromDateTime(sample.Timestamp.LocalDateTime);
            if (day >= firstDay && day <= today) observed.Add(day);
            var sameCycle = previous is not null &&
                            previous.WindowDurationMinutes == sample.WindowDurationMinutes &&
                            Math.Abs((previous.ResetsAt - sample.ResetsAt).TotalMinutes) <= 5;
            if (!sameCycle)
            {
                if (previous is not null && day >= firstDay && day <= today)
                    totals[day] += Math.Max(0, sample.UsedPercent);
                highWaterMark = sample.UsedPercent;
            }
            else if (sample.UsedPercent > highWaterMark)
            {
                if (day >= firstDay && day <= today)
                    totals[day] += sample.UsedPercent - highWaterMark!.Value;
                highWaterMark = sample.UsedPercent;
            }
            previous = sample;
        }

        return totals.Select(pair => new UsageHistoryEntry(
            pair.Key,
            observed.Contains(pair.Key) ? pair.Value : null)).ToArray();
    }

    private static List<StoredUsageSample> Compact(IEnumerable<StoredUsageSample> samples)
    {
        var result = new List<StoredUsageSample>();
        foreach (var sample in samples.OrderBy(item => item.Timestamp))
        {
            var previous = result.LastOrDefault();
            if (previous is not null &&
                DateOnly.FromDateTime(previous.Timestamp.LocalDateTime) == DateOnly.FromDateTime(sample.Timestamp.LocalDateTime) &&
                Math.Abs(previous.UsedPercent - sample.UsedPercent) < 0.001 &&
                previous.WindowDurationMinutes == sample.WindowDurationMinutes &&
                Math.Abs((previous.ResetsAt - sample.ResetsAt).TotalMinutes) <= 5)
                result[^1] = sample;
            else
                result.Add(sample);
        }
        return result;
    }

    private List<StoredUsageSample> Load()
    {
        try
        {
            if (!File.Exists(_filePath)) return [];
            return JsonSerializer.Deserialize<List<StoredUsageSample>>(File.ReadAllText(_filePath)) ?? [];
        }
        catch { return []; }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_filePath)!);
            var temporaryPath = _filePath + ".tmp";
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(_samples));
            File.Move(temporaryPath, _filePath, overwrite: true);
        }
        catch { }
    }
}
