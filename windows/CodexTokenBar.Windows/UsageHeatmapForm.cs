namespace CodexTokenBar.Windows;

internal sealed class UsageHeatmapForm : Form
{
    public UsageHeatmapForm(IReadOnlyList<UsageHistoryEntry> entries)
    {
        Text = "Codex 全年使用热力图";
        ClientSize = new Size(830, 180);
        MinimumSize = new Size(650, 180);
        StartPosition = FormStartPosition.CenterScreen;
        Controls.Add(new HeatmapControl(entries) { Dock = DockStyle.Fill });
    }

    private sealed class HeatmapControl(IReadOnlyList<UsageHistoryEntry> entries) : Control
    {
        private readonly IReadOnlyList<UsageHistoryEntry> _entries = entries;

        protected override void OnPaint(PaintEventArgs eventArgs)
        {
            base.OnPaint(eventArgs);
            eventArgs.Graphics.Clear(SystemColors.Window);
            const int cell = 11;
            const int gap = 3;
            const int left = 62;
            const int top = 44;
            using var labelBrush = new SolidBrush(SystemColors.GrayText);
            eventArgs.Graphics.DrawString("近 52 周 Codex 用量", Font, SystemBrushes.ControlText, 18, 14);
            eventArgs.Graphics.DrawString("周一", Font, labelBrush, 18, top + 1 * (cell + gap));
            eventArgs.Graphics.DrawString("周三", Font, labelBrush, 18, top + 3 * (cell + gap));
            eventArgs.Graphics.DrawString("周五", Font, labelBrush, 18, top + 5 * (cell + gap));

            if (_entries.Count == 0) return;
            var first = _entries[0].Date;
            foreach (var entry in _entries)
            {
                var offset = entry.Date.DayNumber - first.DayNumber;
                var column = offset / 7;
                var row = offset % 7;
                var color = HeatColor(entry.UsedPercent);
                using var brush = new SolidBrush(color);
                eventArgs.Graphics.FillRectangle(brush, left + column * (cell + gap), top + row * (cell + gap), cell, cell);
            }
        }

        private static Color HeatColor(double? value)
        {
            if (value is null) return Color.FromArgb(235, 237, 240);
            if (value < 2) return Color.FromArgb(218, 251, 225);
            if (value < 5) return Color.FromArgb(155, 233, 168);
            if (value < 10) return Color.FromArgb(64, 196, 99);
            return Color.FromArgb(33, 110, 57);
        }
    }
}
