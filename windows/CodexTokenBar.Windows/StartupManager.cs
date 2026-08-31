using Microsoft.Win32;

namespace CodexTokenBar.Windows;

internal static class StartupManager
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string SettingsKey = @"Software\333.dev\CodexTokenBar";
    private const string ValueName = "Codex Token Bar";
    private const string InitializedValueName = "StartupPreferenceInitialized";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
            return key?.GetValue(ValueName) is string value && !string.IsNullOrWhiteSpace(value);
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        if (enabled)
            key.SetValue(ValueName, $"\"{Environment.ProcessPath}\"");
        else
            key.DeleteValue(ValueName, throwOnMissingValue: false);

        using var settings = Registry.CurrentUser.CreateSubKey(SettingsKey, writable: true);
        settings.SetValue(InitializedValueName, 1, RegistryValueKind.DWord);
    }

    public static void EnsureDefaultEnabled()
    {
        using var existingSettings = Registry.CurrentUser.OpenSubKey(SettingsKey, writable: false);
        if (existingSettings?.GetValue(InitializedValueName) is not null) return;
        SetEnabled(true);
    }
}
