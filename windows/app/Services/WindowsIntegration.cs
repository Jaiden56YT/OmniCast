using System;
using Microsoft.Win32;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace OmniCast.Services;

// Toast notifications (disconnects, reconnects, recording errors).
public static class Toasts
{
    private static bool _registered;

    public static void Register()
    {
        try
        {
            AppNotificationManager.Default.Register();
            _registered = true;
        }
        catch (Exception)
        {
            // Notifications are a nice-to-have: if Windows refuses (e.g. they're
            // turned off by policy), the app works the same without them.
            _registered = false;
        }
    }

    public static void Show(string title, string body)
    {
        if (!_registered) return;
        try
        {
            var toast = new AppNotificationBuilder().AddText(title).AddText(body).BuildNotification();
            AppNotificationManager.Default.Show(toast);
        }
        catch (Exception) { }
    }

    public static void Unregister()
    {
        if (!_registered) return;
        try { AppNotificationManager.Default.Unregister(); } catch (Exception) { }
    }
}

// "Start with Windows": a value under HKCU\...\Run, so it needs no admin rights
// and shows up (and can be turned off) in Task Manager > Startup apps.
public static class StartWithWindows
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "OmniCast";

    public static void Set(bool on)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        if (key == null) return;
        if (on)
            key.SetValue(Name, $"\"{Environment.ProcessPath}\" --minimized");
        else
            key.DeleteValue(Name, throwOnMissingValue: false);
    }

    public static bool IsOn()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(Name) is string s && s.Contains(Environment.ProcessPath ?? "\u0000", StringComparison.OrdinalIgnoreCase);
    }
}
