using System.Globalization;
using System.Text.Json;

namespace CodexTokenBar.Windows;

internal sealed record UsageWindow(double UsedPercent, int? WindowDurationMinutes, DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => Math.Clamp(100 - UsedPercent, 0, 100);
}

internal sealed record UsageBucket(
    string Id,
    string? Name,
    UsageWindow? Primary,
    UsageWindow? Secondary,
    string? PlanType,
    bool? HasCredits,
    bool? UnlimitedCredits,
    string? CreditBalance,
    string? RateLimitReachedType)
{
    public UsageWindow? HeadlineWindow => Primary ?? Secondary;
    public string DisplayName => string.IsNullOrWhiteSpace(Name) ? Id : Name;
}

internal sealed record RateLimitResetCredit(
    string Id,
    string? Status,
    DateTimeOffset? ExpiresAt,
    string? Title);

internal sealed record UsageSnapshot(
    IReadOnlyList<UsageBucket> Buckets,
    int? AvailableResetCredits,
    IReadOnlyList<RateLimitResetCredit> ResetCredits,
    DateTimeOffset UpdatedAt)
{
    public UsageBucket? HeadlineBucket =>
        Buckets.FirstOrDefault(bucket => bucket.Id == "codex" && bucket.HeadlineWindow is not null)
        ?? Buckets.Where(bucket => bucket.HeadlineWindow is not null)
            .OrderBy(bucket => bucket.HeadlineWindow!.RemainingPercent)
            .FirstOrDefault();
}

internal static class RateLimitParser
{
    public static UsageSnapshot Parse(JsonElement root)
    {
        if (root.TryGetProperty("error", out var error) && error.ValueKind is not JsonValueKind.Null)
            throw new InvalidDataException(ServerError(error));

        var result = TryObject(root, "result") ?? root;
        var buckets = new List<UsageBucket>();
        var byId = TryObject(result, "rateLimitsByLimitId", "rate_limits_by_limit_id");

        if (byId is { } collection)
        {
            foreach (var property in collection.EnumerateObject())
            {
                if (property.Value.ValueKind != JsonValueKind.Object) continue;
                var bucket = ParseBucket(property.Value, property.Name);
                if (bucket is not null) buckets.Add(bucket);
            }
        }

        if (buckets.Count == 0)
        {
            var rawBucket = TryObject(result, "rateLimits", "rate_limits");
            if (rawBucket is { } value && ParseBucket(value, "codex") is { } bucket)
                buckets.Add(bucket);
        }

        if (buckets.Count == 0)
            throw new InvalidDataException("Codex 没有返回可显示的额度。");

        buckets.Sort((left, right) =>
        {
            if (left.Id == "codex") return right.Id == "codex" ? 0 : -1;
            if (right.Id == "codex") return 1;
            return StringComparer.CurrentCultureIgnoreCase.Compare(left.DisplayName, right.DisplayName);
        });

        int? availableCredits = null;
        var resetCreditDetails = new List<RateLimitResetCredit>();
        if (TryObject(result, "rateLimitResetCredits", "rate_limit_reset_credits") is { } credits)
        {
            availableCredits = Integer(credits, "availableCount", "available_count") is { } count
                ? Math.Max(0, count)
                : null;
            if (credits.TryGetProperty("credits", out var rawCredits) && rawCredits.ValueKind == JsonValueKind.Array)
            {
                foreach (var rawCredit in rawCredits.EnumerateArray())
                {
                    if (rawCredit.ValueKind != JsonValueKind.Object || Text(rawCredit, "id") is not { } id) continue;
                    DateTimeOffset? expiresAt = null;
                    if (Number(rawCredit, "expiresAt", "expires_at") is { } expiry)
                    {
                        try { expiresAt = DateTimeOffset.FromUnixTimeSeconds((long)expiry); }
                        catch (ArgumentOutOfRangeException) { }
                    }
                    resetCreditDetails.Add(new RateLimitResetCredit(
                        id,
                        Text(rawCredit, "status"),
                        expiresAt,
                        Text(rawCredit, "title")));
                }
            }
        }

        resetCreditDetails.Sort((left, right) => Nullable.Compare(left.ExpiresAt, right.ExpiresAt));
        return new UsageSnapshot(buckets, availableCredits, resetCreditDetails, DateTimeOffset.Now);
    }

    private static UsageBucket? ParseBucket(JsonElement raw, string fallbackId)
    {
        var primary = ParseWindow(TryObject(raw, "primary"));
        var secondary = ParseWindow(TryObject(raw, "secondary"));
        if (primary is null && secondary is null) return null;

        var credits = TryObject(raw, "credits");
        return new UsageBucket(
            Text(raw, "limitId", "limit_id") ?? fallbackId,
            Text(raw, "limitName", "limit_name"),
            primary,
            secondary,
            Text(raw, "planType", "plan_type"),
            credits is { } creditObject ? Boolean(creditObject, "hasCredits", "has_credits") : null,
            credits is { } unlimitedObject ? Boolean(unlimitedObject, "unlimited") : null,
            credits is { } balanceObject ? Text(balanceObject, "balance") : null,
            Text(raw, "rateLimitReachedType", "rate_limit_reached_type"));
    }

