using System.Diagnostics;
using System.Text.Json;

namespace CodexTokenBar.Windows;

internal sealed class CodexAppServerClient : IDisposable
{
    private readonly CancellationTokenSource _stopping = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private readonly object _stateLock = new();
    private Process? _process;
    private int _nextId;
    private int? _initializeRequestId;
    private int? _rateLimitRequestId;
    private int? _tokenUsageRequestId;
    private bool _initialized;
    private DateTimeOffset? _lastTokenUsageUpdate;

    public event Action<UsageSnapshot>? SnapshotReceived;
    public event Action<TokenUsageSnapshot>? TokenUsageReceived;
    public event Action<string>? ErrorReceived;

    public void Start() => _ = Task.Run(RunLoopAsync);

    public void Refresh(bool includeTokenUsage = false)
    {
        lock (_stateLock)
        {
            if (!_initialized || _process is not { HasExited: false }) return;
            if (_rateLimitRequestId is null)
            {
                _rateLimitRequestId = NextId();
                var requestId = _rateLimitRequestId.Value;
                _ = SendAndReportAsync(
                    new { method = "account/rateLimits/read", id = requestId },
                    _stopping.Token);
                _ = ExpireRateLimitRequestAsync(requestId, _stopping.Token);
            }

            var tokenUsageStale = _lastTokenUsageUpdate is null ||
                                  DateTimeOffset.Now - _lastTokenUsageUpdate >= TimeSpan.FromHours(1);
            if ((includeTokenUsage || tokenUsageStale) && _tokenUsageRequestId is null)
            {
                _tokenUsageRequestId = NextId();
                _ = SendAndReportAsync(
                    new { method = "account/usage/read", id = _tokenUsageRequestId.Value },
                    _stopping.Token);
            }
        }
    }

    private async Task RunLoopAsync()
    {
        while (!_stopping.IsCancellationRequested)
        {
            try
            {
                await RunSessionAsync(_stopping.Token).ConfigureAwait(false);
                if (!_stopping.IsCancellationRequested)
                    ErrorReceived?.Invoke("Codex 连接已断开，正在重新连接…");
            }
            catch (OperationCanceledException) when (_stopping.IsCancellationRequested) { }
            catch (Exception error)
            {
                ErrorReceived?.Invoke(error.Message);
            }

            ResetSession();
            if (_stopping.IsCancellationRequested) break;
            try { await Task.Delay(TimeSpan.FromSeconds(5), _stopping.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task RunSessionAsync(CancellationToken cancellationToken)
    {
        var command = FindCodexCommand() ?? throw new FileNotFoundException(
            "未找到 Codex。请安装 Codex CLI，或设置 CODEX_TOKEN_BAR_CODEX_PATH。");

        var startInfo = command.CreateStartInfo();
        var process = new Process { StartInfo = startInfo };
        if (!process.Start()) throw new InvalidOperationException("无法启动 Codex。");
        _ = process.StandardError.ReadToEndAsync(cancellationToken);

        lock (_stateLock) _process = process;
        _initializeRequestId = NextId();
        await SendAsync(new
        {
            method = "initialize",
            id = _initializeRequestId,
            @params = new
            {
                clientInfo = new { name = "codex_token_bar_windows", title = "Codex Token Bar", version = "1.3.2" }
            }
        }, cancellationToken).ConfigureAwait(false);

        while (!cancellationToken.IsCancellationRequested)
        {
            var line = await process.StandardOutput.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null) break;
            if (string.IsNullOrWhiteSpace(line)) continue;
            HandleLine(line, cancellationToken);
        }
    }

    private void HandleLine(string line, CancellationToken cancellationToken)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            var id = root.TryGetProperty("id", out var idElement) && idElement.TryGetInt32(out var parsedId)
                ? parsedId
                : (int?)null;

            if (id == _initializeRequestId)
            {
                if (root.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null)
                    throw new InvalidDataException("Codex 初始化失败。" + ErrorMessage(error));

                lock (_stateLock)
                {
                    _initializeRequestId = null;
                    _initialized = true;
                }
                _ = SendAndReportAsync(new { method = "initialized", @params = new { } }, cancellationToken);
                Refresh();
                return;
            }

            if (id == _rateLimitRequestId)
            {
                lock (_stateLock) _rateLimitRequestId = null;
                SnapshotReceived?.Invoke(RateLimitParser.Parse(root));
                return;
            }

            if (id == _tokenUsageRequestId)
            {
                lock (_stateLock)
                {
                    _tokenUsageRequestId = null;
                    _lastTokenUsageUpdate = DateTimeOffset.Now;
                }
                TokenUsageReceived?.Invoke(TokenUsageParser.Parse(root));
                return;
            }

            if (root.TryGetProperty("method", out var method) &&
                method.GetString() == "account/rateLimits/updated")
                Refresh();
        }
        catch (JsonException) { }
        catch (Exception error) { ErrorReceived?.Invoke(error.Message); }
    }

    private async Task SendAsync(object message, CancellationToken cancellationToken)
    {
        await _writeLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            Process? process;
            lock (_stateLock) process = _process;
            if (process is null || process.HasExited) return;
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(message)).ConfigureAwait(false);
            await process.StandardInput.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally { _writeLock.Release(); }
    }

