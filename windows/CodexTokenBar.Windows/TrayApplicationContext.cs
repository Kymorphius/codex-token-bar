using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.Runtime.InteropServices;

namespace CodexTokenBar.Windows;

internal sealed class TrayApplicationContext : ApplicationContext
{
    private const string Version = "1.3.2";
    private readonly SynchronizationContext _uiContext;
    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _menu = new()
    {
        ShowImageMargin = false,
        DropShadowEnabled = false,
        AutoClose = true
    };
    private readonly Form _menuOwner = new()
    {
        ShowInTaskbar = false,
        FormBorderStyle = FormBorderStyle.None,
        StartPosition = FormStartPosition.Manual,
        Location = new Point(-32_000, -32_000),
        Size = new Size(1, 1),
        Opacity = 0,
        TopMost = true
    };
    private readonly CodexAppServerClient _client = new();
    private readonly UsageHistoryStore _usageHistory = new();
    private readonly GitHubUpdateChecker _updateChecker = new();
    private readonly TiboRSSHubClient _tiboClient = new();
    private readonly TiboPostStore _tiboPostStore = new();
    private readonly System.Windows.Forms.Timer _refreshTimer = new() { Interval = 60_000 };
    private readonly System.Windows.Forms.Timer _updateTimer = new() { Interval = 24 * 60 * 60 * 1_000 };
    private readonly System.Windows.Forms.Timer _tiboTimer = new() { Interval = 30 * 60 * 1_000 };
    private UsageSnapshot? _snapshot;
    private TokenUsageSnapshot? _tokenUsageSnapshot;
    private string? _lastError;
    private Icon? _generatedIcon;
    private bool _isCheckingForUpdates;
    private XLoginForm? _xLoginForm;
    private TiboFeedForm? _tiboFeedForm;
    private string? _xAuthToken;
    private string _tiboStatus = "本机 RSSHub 等待首次更新";
    private bool _isRefreshingTibo;
    private bool _tiboRepliesAvailable;

