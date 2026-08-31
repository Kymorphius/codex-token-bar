using System.Security.Cryptography;

namespace CodexTokenBar.Windows;

internal static class XAuthTokenStore
{
    private static readonly byte[] Entropy = "Codex Token Bar · X auth_token · v1"u8.ToArray();
    private static readonly string PathName = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Codex Token Bar", "x-session.bin");

    public static string? Load()
    {
        try
        {
            if (!File.Exists(PathName)) return null;
            var encrypted = File.ReadAllBytes(PathName);
            var clear = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
            var value = System.Text.Encoding.UTF8.GetString(clear);
            CryptographicOperations.ZeroMemory(clear);
            return string.IsNullOrWhiteSpace(value) ? null : value;
        }
        catch { return null; }
    }

    public static void Save(string value)
    {
        try
        {
            var clear = System.Text.Encoding.UTF8.GetBytes(value);
            var encrypted = ProtectedData.Protect(clear, Entropy, DataProtectionScope.CurrentUser);
            CryptographicOperations.ZeroMemory(clear);
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PathName)!);
            File.WriteAllBytes(PathName, encrypted);
        }
        catch { }
    }

    public static void Clear()
    {
        try { if (File.Exists(PathName)) File.Delete(PathName); }
        catch { }
    }
}