    private async Task SendAndReportAsync(object message, CancellationToken cancellationToken)
    {
        try { await SendAsync(message, cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        catch (Exception error) { ErrorReceived?.Invoke($"无法与 Codex 通信：{error.Message}"); }
    }

    private async Task ExpireRateLimitRequestAsync(int requestId, CancellationToken cancellationToken)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(15), cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }

        lock (_stateLock)
        {
            if (_rateLimitRequestId != requestId) return;
            _rateLimitRequestId = null;
        }
        ErrorReceived?.Invoke("读取 Codex 额度超时，稍后会自动重试。");
    }

    private int NextId() => Interlocked.Increment(ref _nextId);

    private void ResetSession()
    {
        Process? process;
        lock (_stateLock)
        {
            process = _process;
            _process = null;
            _initializeRequestId = null;
            _rateLimitRequestId = null;
            _tokenUsageRequestId = null;
            _initialized = false;
        }
        process?.Dispose();
    }

    private static string ErrorMessage(JsonElement error) =>
        error.ValueKind == JsonValueKind.Object && error.TryGetProperty("message", out var message)
            ? message.GetString() ?? "未知错误"
            : "未知错误";

    private static CodexCommand? FindCodexCommand()
    {
        var candidates = new List<string?>
        {
            Environment.GetEnvironmentVariable("CODEX_TOKEN_BAR_CODEX_PATH"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm", "codex.cmd"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "OpenAI", "Codex", "bin", "codex.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Codex", "resources", "codex.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "ChatGPT", "resources", "codex.exe")
        };

        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            candidates.Add(Path.Combine(directory, "codex.exe"));
            candidates.Add(Path.Combine(directory, "codex.cmd"));
        }

        return candidates.Where(candidate => !string.IsNullOrWhiteSpace(candidate))
            .Select(candidate => Path.GetFullPath(Environment.ExpandEnvironmentVariables(candidate!)))
            .Where(File.Exists)
            .Select(candidate => new CodexCommand(candidate))
            .FirstOrDefault();
    }

    public void Dispose()
    {
        _stopping.Cancel();
        lock (_stateLock)
        {
            if (_process is { HasExited: false } process)
            {
                try { process.Kill(entireProcessTree: true); } catch { }
            }
        }
        ResetSession();
    }

    private sealed record CodexCommand(string Path)
    {
        public ProcessStartInfo CreateStartInfo()
        {
            var isScript = System.IO.Path.GetExtension(Path).Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
                           System.IO.Path.GetExtension(Path).Equals(".bat", StringComparison.OrdinalIgnoreCase);
            var startInfo = new ProcessStartInfo
            {
                FileName = isScript ? Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe" : Path,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            if (isScript)
            {
                startInfo.ArgumentList.Add("/d");
                startInfo.ArgumentList.Add("/s");
                startInfo.ArgumentList.Add("/c");
                startInfo.ArgumentList.Add($"\"{Path}\" app-server");
            }
            else startInfo.ArgumentList.Add("app-server");
            return startInfo;
        }
    }
}