    private static UsageWindow? ParseWindow(JsonElement? raw)
    {
        if (raw is not { } value || Number(value, "usedPercent", "used_percent") is not { } used)
            return null;

        DateTimeOffset? resetsAt = null;
        if (Number(value, "resetsAt", "resets_at") is { } timestamp)
        {
            try { resetsAt = DateTimeOffset.FromUnixTimeSeconds((long)timestamp); }
            catch (ArgumentOutOfRangeException) { }
        }

        return new UsageWindow(
            used,
            Integer(value, "windowDurationMins", "window_duration_mins", "window_minutes"),
            resetsAt);
    }

    private static JsonElement? TryObject(JsonElement value, params string[] names)
    {
        foreach (var name in names)
            if (value.ValueKind == JsonValueKind.Object &&
                value.TryGetProperty(name, out var child) && child.ValueKind == JsonValueKind.Object)
                return child;
        return null;
    }

    private static string? Text(JsonElement value, params string[] names)
    {
        foreach (var name in names)
        {
            if (!value.TryGetProperty(name, out var child)) continue;
            var result = child.ValueKind switch
            {
                JsonValueKind.String => child.GetString(),
                JsonValueKind.Number => child.GetRawText(),
                _ => null
            };
            if (!string.IsNullOrWhiteSpace(result)) return result.Trim();
        }
        return null;
    }

    private static double? Number(JsonElement value, params string[] names)
    {
        foreach (var name in names)
        {
            if (!value.TryGetProperty(name, out var child)) continue;
            if (child.ValueKind == JsonValueKind.Number && child.TryGetDouble(out var number)) return number;
            if (child.ValueKind == JsonValueKind.String &&
                double.TryParse(child.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number))
                return number;
        }
        return null;
    }

    private static int? Integer(JsonElement value, params string[] names) =>
        Number(value, names) is { } number ? (int)number : null;

    private static bool? Boolean(JsonElement value, params string[] names)
    {
        foreach (var name in names)
        {
            if (!value.TryGetProperty(name, out var child)) continue;
            if (child.ValueKind == JsonValueKind.True) return true;
            if (child.ValueKind == JsonValueKind.False) return false;
            if (child.ValueKind == JsonValueKind.String && bool.TryParse(child.GetString(), out var parsed))
                return parsed;
        }
        return null;
    }

    private static string ServerError(JsonElement error) =>
        Text(error, "message") ?? "Codex 返回了未知错误。";
}

internal sealed record DailyTokenUsage(string StartDate, long Tokens);

internal sealed record TokenUsageSnapshot(IReadOnlyList<DailyTokenUsage> DailyUsage, long? LifetimeTokens)
{
    public string? LatestStartDate => DailyUsage.LastOrDefault()?.StartDate;
    public long? TokensOn(string startDate) => DailyUsage.FirstOrDefault(item => item.StartDate == startDate)?.Tokens;
}

internal static class TokenUsageParser
{
    public static TokenUsageSnapshot Parse(JsonElement root)
    {
        if (root.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null)
            throw new InvalidDataException("Codex 返回了无法识别的 token 用量数据。");

        var result = root.TryGetProperty("result", out var resultElement) && resultElement.ValueKind == JsonValueKind.Object
            ? resultElement
            : root;
        long? lifetime = null;
        if (result.TryGetProperty("summary", out var summary) && summary.ValueKind == JsonValueKind.Object)
            lifetime = NonnegativeInteger(summary, "lifetimeTokens", "lifetime_tokens");

        var byDate = new Dictionary<string, DailyTokenUsage>();
        JsonElement rawBuckets = default;
        var hasBuckets = result.TryGetProperty("dailyUsageBuckets", out rawBuckets) ||
                         result.TryGetProperty("daily_usage_buckets", out rawBuckets);
        if (hasBuckets && rawBuckets.ValueKind == JsonValueKind.Array)
        {
            foreach (var raw in rawBuckets.EnumerateArray())
            {
                if (raw.ValueKind != JsonValueKind.Object) continue;
                var startDate = String(raw, "startDate", "start_date");
                var tokens = NonnegativeInteger(raw, "tokens");
                if (startDate is not null && tokens is not null)
                    byDate[startDate] = new DailyTokenUsage(startDate, tokens.Value);
            }
        }
        return new TokenUsageSnapshot(byDate.Values.OrderBy(item => item.StartDate).ToArray(), lifetime);
    }

    private static string? String(JsonElement value, params string[] names)
    {
        foreach (var name in names)
            if (value.TryGetProperty(name, out var child) && child.ValueKind == JsonValueKind.String &&
                !string.IsNullOrWhiteSpace(child.GetString()))
                return child.GetString()!.Trim();
        return null;
    }

    private static long? NonnegativeInteger(JsonElement value, params string[] names)
    {
        foreach (var name in names)
        {
            if (!value.TryGetProperty(name, out var child)) continue;
            long parsed;
            if (child.ValueKind == JsonValueKind.Number && child.TryGetInt64(out parsed) && parsed >= 0) return parsed;
            if (child.ValueKind == JsonValueKind.String && long.TryParse(child.GetString(), out parsed) && parsed >= 0) return parsed;
        }
        return null;
    }
}
