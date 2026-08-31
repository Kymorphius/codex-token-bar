using System.Text.Json;

namespace CodexTokenBar.Windows;

internal sealed record TiboPost(
    string Text,
    string Url,
    DateTimeOffset? PostedAt,
    DateTimeOffset CapturedAt,
    bool IsFromRssHub = true);

internal sealed class TiboPostStore
{
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };
    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Codex Token Bar", "tibo-posts.json");

    public IReadOnlyList<TiboPost> Posts { get; private set; } = [];

    public TiboPostStore() => Load();

    public void Merge(IEnumerable<TiboPost> incoming)
    {
        var byUrl = Posts.ToDictionary(post => post.Url, StringComparer.OrdinalIgnoreCase);
        foreach (var post in incoming)
        {
            if (byUrl.TryGetValue(post.Url, out var existing) && existing.Text.Length > post.Text.Length)
                continue;
            byUrl[post.Url] = post;
        }
        Posts = byUrl.Values
            .OrderByDescending(post => post.PostedAt ?? post.CapturedAt)
            .Take(20)
            .ToArray();
        Save();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            Posts = JsonSerializer.Deserialize<TiboPost[]>(File.ReadAllText(_path)) ?? [];
        }
        catch { Posts = []; }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(Posts, JsonOptions));
        }
        catch { }
    }
}
