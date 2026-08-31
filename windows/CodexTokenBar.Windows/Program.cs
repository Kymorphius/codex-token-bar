namespace CodexTokenBar.Windows;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        using var singleInstance = new Mutex(
            initiallyOwned: true,
            name: @"Global\dev.333.codex-token-bar.windows",
            createdNew: out var isFirstInstance);
        if (!isFirstInstance) return;

        ApplicationConfiguration.Initialize();
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        try
        {
            Application.Run(new TrayApplicationContext(SynchronizationContext.Current!));
        }
        finally
        {
            singleInstance.ReleaseMutex();
        }
    }
}
