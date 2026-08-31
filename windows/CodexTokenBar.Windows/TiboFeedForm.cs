using System.Diagnostics;

namespace CodexTokenBar.Windows;

internal sealed class TiboFeedForm : Form
{
    private readonly Label _status = new() { AutoSize = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
    private readonly FlowLayoutPanel _feed = new()
    {
        Dock = DockStyle.Fill,
        AutoScroll = true,
        FlowDirection = FlowDirection.TopDown,
        WrapContents = false,
        Padding = new Padding(16)
    };
    private readonly Button _refresh = new() { Text = "刷新 RSS", AutoSize = true };

    public event Action? RefreshRequested;

    public TiboFeedForm()
    {
        Text = "Tibo 消息";
        ClientSize = new Size(780, 720);
        MinimumSize = new Size(600, 460);
        StartPosition = FormStartPosition.CenterScreen;
        var header = new TableLayoutPanel { Dock = DockStyle.Top, Height = 48, Padding = new Padding(12, 8, 12, 6), ColumnCount = 2 };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _refresh.Click += (_, _) => RefreshRequested?.Invoke();
        header.Controls.Add(_status, 0, 0);
        header.Controls.Add(_refresh, 1, 0);
        Controls.Add(_feed);
        Controls.Add(header);
        Resize += (_, _) => ResizeCards();
    }

    public void UpdateFeed(IReadOnlyList<TiboPost> posts, string status, bool refreshing)
    {
        _status.Text = status;
        _refresh.Enabled = !refreshing;
        _refresh.Text = refreshing ? "正在刷新…" : "刷新 RSS";
        _feed.SuspendLayout();
        _feed.Controls.Clear();
        if (posts.Count == 0)
        {
            _feed.Controls.Add(new Label
            {
                AutoSize = false,
                Height = 100,
                Text = "RSS 暂无消息\r\n\r\n请先在内置 X 页面完成登录，然后点击“刷新 RSS”。",
                Font = new Font("Segoe UI", 11),
                ForeColor = SystemColors.GrayText
            });
        }
        foreach (var post in posts)
        {
            var card = new Panel { Height = 150, BackColor = SystemColors.ControlLightLight, Margin = new Padding(0, 0, 0, 12), Padding = new Padding(14) };
            var metadata = new Label
            {
                Dock = DockStyle.Top,
                Height = 24,
                Text = $"Tibo · @thsottiaux · {PostAge(post)}",
                ForeColor = SystemColors.GrayText,
                Font = new Font("Segoe UI", 9, FontStyle.Bold)
            };
            var button = new LinkLabel { Dock = DockStyle.Bottom, Height = 25, Text = "查看原帖", LinkColor = Color.RoyalBlue };
            button.LinkClicked += (_, _) => OpenUrl(post.Url);
            var body = new TextBox
            {
                Dock = DockStyle.Fill,
                Multiline = true,
                ReadOnly = true,
                BorderStyle = BorderStyle.None,
                BackColor = SystemColors.ControlLightLight,
                Font = new Font("Segoe UI", 10.5f),
                Text = post.Text,
                ScrollBars = ScrollBars.Vertical
            };
            card.Controls.Add(body);
            card.Controls.Add(button);
            card.Controls.Add(metadata);
            _feed.Controls.Add(card);
        }
        _feed.ResumeLayout();
        ResizeCards();
    }

    private void ResizeCards()
    {
        var width = Math.Max(420, _feed.ClientSize.Width - _feed.Padding.Horizontal - SystemInformation.VerticalScrollBarWidth - 4);
        foreach (Control control in _feed.Controls) control.Width = width;
    }

    private static string PostAge(TiboPost post)
    {
        var elapsed = DateTimeOffset.Now - (post.PostedAt ?? post.CapturedAt);
        if (elapsed.TotalMinutes < 60) return $"{Math.Max(1, (int)elapsed.TotalMinutes)} 分钟前";
        if (elapsed.TotalHours < 24) return $"{(int)elapsed.TotalHours} 小时前";
        return $"{Math.Max(1, (int)elapsed.TotalDays)} 天前";
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }
}
