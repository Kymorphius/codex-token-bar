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
    private readonly string _directory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Codex Token Bar");
    private readonly string _path;
    private readonly string _readStatePath;
    private HashSet<string> _readUrls = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<TiboPost> Posts { get; private set; } = [];

    public TiboPostStore()
    {
        _path = Path.Combine(_directory, "tibo-posts.json");
        _readStatePath = Path.Combine(_directory, "tibo-read-state.json");
        Load();
        LoadReadState();
    }

    public int UnreadCount => Posts.Count(post => !_readUrls.Contains(post.Url));

    public bool IsUnread(string url) => !_readUrls.Contains(url);

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

    public bool MarkRead(string url)
    {
        if (!_readUrls.Add(url)) return false;
        SaveReadState();
        return true;
    }

    public bool MarkAllRead()
    {
        var changed = false;
        foreach (var post in Posts) changed |= _readUrls.Add(post.Url);
        if (changed) SaveReadState();
        return changed;
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
            Directory.CreateDirectory(_directory);
            File.WriteAllText(_path, JsonSerializer.Serialize(Posts, JsonOptions));
        }
        catch { }
    }

    private void LoadReadState()
    {
        try
        {
            if (File.Exists(_readStatePath))
            {
                var urls = JsonSerializer.Deserialize<string[]>(File.ReadAllText(_readStatePath)) ?? [];
                _readUrls = new HashSet<string>(urls, StringComparer.OrdinalIgnoreCase);
                return;
            }

            // On the first upgrade, treat the existing cache as the read baseline.
            // A fresh installation has no cached posts, so its first fetch is unread.
            _readUrls = new HashSet<string>(Posts.Select(post => post.Url), StringComparer.OrdinalIgnoreCase);
            SaveReadState();
        }
        catch
        {
            _readUrls = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        }
    }

    private void SaveReadState()
    {
        try
        {
            Directory.CreateDirectory(_directory);
            File.WriteAllText(_readStatePath, JsonSerializer.Serialize(_readUrls.Order(), JsonOptions));
        }
        catch { }
    }
}
