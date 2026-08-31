using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace CodexTokenBar.Windows;

internal sealed record TiboFetchResult(IReadOnlyList<TiboPost> Posts, bool RepliesAvailable);

internal sealed partial class TiboRSSHubClient : IDisposable
{
    private const string RssHubVersion = "1.0.0-master.8aeb46b";
    private const string Marker = "CODEX_RSSHUB_RESULT:";
    private readonly string _runtimeRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Codex Token Bar", "rsshub-runtime");
    private Process? _process;

    public async Task<TiboFetchResult> FetchAsync(string authToken, IProgress<string>? progress = null, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(authToken)) throw new InvalidOperationException("需要先在应用内登录 X。");
        await EnsureRuntimeAsync(progress, cancellationToken);
        var node = FindExecutable("node.exe") ?? throw new InvalidOperationException("没有找到内置或系统 Node.js。");
        var runner = EnsureRunnerFile();
        var module = Path.Combine(_runtimeRoot, "node_modules", "rsshub", "dist-lib", "pkg.mjs");
        if (!File.Exists(module)) throw new InvalidOperationException("本机 RSSHub 组件不完整，请重新安装。");

        progress?.Report("本机 RSSHub 正在读取完整内容…");
        var startInfo = new ProcessStartInfo
        {
            FileName = node,
            WorkingDirectory = _runtimeRoot,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = Encoding.UTF8,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add(runner);
        startInfo.ArgumentList.Add(module);
        startInfo.ArgumentList.Add("/twitter/user/thsottiaux/includeReplies=0&includeRts=0&readable=1");
        startInfo.ArgumentList.Add("/twitter/user/thsottiaux/includeReplies=1&includeRts=0&readable=1");

        using var process = new Process { StartInfo = startInfo };
        _process = process;
        process.Start();
        await process.StandardInput.WriteAsync(JsonSerializer.Serialize(new { authToken }));
        process.StandardInput.Close();
        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var output = await outputTask;
        var stderr = await errorTask;
        _process = null;

        var markerIndex = output.LastIndexOf(Marker, StringComparison.Ordinal);
        if (markerIndex < 0)
            throw new InvalidOperationException("RSSHub 返回了无法识别的结果。" + ShortError(stderr));
        using var document = JsonDocument.Parse(output[(markerIndex + Marker.Length)..].Trim());
        var root = document.RootElement;
        if (root.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message))
            throw new InvalidOperationException("RSSHub：" + message.GetString());

