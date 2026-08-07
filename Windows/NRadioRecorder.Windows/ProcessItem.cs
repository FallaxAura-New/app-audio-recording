using System.Diagnostics;

namespace NRadioRecorder.Windows;

internal sealed record ProcessItem(int Id, string Name, string WindowTitle)
{
    public string DisplayName => string.IsNullOrWhiteSpace(WindowTitle)
        ? $"{Name}  ·  PID {Id}"
        : $"{Name}  ·  {WindowTitle}  ·  PID {Id}";

    public static IReadOnlyList<ProcessItem> GetVisibleApplications()
    {
        var currentPid = Environment.ProcessId;
        var items = new List<ProcessItem>();

        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    if (process.Id == currentPid || process.HasExited || process.MainWindowHandle == IntPtr.Zero)
                    {
                        continue;
                    }

                    items.Add(new ProcessItem(
                        process.Id,
                        process.ProcessName,
                        process.MainWindowTitle));
                }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
            }
        }

        return items
            .OrderBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(item => item.Id)
            .ToArray();
    }
}
