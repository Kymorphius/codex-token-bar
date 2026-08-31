using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Win32;

namespace CodexTokenBar.Windows;

internal sealed record GitHubRelease(string Version, string PageUrl, string? DownloadUrl);

internal static class AppSettings
{
    private const string KeyPath = @"Software\333.dev\CodexTokenBar";
    public static string XBrowserLanguage
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue("XBrowserLanguage") as string ?? "system";
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
            key.SetValue("XBrowserLanguage", value, RegistryValueKind.String);
        }
    }

    public static bool AutomaticUpdateChecks
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(KeyPath);
            return key?.GetValue("AutomaticUpdateChecks") is int value && value != 0;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(KeyPath, writable: true);
            key.SetValue("AutomaticUpdateChecks", value ? 1 : 0, RegistryValueKind.DWord);
        }
    }
}

internal sealed class GitHubUpdateChecker
{
    private static readonly HttpClient Client = CreateClient();

    public async Task<(GitHubRelease? Release, string? LatestVersion)> CheckAsync(string currentVersion)
    {
        using var response = await Client.GetAsync("https://api.github.com/repos/Kymorphius/codex-token-bar/releases/latest");
        if (response.StatusCode == System.Net.HttpStatusCode.NotFound) return (null, null);
        response.EnsureSuccessStatusCode();
        using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        var root = document.RootElement;
        var latest = Normalize(root.GetProperty("tag_name").GetString() ?? "0");
        var page = root.GetProperty("html_url").GetString()!;
        string? download = null;
        if (root.TryGetProperty("assets", out var assets))
        {
            download = assets.EnumerateArray()
                .Where(asset => asset.GetProperty("name").GetString()?.Contains("Windows", StringComparison.OrdinalIgnoreCase) == true ||
                                asset.GetProperty("name").GetString()?.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) == true)
                .Select(asset => asset.GetProperty("browser_download_url").GetString())
                .FirstOrDefault(value => value is not null);
        }
        return IsNewer(latest, currentVersion)
            ? (new GitHubRelease(latest, page, download), latest)
            : (null, latest);
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("CodexTokenBar", "1.3.1"));
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    private static string Normalize(string version) => version.Trim().TrimStart('v', 'V').Split('-', '+')[0];
    private static bool IsNewer(string candidate, string current)
    {
        var left = Normalize(candidate).Split('.').Select(part => int.TryParse(part, out var value) ? value : 0).ToArray();
        var right = Normalize(current).Split('.').Select(part => int.TryParse(part, out var value) ? value : 0).ToArray();
        for (var index = 0; index < Math.Max(left.Length, right.Length); index++)
        {
            var lhs = index < left.Length ? left[index] : 0;
            var rhs = index < right.Length ? right[index] : 0;
            if (lhs != rhs) return lhs > rhs;
        }
        return false;
    }
}