        var posts = new Dictionary<string, TiboPost>(StringComparer.OrdinalIgnoreCase);
        var repliesAvailable = false;
        if (root.TryGetProperty("feeds", out var feeds) && feeds.ValueKind == JsonValueKind.Array)
        {
            foreach (var feed in feeds.EnumerateArray())
            {
                var route = feed.TryGetProperty("route", out var routeValue) ? routeValue.GetString() ?? "" : "";
                if (!feed.TryGetProperty("data", out var data)) continue;
                var parsed = ParsePosts(data);
                if (route.Contains("includeReplies=1", StringComparison.Ordinal) && parsed.Count > 0)
                    repliesAvailable = true;
                foreach (var post in parsed) posts[post.Url] = post;
            }
        }
        if (posts.Count == 0) throw new InvalidOperationException("RSSHub 暂未返回公开消息。");
        return new TiboFetchResult(
            posts.Values.OrderByDescending(post => post.PostedAt ?? post.CapturedAt).ToArray(),
            repliesAvailable);
    }

    private async Task EnsureRuntimeAsync(IProgress<string>? progress, CancellationToken cancellationToken)
    {
        var packagePath = Path.Combine(_runtimeRoot, "node_modules", "rsshub", "package.json");
        var slimMarker = Path.Combine(_runtimeRoot, ".codex-tibo-slim-version");
        var installedVersionMatches = false;
        if (File.Exists(packagePath))
        {
            try
            {
                using var package = JsonDocument.Parse(await File.ReadAllTextAsync(packagePath, cancellationToken));
                installedVersionMatches = package.RootElement.GetProperty("version").GetString() == RssHubVersion;
            }
            catch { }
        }

        if (installedVersionMatches && (File.Exists(slimMarker) || !HasBundledRuntime())) return;

        if (TryInstallBundledRuntime(progress) && File.Exists(packagePath)) return;
        if (installedVersionMatches) return;

        var npm = FindExecutable("npm.cmd") ?? throw new InvalidOperationException("没有找到本机 npm，无法安装 RSSHub 组件。");
        Directory.CreateDirectory(_runtimeRoot);
        progress?.Report("首次使用，正在安装本机 RSSHub 组件…");
        var info = new ProcessStartInfo
        {
            FileName = npm,
            WorkingDirectory = _runtimeRoot,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            CreateNoWindow = true
        };
        info.ArgumentList.Add("install");
        info.ArgumentList.Add("--omit=dev");
        info.ArgumentList.Add("--no-audit");
        info.ArgumentList.Add("--no-fund");
        info.ArgumentList.Add($"rsshub@{RssHubVersion}");
        using var process = Process.Start(info) ?? throw new InvalidOperationException("无法启动 RSSHub 安装程序。");
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        if (process.ExitCode != 0 || !File.Exists(packagePath))
            throw new InvalidOperationException("本机 RSSHub 组件安装失败。" + ShortError(stderr + " " + stdout));
    }

    private bool TryInstallBundledRuntime(IProgress<string>? progress)
    {
        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames().FirstOrDefault(name =>
            name.EndsWith("rsshub-runtime-win-x64.zip", StringComparison.OrdinalIgnoreCase));
        if (resourceName is null) return false;
        progress?.Report("首次使用，正在准备应用内置 RSSHub…");
        var staging = _runtimeRoot + ".new-" + Guid.NewGuid().ToString("N");
        var backup = _runtimeRoot + ".backup-" + Guid.NewGuid().ToString("N");
        try
        {
            Directory.CreateDirectory(staging);
            using var stream = assembly.GetManifestResourceStream(resourceName)
                ?? throw new InvalidOperationException("无法读取内置 RSSHub 组件。");
            using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
            archive.ExtractToDirectory(staging, overwriteFiles: true);
            var stagedPackage = Path.Combine(staging, "node_modules", "rsshub", "package.json");
            var stagedMarker = Path.Combine(staging, ".codex-tibo-slim-version");
            if (!File.Exists(stagedPackage) || !File.Exists(stagedMarker))
                throw new InvalidOperationException("内置 RSSHub 精简组件不完整。");
            if (Directory.Exists(_runtimeRoot)) Directory.Move(_runtimeRoot, backup);
            Directory.Move(staging, _runtimeRoot);
            if (Directory.Exists(backup)) Directory.Delete(backup, recursive: true);
            return true;
        }
        catch (Exception error)
        {
            try
            {
                if (!Directory.Exists(_runtimeRoot) && Directory.Exists(backup)) Directory.Move(backup, _runtimeRoot);
                if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            }
            catch { }
            throw new InvalidOperationException("无法解压应用内置 RSSHub 组件：" + error.Message, error);
        }
    }

    private static bool HasBundledRuntime() => Assembly.GetExecutingAssembly().GetManifestResourceNames()
        .Any(name => name.EndsWith("rsshub-runtime-win-x64.zip", StringComparison.OrdinalIgnoreCase));

    private string EnsureRunnerFile()
    {
        Directory.CreateDirectory(_runtimeRoot);
        var runnerPath = Path.Combine(_runtimeRoot, "rsshub-runner.mjs");
        var resourceName = Assembly.GetExecutingAssembly().GetManifestResourceNames()
            .FirstOrDefault(name => name.EndsWith("rsshub-runner.mjs", StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException("应用缺少 RSSHub 启动组件。");
        using var input = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("无法读取 RSSHub 启动组件。");
        using var output = File.Create(runnerPath);
        input.CopyTo(output);
        return runnerPath;
    }

    private static List<TiboPost> ParsePosts(JsonElement data)
    {
        var items = FindItems(data);
        var result = new List<TiboPost>();
        foreach (var item in items)
        {
            var url = StringProperty(item, "link") ?? StringProperty(item, "url");
            if (url is null || !url.Contains("/status/", StringComparison.OrdinalIgnoreCase)) continue;
            var html = NestedStringProperty(item, "content", "html")
                ?? StringProperty(item, "description") ?? StringProperty(item, "content_html");
            var text = NestedStringProperty(item, "content", "text")
                ?? (html is null ? null : HtmlToText(html)) ?? StringProperty(item, "title");
            text = NormalizeText(text ?? "");
            if (text.Length == 0) continue;
            var dateText = StringProperty(item, "pubDate") ?? StringProperty(item, "date_published") ?? StringProperty(item, "published");
            DateTimeOffset? date = DateTimeOffset.TryParse(dateText, out var parsedDate) ? parsedDate : null;
            result.Add(new TiboPost(text, url, date, DateTimeOffset.Now));
        }
        return result;
    }

    private static IEnumerable<JsonElement> FindItems(JsonElement data)
    {
        if (TryArray(data, "item", out var items) || TryArray(data, "items", out items)) return items.EnumerateArray();
        if (data.TryGetProperty("data", out var nested) &&
            (TryArray(nested, "item", out items) || TryArray(nested, "items", out items))) return items.EnumerateArray();
        return [];
    }

    private static bool TryArray(JsonElement element, string name, out JsonElement value) =>
        element.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Array;
    private static string? StringProperty(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static string? NestedStringProperty(JsonElement element, string parent, string name) =>
        element.TryGetProperty(parent, out var nested) && nested.ValueKind == JsonValueKind.Object ? StringProperty(nested, name) : null;
    private static string HtmlToText(string html) => System.Net.WebUtility.HtmlDecode(TagRegex().Replace(html, " "));
    private static string NormalizeText(string value) => WhitespaceRegex().Replace(value, " ").Trim();
    private static string ShortError(string value)
    {
        var text = NormalizeText(value);
        return text.Length == 0 ? "" : " " + (text.Length > 240 ? text[..240] + "…" : text);
    }

    private static string? FindExecutable(string name)
    {
        var bundled = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Codex Token Bar", "rsshub-runtime", name);
        if (File.Exists(bundled)) return bundled;
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var folder in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(folder.Trim('"'), name);
            if (File.Exists(candidate)) return candidate;
        }
        var nodeFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs");
        var fallback = Path.Combine(nodeFolder, name);
        return File.Exists(fallback) ? fallback : null;
    }

    public void Dispose()
    {
        try { if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true); }
        catch { }
        _process?.Dispose();
    }

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex TagRegex();
    [GeneratedRegex("\\s+")]
    private static partial Regex WhitespaceRegex();
}
