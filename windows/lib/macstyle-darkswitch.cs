// macstyle dark-mode wallpaper: the day picture in light mode, the night picture in dark mode.
//
// Replaces the PowerShell watcher that checked every two seconds. This one sleeps until Windows
// says the Personalize key changed (RegNotifyChangeKeyValue), so it uses no CPU while waiting and
// a few MB of memory. "-once" sets the picture and exits. The pair is "wallpaper" in
// %LOCALAPPDATA%\macstyle\config.json (default mountain). Built with the C# compiler that is part
// of Windows (.NET Framework 4).
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32;

static class DarkSwitch
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint param, string vparam, uint winIni);
    [DllImport("advapi32.dll")]
    static extern int RegNotifyChangeKeyValue(IntPtr key, bool subtree, uint filter, IntPtr evt, bool async);

    const string Key = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    static readonly string State = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "macstyle");
    static string last = "";

    static bool Dark()
    {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Key))
        {
            object v = k == null ? null : k.GetValue("AppsUseLightTheme");
            return v is int && (int)v == 0;
        }
    }

    static string Pair()
    {
        try
        {
            Match m = Regex.Match(File.ReadAllText(Path.Combine(State, "config.json")), "\"wallpaper\"\\s*:\\s*\"([A-Za-z0-9_-]+)\"");
            if (m.Success) return m.Groups[1].Value;
        }
        catch { }
        return "mountain";
    }

    static void Apply()
    {
        string pic = Path.Combine(State, "wallpapers", Pair() + (Dark() ? "-d.jpg" : "-l.jpg"));
        if (pic != last && File.Exists(pic))
        {
            SystemParametersInfo(0x0014, 0, pic, 3);   // SPI_SETDESKWALLPAPER, saved and announced
            last = pic;
        }
    }

    static void Main(string[] args)
    {
        // -once only sets the picture: it never takes the one-per-user lock, so the watcher
        // started right after it is not mistaken for a second copy
        if (args.Length > 0 && args[0].Equals("-once", StringComparison.OrdinalIgnoreCase)) { Apply(); return; }
        bool created;
        using (Mutex one = new Mutex(true, @"Local\macstyle-darkswitch", out created))
        {
            if (!created) return;                          // already running for this user
            Apply();
            while (true)
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(Key))
                {
                    if (k == null) { Thread.Sleep(60000); continue; }
                    // REG_NOTIFY_CHANGE_LAST_SET: wait here until a value under the key changes
                    RegNotifyChangeKeyValue(k.Handle.DangerousGetHandle(), false, 4, IntPtr.Zero, false);
                }
                Thread.Sleep(300);                          // Windows writes a few values in a row
                Apply();
            }
        }
    }
}
