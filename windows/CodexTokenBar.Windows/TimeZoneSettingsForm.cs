namespace CodexTokenBar.Windows;

internal static class DisplayTimeZone
{
    public static TimeZoneInfo Current
    {
        get
        {
            var identifier = AppSettings.DisplayTimeZoneId;
            if (!string.IsNullOrWhiteSpace(identifier))
            {
                try { return TimeZoneInfo.FindSystemTimeZoneById(identifier); }
                catch (TimeZoneNotFoundException) { }
                catch (InvalidTimeZoneException) { }
            }
            return TimeZoneInfo.Local;
        }
    }

    public static string Name(TimeZoneInfo zone, DateTime? localTime = null)
    {
        var local = localTime ?? TimeZoneInfo.ConvertTime(DateTimeOffset.Now, zone).DateTime;
        var name = zone.IsDaylightSavingTime(local) ? zone.DaylightName : zone.StandardName;
        return $"{name}（{Offset(zone.GetUtcOffset(local))}）";
    }

    private static string Offset(TimeSpan offset)
    {
        if (offset == TimeSpan.Zero) return "UTC";
        var sign = offset < TimeSpan.Zero ? "−" : "+";
        var absolute = offset.Duration();
        return absolute.Minutes == 0
            ? $"UTC{sign}{absolute.Hours}"
            : $"UTC{sign}{absolute.Hours}:{absolute.Minutes:00}";
    }
}

internal sealed class TimeZoneSettingsForm : Form
{
    private sealed record Choice(string? Id, string Label)
    {
        public override string ToString() => Label;
    }

    private readonly ComboBox _timeZones = new()
    {
        DropDownStyle = ComboBoxStyle.DropDownList,
        Width = 480
    };

    public TimeZoneSettingsForm()
    {
        Text = "显示时区";
        ClientSize = new Size(550, 180);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        _timeZones.Items.Add(new Choice(
            null,
            $"跟随系统（{DisplayTimeZone.Name(TimeZoneInfo.Local)}）"));
        foreach (var zone in TimeZoneInfo.GetSystemTimeZones())
            _timeZones.Items.Add(new Choice(zone.Id, $"{zone.Id} · {DisplayTimeZone.Name(zone)}"));

        var selectedId = AppSettings.DisplayTimeZoneId;
        _timeZones.SelectedIndex = Enumerable.Range(0, _timeZones.Items.Count)
            .FirstOrDefault(index => (_timeZones.Items[index] as Choice)?.Id == selectedId);

        var save = new Button { Text = "保存", DialogResult = DialogResult.OK, AutoSize = true };
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, AutoSize = true };
        save.Click += (_, _) =>
            AppSettings.DisplayTimeZoneId = (_timeZones.SelectedItem as Choice)?.Id;
        AcceptButton = save;
        CancelButton = cancel;

        var buttons = new FlowLayoutPanel
        {
            AutoSize = true,
            FlowDirection = FlowDirection.LeftToRight
        };
        buttons.Controls.Add(save);
        buttons.Controls.Add(cancel);

        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(28, 22, 28, 18)
        };
        layout.Controls.Add(new Label
        {
            Text = "默认跟随 Windows 系统时区；也可以选择一个固定时区。",
            AutoSize = true
        });
        layout.Controls.Add(new Panel { Width = 1, Height = 5 });
        layout.Controls.Add(_timeZones);
        layout.Controls.Add(new Panel { Width = 1, Height = 8 });
        layout.Controls.Add(buttons);
        Controls.Add(layout);
    }
}
