using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using System.Globalization;

namespace CodexTokenBar.Windows;

internal sealed class XLoginForm : Form
{
    private readonly WebView2 _webView = new() { Dock = DockStyle.Fill };
    private readonly Label _status = new()
    {
        Text = "正在初始化 X 登录页…",
        AutoSize = false,
        Dock = DockStyle.Fill,
        TextAlign = ContentAlignment.MiddleLeft,
        Padding = new Padding(10, 0, 0, 0)
    };
    private readonly System.Windows.Forms.Timer _cookieTimer = new() { Interval = 1_500 };
    private readonly Button _internalLogin = new() { Text = "打开内置登录页面", AutoSize = true, Margin = new Padding(8), Enabled = false };
    private readonly ComboBox _language = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 145, Margin = new Padding(4, 9, 8, 7) };
    private readonly Button _translationSettings = new() { Text = "X 翻译设置", AutoSize = true, Margin = new Padding(8), Enabled = false };
    private bool _checkingCookie;
    private bool _changingLanguage;
    private string? _lastDetectedToken;

    private sealed record BrowserLanguage(string Key, string Label, string WebViewTag, string XCode);
    private static readonly BrowserLanguage[] Languages =
    [
        new("system", $"跟随系统（{CultureInfo.CurrentUICulture.NativeName}）", "", ""),
        new("zh-CN", "简体中文", "zh-CN", "zh-cn"),
        new("zh-TW", "繁體中文", "zh-TW", "zh-tw"),
        new("en-US", "English", "en-US", "en"),
        new("ja-JP", "日本語", "ja-JP", "ja"),
        new("ko-KR", "한국어", "ko-KR", "ko"),
        new("fr-FR", "Français", "fr-FR", "fr"),
        new("de-DE", "Deutsch", "de-DE", "de"),
        new("es-ES", "Español", "es-ES", "es")
    ];

    public event Action<string>? AuthTokenAvailable;

    public XLoginForm()
    {
        Text = "Tibo 动态 · X 登录";
        ClientSize = new Size(1080, 760);
        MinimumSize = new Size(760, 520);
        StartPosition = FormStartPosition.CenterScreen;

        var topBar = new TableLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 48,
            ColumnCount = 6,
            RowCount = 1
        };
        topBar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        topBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        topBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        topBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        topBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        topBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        foreach (var option in Languages) _language.Items.Add(option);
        _language.DisplayMember = nameof(BrowserLanguage.Label);
        _language.SelectedItem = Languages.FirstOrDefault(option => option.Key == AppSettings.XBrowserLanguage) ?? Languages[0];
        _language.SelectedIndexChanged += async (_, _) => await ChangeLanguageAsync();
        _internalLogin.Click += (_, _) =>
        {
            if (_webView.CoreWebView2 is null) return;
            NavigateWithLanguage(_lastDetectedToken is null
                ? "https://x.com/i/flow/login"
                : "https://x.com/thsottiaux");
        };
        _translationSettings.Click += (_, _) => NavigateWithLanguage("https://x.com/settings/language");
        var external = new Button { Text = "用系统浏览器打开", AutoSize = true, Margin = new Padding(8) };
        external.Click += (_, _) =>
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://x.com/thsottiaux") { UseShellExecute = true }); }
            catch { }
        };
        topBar.Controls.Add(_status, 0, 0);
        topBar.Controls.Add(new Label { Text = "网页语言", AutoSize = true, Anchor = AnchorStyles.None }, 1, 0);
        topBar.Controls.Add(_language, 2, 0);
        topBar.Controls.Add(_translationSettings, 3, 0);
        topBar.Controls.Add(_internalLogin, 4, 0);
        topBar.Controls.Add(external, 5, 0);
        Controls.Add(_webView);
        Controls.Add(topBar);

        _cookieTimer.Tick += async (_, _) => await DetectLoginCookieAsync();
        Shown += async (_, _) => await InitializeAsync();
        FormClosed += (_, _) => _cookieTimer.Stop();
    }

    private async Task InitializeAsync()
    {
        if (_webView.CoreWebView2 is not null)
        {
            _cookieTimer.Start();
            await DetectLoginCookieAsync();
            return;
        }

        try
        {
            var userDataFolder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Codex Token Bar",
                "WebView2");
            var options = new CoreWebView2EnvironmentOptions { Language = SelectedLanguage.WebViewTag };
            var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: userDataFolder, options: options);
            await _webView.EnsureCoreWebView2Async(environment);
            var core = _webView.CoreWebView2 ?? throw new InvalidOperationException("WebView2 初始化失败。");
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = true;
            core.AddWebResourceRequestedFilter("https://x.com/*", CoreWebView2WebResourceContext.All);
            core.AddWebResourceRequestedFilter("https://*.x.com/*", CoreWebView2WebResourceContext.All);
            core.AddWebResourceRequestedFilter("https://twitter.com/*", CoreWebView2WebResourceContext.All);
            core.AddWebResourceRequestedFilter("https://*.twitter.com/*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, eventArgs) =>
                eventArgs.Request.Headers.SetHeader("Accept-Language", AcceptLanguageHeader);
            core.NavigationCompleted += async (_, _) => await DetectLoginCookieAsync();
            core.NewWindowRequested += (_, eventArgs) =>
            {
                eventArgs.Handled = true;
                if (!string.IsNullOrWhiteSpace(eventArgs.Uri)) core.Navigate(eventArgs.Uri);
            };
            _internalLogin.Enabled = true;
            _translationSettings.Enabled = true;
            await ApplyLanguageCookiesAsync();
            NavigateWithLanguage("https://x.com/thsottiaux");
            _status.Text = $"请在 X 页面完成登录；网页语言：{SelectedLanguage.Label}";
            _cookieTimer.Start();
        }
        catch (Exception error)
        {
            _status.Text = "无法打开 X 登录页：" + error.Message;
        }
    }

    private BrowserLanguage SelectedLanguage
    {
        get
        {
            var selected = _language.SelectedItem as BrowserLanguage ?? Languages[0];
            if (selected.Key != "system") return selected;
            var culture = CultureInfo.CurrentUICulture;
            var key = culture.Name;
            var exact = Languages.FirstOrDefault(option => option.Key.Equals(key, StringComparison.OrdinalIgnoreCase));
            if (exact is not null) return selected with { WebViewTag = exact.WebViewTag, XCode = exact.XCode };
            var language = culture.TwoLetterISOLanguageName;
            var approximate = Languages.FirstOrDefault(option => option.WebViewTag.StartsWith(language + "-", StringComparison.OrdinalIgnoreCase));
            return selected with
            {
                WebViewTag = culture.Name.Length > 0 ? culture.Name : "en-US",
                XCode = approximate?.XCode ?? language
            };
        }
    }

    private string AcceptLanguageHeader
    {
        get
        {
            var language = SelectedLanguage.WebViewTag;
            var baseLanguage = language.Split('-')[0];
            return baseLanguage.Equals("en", StringComparison.OrdinalIgnoreCase)
                ? language + ",en;q=0.9"
                : $"{language},{baseLanguage};q=0.9,en;q=0.8";
        }
    }

    private async Task ChangeLanguageAsync()
    {
        if (_changingLanguage || _language.SelectedItem is not BrowserLanguage selected) return;
        AppSettings.XBrowserLanguage = selected.Key;
        if (_webView.CoreWebView2 is null) return;
        _changingLanguage = true;
        try
        {
            await ApplyLanguageCookiesAsync();
            var target = _webView.Source?.AbsoluteUri;
            NavigateWithLanguage(string.IsNullOrWhiteSpace(target) || target == "about:blank"
                ? "https://x.com/thsottiaux"
                : target);
            _status.Text = $"网页语言已切换为：{SelectedLanguage.Label} · X 翻译入口会按此语言显示";
        }
        catch (Exception error) { _status.Text = "切换网页语言失败：" + error.Message; }
        finally { _changingLanguage = false; }
    }

    private Task ApplyLanguageCookiesAsync()
    {
        var core = _webView.CoreWebView2;
        if (core is null) return Task.CompletedTask;
        var language = SelectedLanguage.XCode;
        foreach (var domain in new[] { ".x.com", ".twitter.com" })
        {
            var cookie = core.CookieManager.CreateCookie("lang", language, domain, "/");
            cookie.IsSecure = true;
            cookie.Expires = DateTime.Now.AddYears(1);
            core.CookieManager.AddOrUpdateCookie(cookie);
        }
        return Task.CompletedTask;
    }

    private void NavigateWithLanguage(string address)
    {
        var core = _webView.CoreWebView2;
        if (core is null) return;
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri)) return;
        var builder = new UriBuilder(uri);
        var query = builder.Query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(part => !part.StartsWith("lang=", StringComparison.OrdinalIgnoreCase))
            .ToList();
        query.Add("lang=" + Uri.EscapeDataString(SelectedLanguage.XCode));
        builder.Query = string.Join("&", query);
        core.Navigate(builder.Uri.AbsoluteUri);
    }

    private async Task DetectLoginCookieAsync()
    {
        if (_checkingCookie || _webView.CoreWebView2 is null) return;
        _checkingCookie = true;
        try
        {
            var cookies = await _webView.CoreWebView2.CookieManager.GetCookiesAsync("https://x.com");
            var authToken = cookies.FirstOrDefault(cookie =>
                cookie.Name == "auth_token" &&
                (cookie.Domain.Equals("x.com", StringComparison.OrdinalIgnoreCase) ||
                 cookie.Domain.EndsWith(".x.com", StringComparison.OrdinalIgnoreCase)))?.Value;
            if (string.IsNullOrWhiteSpace(authToken))
            {
                _status.Text = "尚未检测到 X 登录，请继续完成登录。";
                return;
            }

            _status.Text = "X 已登录 · Cookie 由 WebView2 和 Windows 当前用户加密保护";
            _internalLogin.Text = "打开 Tibo 时间线";
            if (authToken == _lastDetectedToken) return;
            _lastDetectedToken = authToken;
            AuthTokenAvailable?.Invoke(authToken);
        }
        catch (Exception error)
        {
            _status.Text = "检查 X 登录状态失败：" + error.Message;
        }
        finally { _checkingCookie = false; }
    }
}
