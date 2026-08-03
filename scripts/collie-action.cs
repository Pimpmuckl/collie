using System;
using System.Diagnostics;
using System.IO;
using System.Linq;

internal static class CollieAction
{
    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static int Main(string[] args)
    {
        var executable = Process.GetCurrentProcess().MainModule.FileName;
        var root = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(executable), ".."));
        if (root.StartsWith(@"\\?\", StringComparison.Ordinal)) root = root.Substring(4);

        var powershell = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        var controlScript = Path.Combine(root, "scripts", "collie-ctl.ps1");
        var arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " +
            Quote(controlScript) + " " + string.Join(" ", args.Select(Quote));

        using (var child = Process.Start(new ProcessStartInfo(powershell, arguments)
        {
            UseShellExecute = false,
        }))
        {
            child.WaitForExit();
            return child.ExitCode;
        }
    }
}