    public TrayApplicationContext(SynchronizationContext uiContext)
    {
        _uiContext = uiContext;
        _xAuthToken = XAuthTokenStore.Load();
        StartupManager.EnsureDefaultEnabled();
        _notifyIcon = new NotifyIcon
        {
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Text = "Codex Token Bar · 正在读取额度…",
            Visible = true
        };
        _notifyIcon.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button == MouseButtons.Left) ShowMenu();
            if (eventArgs.Button == MouseButtons.Right) ShowXLogin();
        };
        _menu.Closed += (_, _) => _menuOwner.Hide();
        _menuOwner.Deactivate += (_, _) =>
        {
            if (_menu.Visible) _menu.Close(ToolStripDropDownCloseReason.AppClicked);
        };

        _client.SnapshotReceived += snapshot => _uiContext.Post(_ =>
        {
            _snapshot = snapshot;
            _lastError = null;
            _usageHistory.Record(snapshot);
            DiagnosticStatus.WriteSnapshot(snapshot);
            UpdateTrayIcon();
        }, null);
        _client.TokenUsageReceived += snapshot => _uiContext.Post(_ => _tokenUsageSnapshot = snapshot, null);
        _client.ErrorReceived += message => _uiContext.Post(_ =>
        {
            _lastError = message;
            DiagnosticStatus.WriteError(message);
            UpdateTrayIcon();
        }, null);

        _refreshTimer.Tick += (_, _) => _client.Refresh();
        _updateTimer.Tick += async (_, _) => await CheckForUpdatesAsync(userInitiated: false);
        _tiboTimer.Tick += async (_, _) => await RefreshTiboAsync();
        _refreshTimer.Start();
        _tiboTimer.Start();
        ConfigureAutomaticUpdates(checkSoon: true);
        DiagnosticStatus.WriteStarting();
        _client.Start();
        if (_xAuthToken is not null)
            _ = Task.Delay(TimeSpan.FromSeconds(3)).ContinueWith(_ =>
                _uiContext.Post(async _ => await RefreshTiboAsync(), null));
    }

    private void ShowMenu()
    {
        if (_menu.Visible)
        {
            _menu.Close();
            return;
        }

        RebuildMenu();
        var cursor = Cursor.Position;
        var workingArea = Screen.FromPoint(cursor).WorkingArea;
        var preferredSize = _menu.GetPreferredSize(Size.Empty);
        var maximumX = Math.Max(workingArea.Left, workingArea.Right - preferredSize.Width);
        var maximumY = Math.Max(workingArea.Top, workingArea.Bottom - preferredSize.Height);
        var menuX = Math.Clamp(cursor.X, workingArea.Left, maximumX);
        var menuY = cursor.Y + preferredSize.Height <= workingArea.Bottom
            ? cursor.Y
            : cursor.Y - preferredSize.Height;
        menuY = Math.Clamp(menuY, workingArea.Top, maximumY);

        _menuOwner.Location = new Point(
            Math.Clamp(cursor.X, workingArea.Left, workingArea.Right - 1),
            Math.Clamp(cursor.Y, workingArea.Top, workingArea.Bottom - 1));
        if (!_menuOwner.Visible) _menuOwner.Show();
        _menuOwner.Activate();
        SetForegroundWindow(_menuOwner.Handle);
        _menu.Show(new Point(menuX, menuY));
    }

    private void UpdateTrayIcon()
    {
        var remaining = _snapshot?.HeadlineBucket?.HeadlineWindow?.RemainingPercent;
        var label = remaining is { } value ? $"{Math.Round(value):0}" : "--";
        var nextIcon = CreatePercentageIcon(label);
        _notifyIcon.Icon = nextIcon;
        _generatedIcon?.Dispose();
        _generatedIcon = nextIcon;
        var tooltip = remaining is { } percent
            ? $"Codex 剩余额度 {Math.Round(percent):0}% · 左键查看详情"
            : _lastError ?? "正在读取 Codex 剩余额度…";
        _notifyIcon.Text = tooltip.Length <= 63 ? tooltip : tooltip[..60] + "…";
    }

    private void RebuildMenu()
    {
        _menu.Items.Clear();
        AddLabel(_menu.Items, "Codex 剩余额度", bold: true);
        if (_snapshot is { } snapshot)
        {
            var primaryBuckets = snapshot.Buckets.Where(bucket => !IsSpark(bucket)).ToArray();
            for (var index = 0; index < primaryBuckets.Length; index++)
            {
                if (index > 0) _menu.Items.Add(new ToolStripSeparator());
                AddBucket(_menu.Items, primaryBuckets[index]);
            }
            AddResetCredits(snapshot);
            AddUsageHistory();
            _menu.Items.Add(new ToolStripSeparator());
            AddLabel(_menu.Items, $"更新于 {snapshot.UpdatedAt:HH:mm:ss}");
        }
        else AddLabel(_menu.Items, _lastError ?? "正在连接 Codex…");

        if (_snapshot is not null && _lastError is not null) AddLabel(_menu.Items, $"提示：{_lastError}");
        AddTimeTools();
        AddTiboTools();
        _menu.Items.Add(new ToolStripSeparator());
        AddAction(_menu.Items, "立即刷新", (_, _) =>
        {
            _lastError = null;
            _client.Refresh(includeTokenUsage: true);
        });
        AddAction(_menu.Items, "打开 Codex", (_, _) => OpenUrl("codex://"));

        var startup = AddAction(_menu.Items, "登录时自动启动", (_, _) => ToggleStartup());
        startup.Checked = StartupManager.IsEnabled;
        var update = AddAction(
            _menu.Items,
            _isCheckingForUpdates ? "正在检查 GitHub 更新…" : "检查 GitHub 更新…",
            async (_, _) => await CheckForUpdatesAsync(userInitiated: true));
        update.Enabled = !_isCheckingForUpdates;
        var automaticUpdates = AddAction(_menu.Items, "自动检查 GitHub 更新", (_, _) =>
        {
            AppSettings.AutomaticUpdateChecks = !AppSettings.AutomaticUpdateChecks;
            ConfigureAutomaticUpdates(checkSoon: AppSettings.AutomaticUpdateChecks);
        });
        automaticUpdates.Checked = AppSettings.AutomaticUpdateChecks;
        _menu.Items.Add(new ToolStripSeparator());
        AddAction(_menu.Items, "关于 Codex Token Bar", (_, _) => ShowAbout());
        AddAction(_menu.Items, "退出", (_, _) => ExitThread());

        if (_snapshot?.Buckets.FirstOrDefault(IsSpark) is { } spark)
        {
            _menu.Items.Add(new ToolStripSeparator());
            AddCollapsedSparkBucket(spark);
        }
    }

    private void AddBucket(ToolStripItemCollection items, UsageBucket bucket)
    {
        var name = bucket.Name ?? (bucket.Id == "codex" ? "Codex" : bucket.Id);
        if (bucket.Primary is { } primary)
        {
            AddLabel(items, $"{name}：{FormatPercent(primary.RemainingPercent)} 剩余", bold: true);
            AddLabel(items, Indent(WindowDescription(primary)), bright: bucket.Id == "codex");
            if (DailyAllowanceDescription(primary) is { } allowance)
                AddLabel(items, Indent(allowance), bright: bucket.Id == "codex");
        }
        else AddLabel(items, name, bold: true);
        if (bucket.Secondary is { } secondary)
        {
            AddLabel(items, $"次级窗口：{FormatPercent(secondary.RemainingPercent)} 剩余");
            AddLabel(items, Indent(WindowDescription(secondary)), bright: bucket.Id == "codex");
            if (DailyAllowanceDescription(secondary) is { } allowance)
                AddLabel(items, Indent(allowance), bright: bucket.Id == "codex");
        }
        if (!string.IsNullOrWhiteSpace(bucket.PlanType) && bucket.Id == "codex")
            AddLabel(items, Indent($"套餐：{CultureInfo.InvariantCulture.TextInfo.ToTitleCase(bucket.PlanType)}"));
        if (!string.IsNullOrWhiteSpace(bucket.RateLimitReachedType))
            AddLabel(items, Indent($"额度已受限：{bucket.RateLimitReachedType}"));
    }

    private void AddResetCredits(UsageSnapshot snapshot)
    {
        var availableDetails = snapshot.ResetCredits
            .Where(credit => credit.Status is null || credit.Status.Equals("available", StringComparison.OrdinalIgnoreCase))
            .ToArray();
        var count = snapshot.AvailableResetCredits ?? availableDetails.Length;
        if (count <= 0) return;
        _menu.Items.Add(new ToolStripSeparator());
        AddLabel(_menu.Items, $"可用额度重置：{count} 次", bright: true);
        for (var index = 0; index < count; index++)
        {
            var credit = index < availableDetails.Length ? availableDetails[index] : null;
            var detail = credit?.ExpiresAt is { } expiry
                ? $"第 {index + 1} 次：有效期至 {expiry.LocalDateTime:M月d日 HH:mm}（{FormatCountdown(expiry)}）"
                : $"第 {index + 1} 次：有效期暂未提供";
            AddLabel(_menu.Items, Indent(detail), bright: true);
        }
    }

    private void AddUsageHistory()
    {
        _menu.Items.Add(new ToolStripSeparator());
        AddLabel(_menu.Items, "近 7 天用量", bold: true);
        var today = DateOnly.FromDateTime(DateTime.Now);
        foreach (var entry in _usageHistory.Entries.Reverse())
        {
            var label = entry.Date == today
                ? $"今天（{entry.Date:M月d日 ddd}）"
                : entry.Date == today.AddDays(-1) ? $"昨天（{entry.Date:M月d日 ddd}）" : $"{entry.Date:M月d日 ddd}";
            var percentage = entry.UsedPercent is { } used ? FormatPercent(used) : "— 数据不足";
            var tokenDate = entry.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            AddLabel(_menu.Items, Indent($"{label}：{percentage} · {TokenCountDescription(tokenDate)}"));
        }
        AddAction(_menu.Items, Indent("查看全年使用热力图…"), (_, _) => new UsageHeatmapForm(_usageHistory.HeatmapEntries).Show());
        AddLabel(_menu.Items, Indent("历史永久保存在本机；百分比为快照增量"));
    }

    private void AddTimeTools()
    {
        _menu.Items.Add(new ToolStripSeparator());
        var pacificZone = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
        var pacificNow = TimeZoneInfo.ConvertTime(DateTimeOffset.Now, pacificZone);
        var abbreviation = pacificZone.IsDaylightSavingTime(pacificNow) ? "PDT" : "PST";
        var item = new ToolStripMenuItem($"时间 · {abbreviation} {pacificNow:HH:mm}");
        AddLabel(item.DropDownItems, $"太平洋时间（{abbreviation}）：{pacificNow:M月d日 ddd HH:mm}", bright: true);
        AddAction(item.DropDownItems, "太平洋时间 ↔ 本地时间换算…", (_, _) => new TimeConverterForm().ShowDialog());
        var mode = AppSettings.DisplayTimeZoneId is null ? "跟随系统" : DisplayTimeZone.Name(DisplayTimeZone.Current);
        AddAction(item.DropDownItems, $"显示时区：{mode}…", (_, _) =>
        {
            using var form = new TimeZoneSettingsForm();
            form.ShowDialog();
        });
        _menu.Items.Add(item);
    }

    private void AddTiboTools()
    {
        _menu.Items.Add(new ToolStripSeparator());
        AddLabel(_menu.Items, "Tibo 动态", bold: true);
        foreach (var post in _tiboPostStore.Posts.Take(4))
        {
            var item = AddAction(_menu.Items, Indent(TiboPostMenuTitle(post)), (_, _) => OpenUrl(post.Url));
            item.ToolTipText = post.Text;
        }
        if (_tiboPostStore.Posts.Count == 0)
            AddLabel(_menu.Items, Indent(_xAuthToken is null ? "登录 X 后，将通过本机 RSSHub 显示最近发言" : "点击刷新读取最近发言"));
        AddLabel(_menu.Items, Indent(_tiboStatus));
        AddAction(_menu.Items, Indent(_xAuthToken is null ? "在应用内登录 X…" : "打开 Tibo 的 X 时间线…"), (_, _) => ShowXLogin());
        var refresh = AddAction(_menu.Items, Indent(_isRefreshingTibo ? "正在刷新 RSS…" : "刷新 Tibo RSS…"), async (_, _) => await RefreshTiboAsync(userInitiated: true));
        refresh.Enabled = !_isRefreshingTibo && _xAuthToken is not null;
        AddAction(_menu.Items, Indent("查看 Codex 负责人最新公开发言…"), (_, _) => ShowTiboFeed());
        AddAction(_menu.Items, Indent("查看他在不同帖子下的回复…"), (_, _) =>
            OpenUrl("https://x.com/search?q=from%3Athsottiaux%20is%3Areply&src=typed_query&f=live"));
        AddLabel(_menu.Items, Indent("本机 RSSHub · Cookie 不上传 · 尝试包含回复"));
    }

    private void ShowXLogin()
    {
        if (_xLoginForm is null || _xLoginForm.IsDisposed)
        {
            _xLoginForm = new XLoginForm();
            _xLoginForm.AuthTokenAvailable += token =>
            {
                _xAuthToken = token;
                XAuthTokenStore.Save(token);
                if (_menu.Visible) RebuildMenu();
                _ = RefreshTiboAsync();
            };
        }
        if (!_xLoginForm.Visible) _xLoginForm.Show();
        _xLoginForm.WindowState = FormWindowState.Normal;
        _xLoginForm.Activate();
        _xLoginForm.BringToFront();
    }

    private async Task RefreshTiboAsync(bool userInitiated = false)
    {
        if (_isRefreshingTibo) return;
        if (string.IsNullOrWhiteSpace(_xAuthToken))
        {
            if (userInitiated) ShowXLogin();
            return;
        }
        _isRefreshingTibo = true;
        SetTiboStatus("本机 RSSHub 正在准备…");
        try
        {
            var progress = new Progress<string>(SetTiboStatus);
            var feed = await _tiboClient.FetchAsync(_xAuthToken, progress);
            _tiboRepliesAvailable = feed.RepliesAvailable;
            _tiboPostStore.Merge(feed.Posts);
            SetTiboStatus($"RSSHub 已更新 {feed.Posts.Count} 条 · " +
                (feed.RepliesAvailable ? "包含回复" : "回复源暂不可用"));
        }
        catch (Exception error)
        {
            SetTiboStatus(error.Message);
            if (userInitiated)
                MessageBox.Show(error.Message, "Tibo RSS 更新失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            _isRefreshingTibo = false;
            UpdateTiboFeedForm();
            if (_menu.Visible) RebuildMenu();
        }
    }

    private void SetTiboStatus(string status)
    {
        _tiboStatus = status;
        UpdateTiboFeedForm();
        if (_menu.Visible) RebuildMenu();
    }

    private void ShowTiboFeed()
    {
        if (_tiboFeedForm is null || _tiboFeedForm.IsDisposed)
        {
            _tiboFeedForm = new TiboFeedForm();
            _tiboFeedForm.RefreshRequested += async () => await RefreshTiboAsync(userInitiated: true);
        }
        UpdateTiboFeedForm();
        if (!_tiboFeedForm.Visible) _tiboFeedForm.Show();
        _tiboFeedForm.WindowState = FormWindowState.Normal;
        _tiboFeedForm.Activate();
        _tiboFeedForm.BringToFront();
        if (_xAuthToken is not null && _tiboPostStore.Posts.Count == 0) _ = RefreshTiboAsync();
    }

    private void UpdateTiboFeedForm()
    {
        if (_tiboFeedForm is null || _tiboFeedForm.IsDisposed) return;
        _tiboFeedForm.UpdateFeed(_tiboPostStore.Posts, _tiboStatus, _isRefreshingTibo);
    }

    private static string TiboPostMenuTitle(TiboPost post)
    {
        var elapsed = DateTimeOffset.Now - (post.PostedAt ?? post.CapturedAt);
        var age = elapsed.TotalMinutes < 60 ? $"{Math.Max(1, (int)elapsed.TotalMinutes)} 分钟前" :
            elapsed.TotalHours < 24 ? $"{(int)elapsed.TotalHours} 小时前" : $"{Math.Max(1, (int)elapsed.TotalDays)} 天前";
        var collapsed = string.Join(" ", post.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var summary = collapsed.Length > 48 ? collapsed[..48] + "…" : collapsed;
        return $"{age} · {summary}";
    }

    private void AddCollapsedSparkBucket(UsageBucket bucket)
    {
        var name = bucket.Name ?? "GPT-5.3-Codex-Spark";
        var remaining = bucket.HeadlineWindow is { } window ? $" · {FormatPercent(window.RemainingPercent)} 剩余" : string.Empty;
        var item = new ToolStripMenuItem(name + remaining);
        AddBucket(item.DropDownItems, bucket);
        _menu.Items.Add(item);
    }

    private string TokenCountDescription(string startDate)
    {
        if (_tokenUsageSnapshot is null) return "tokens 正在读取…";
        if (_tokenUsageSnapshot.TokensOn(startDate) is { } tokens) return $"{tokens:N0} tokens";
        if (_tokenUsageSnapshot.LatestStartDate is null) return "tokens 暂无数据";
        return string.CompareOrdinal(startDate, _tokenUsageSnapshot.LatestStartDate) > 0 ? "tokens 待官方更新" : "0 tokens";
    }

    private async Task CheckForUpdatesAsync(bool userInitiated)
    {
        if (_isCheckingForUpdates) return;
        _isCheckingForUpdates = true;
        try
        {
            var result = await _updateChecker.CheckAsync(Version);
            if (result.Release is { } release)
            {
                var choice = MessageBox.Show(
                    $"发现新版本 {release.Version}\n\n当前版本为 {Version}。是否打开 GitHub Release？",
                    "Codex Token Bar 更新", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (choice == DialogResult.Yes) OpenUrl(release.DownloadUrl ?? release.PageUrl);
            }
            else if (userInitiated)
            {
                var message = result.LatestVersion is null ? "仓库还没有发布可下载的版本。" :
                    $"当前版本为 {Version}，GitHub 最新版本为 {result.LatestVersion}。";
                MessageBox.Show(message, "已经是最新版本", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
        }
        catch (Exception error)
        {
            if (userInitiated) MessageBox.Show(error.Message, "检查更新失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally { _isCheckingForUpdates = false; }
    }

    private void ConfigureAutomaticUpdates(bool checkSoon)
    {
        _updateTimer.Stop();
        if (!AppSettings.AutomaticUpdateChecks) return;
        _updateTimer.Start();
        if (checkSoon)
            _ = Task.Delay(TimeSpan.FromSeconds(10)).ContinueWith(_ =>
                _uiContext.Post(async _ => await CheckForUpdatesAsync(userInitiated: false), null));
    }

    private static string WindowDescription(UsageWindow window)
    {
        var parts = new List<string>();
        if (window.WindowDurationMinutes is { } minutes) parts.Add($"{FormatDuration(minutes)}窗口");
        if (window.ResetsAt is { } reset)
        {
            parts.Add($"距重置{FormatCountdown(reset)}");
            parts.Add($"{reset.LocalDateTime:M月d日 HH:mm} 重置");
        }
        return parts.Count == 0 ? "额度窗口" : string.Join(" · ", parts);
    }

    private static string? DailyAllowanceDescription(UsageWindow window)
    {
        if (window.WindowDurationMinutes is not { } minutes || minutes < 1_440 || window.ResetsAt is not { } reset) return null;
        var remaining = reset - DateTimeOffset.Now;
        if (remaining <= TimeSpan.Zero) return null;
        if (remaining < TimeSpan.FromDays(1)) return $"距重置不足 1 天：尚可使用 {FormatPercent(window.RemainingPercent)}";
        return $"按剩余时间均分：每天约可用 {FormatPercent(window.RemainingPercent / remaining.TotalDays)}";
    }

    private static ToolStripMenuItem AddAction(ToolStripItemCollection items, string text, EventHandler handler)
    {
        var item = new ToolStripMenuItem(text);
        item.Click += handler;
        items.Add(item);
        return item;
    }

    private static void AddLabel(ToolStripItemCollection items, string text, bool bold = false, bool bright = false)
    {
        var item = new ToolStripMenuItem(text) { Enabled = false };
        if (bold) item.Font = new Font(item.Font, FontStyle.Bold);
        if (bright) item.ForeColor = SystemColors.MenuText;
        items.Add(item);
    }

    private static string Indent(string text) => "    " + text;
    private static string FormatPercent(double value) => Math.Abs(Math.Round(value) - value) < 0.05 ? $"{Math.Round(value):0}%" : $"{value:0.0}%";
    private static bool IsSpark(UsageBucket bucket) => $"{bucket.Id} {bucket.Name}".Contains("spark", StringComparison.OrdinalIgnoreCase);

    private static string FormatDuration(int minutes)
    {
        if (minutes % 10_080 == 0) return $"{minutes / 10_080} 周";
        if (minutes % 1_440 == 0) return $"{minutes / 1_440} 天";
        if (minutes % 60 == 0) return $"{minutes / 60} 小时";
        return $"{minutes} 分钟";
    }

    private static string FormatCountdown(DateTimeOffset reset)
    {
        var remaining = reset - DateTimeOffset.Now;
        if (remaining <= TimeSpan.Zero) return "正在重置";
        var totalHours = Math.Max(1, (int)Math.Ceiling(remaining.TotalHours));
        var days = totalHours / 24;
        var hours = totalHours % 24;
        if (days > 0 && hours > 0) return $"还有 {days} 天 {hours} 小时";
        if (days > 0) return $"还有 {days} 天";
        return $"还有 {hours} 小时";
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) { MessageBox.Show(error.Message, "无法打开", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private static void ToggleStartup()
    {
        try { StartupManager.SetEnabled(!StartupManager.IsEnabled); }
        catch (Exception error) { MessageBox.Show(error.Message, "无法更改登录项", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private static void ShowAbout() => MessageBox.Show(
        $"Codex Token Bar {Version}\n\n在系统托盘显示 Codex 账号的实际剩余额度。\n数据通过本机 Codex App Server 读取，不需要 API Key。",
        "关于 Codex Token Bar", MessageBoxButtons.OK, MessageBoxIcon.Information);

    private static Icon CreatePercentageIcon(string label)
    {
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using var background = new SolidBrush(Color.FromArgb(31, 35, 40));
        graphics.FillRectangle(background, 0, 0, 32, 32);
        var size = label.Length >= 3 ? 17f : 22f;
        using var font = new Font("Segoe UI", size, FontStyle.Bold, GraphicsUnit.Pixel);
        TextRenderer.DrawText(graphics, label, font, new Rectangle(0, 0, 32, 32), Color.White, Color.Transparent,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine |
            TextFormatFlags.NoPadding | TextFormatFlags.NoPrefix);
        var handle = bitmap.GetHicon();
        try { return (Icon)Icon.FromHandle(handle).Clone(); }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr handle);

    protected override void ExitThreadCore()
    {
        _refreshTimer.Stop();
        _updateTimer.Stop();
        _tiboTimer.Stop();
        _refreshTimer.Dispose();
        _updateTimer.Dispose();
        _tiboTimer.Dispose();
        _notifyIcon.Visible = false;
        _client.Dispose();
        _tiboClient.Dispose();
        _menu.Dispose();
        _menuOwner.Dispose();
        _xAuthToken = null;
        _xLoginForm?.Dispose();
        _tiboFeedForm?.Dispose();
        _notifyIcon.Dispose();
        _generatedIcon?.Dispose();
        base.ExitThreadCore();
    }
}
