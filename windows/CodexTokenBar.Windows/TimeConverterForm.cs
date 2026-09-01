namespace CodexTokenBar.Windows;

internal sealed class TimeConverterForm : Form
{
    private static readonly TimeZoneInfo Pacific = TimeZoneInfo.FindSystemTimeZoneById("Pacific Standard Time");
    private readonly TimeZoneInfo _local = DisplayTimeZone.Current;
    private readonly ComboBox _sourceZone = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 250 };
    private readonly DateTimePicker _date = new() { Format = DateTimePickerFormat.Custom, CustomFormat = "yyyy年M月d日 HH:mm", Width = 250 };
    private readonly Label _result = new() { AutoSize = true, Font = new Font("Segoe UI", 11, FontStyle.Bold) };

    public TimeConverterForm()
    {
        Text = "本地时间 ↔ 太平洋时间";
        ClientSize = new Size(420, 230);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;

        _sourceZone.Items.AddRange([
            $"{DisplayTimeZone.Name(_local)} → 太平洋时间",
            $"太平洋时间 → {DisplayTimeZone.Name(_local)}"
        ]);
        _sourceZone.SelectedIndex = 0;
        _sourceZone.SelectedIndexChanged += (_, _) => UpdateResult();
        _date.ValueChanged += (_, _) => UpdateResult();

        var close = new Button { Text = "完成", DialogResult = DialogResult.OK, AutoSize = true };
        AcceptButton = close;
        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(28, 22, 28, 18)
        };
        layout.Controls.Add(new Label { Text = "选择输入时区和时间，换算结果会立即更新。", AutoSize = true });
        layout.Controls.Add(Spacer(5));
        layout.Controls.Add(_sourceZone);
        layout.Controls.Add(_date);
        layout.Controls.Add(Spacer(8));
        layout.Controls.Add(_result);
        layout.Controls.Add(Spacer(8));
        layout.Controls.Add(close);
        Controls.Add(layout);
        UpdateResult();
    }

    private void UpdateResult()
    {
        var source = _sourceZone.SelectedIndex == 0 ? _local : Pacific;
        var destination = _sourceZone.SelectedIndex == 0 ? Pacific : _local;
        var sourceTime = DateTime.SpecifyKind(_date.Value, DateTimeKind.Unspecified);
        var converted = TimeZoneInfo.ConvertTime(sourceTime, source, destination);
        var abbreviation = destination == Pacific
            ? (destination.IsDaylightSavingTime(converted) ? "PDT" : "PST")
            : DisplayTimeZone.Name(_local, converted);
        _result.Text = $"{abbreviation}：{converted:M月d日 ddd HH:mm}";
    }

    private static Control Spacer(int height) => new Panel { Width = 1, Height = height };
}
