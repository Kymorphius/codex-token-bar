using System.Text;

namespace CodexTokenBar.Windows;

internal static class DiagnosticStatus
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Codex Token Bar");

    public static string FilePath => Path.Combine(DirectoryPath, "status.txt");

    public static void WriteStarting() => Write("正在连接 Codex…");

    public static void WriteError(string message) => Write($"错误：{message}");

    public static void WriteSnapshot(UsageSnapshot snapshot)
    {
        var text = new StringBuilder("连接正常");
        foreach (var bucket in snapshot.Buckets)
        {
            if (bucket.HeadlineWindow is not { } window) continue;
            text.AppendLine();
            text.Append(bucket.DisplayName);
            text.Append("：剩余 ");
            text.Append(window.RemainingPercent.ToString("0.#"));
            text.Append('%');
        }
        Write(text.ToString());
    }

    private static void Write(string status)
    {
        try
        {
            Directory.CreateDirectory(DirectoryPath);
            File.WriteAllText(
                FilePath,
                $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}\r\n{status}\r\n",
                Encoding.UTF8);
        }
        catch { }
    }
}
