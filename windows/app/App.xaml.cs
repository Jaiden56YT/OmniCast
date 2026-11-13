using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using Microsoft.UI.Xaml;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast;

public partial class App : Application
{
    public static new App? Current => Application.Current as App;

    public MainWindow? Window { get; private set; }
    public TrayIcon? Tray { get; private set; }
    private bool _quitting;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => LogCrash(e.Exception);
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var host = EngineHost.Current;
        Toasts.Register();
        host.Notify += (title, body) =>
        {
            // Only interrupt when the window isn't in front.
            if (Window == null || !Window.IsForeground)
                Toasts.Show(title, body);
        };

        Window = new MainWindow();
        Window.CloseRequested += OnCloseRequested;
        if (!Program.StartMinimized)
            Window.Activate();

        Tray = new TrayIcon(Path.Combine(AppContext.BaseDirectory, "Assets"));
        Tray.OpenRequested += ShowMainWindow;
        Tray.QuitRequested += Quit;
        Tray.Action += OnHotkey;
        Tray.SceneRequested += n => host.SwitchSceneByNumber(n);
        Tray.ScenesProvider = () => host.Scenes.Select(s => (s.Name, s.Id == host.ActiveScene.Id)).ToList();
        host.PropertyChanged += OnHostChanged;

        await host.StartAsync();
    }

    private void OnHostChanged(object? sender, PropertyChangedEventArgs e)
    {
        var host = EngineHost.Current;
        if (e.PropertyName is nameof(EngineHost.IsLive) or nameof(EngineHost.IsRecording) or nameof(EngineHost.IsMicMuted))
            Tray?.Update(host.IsLive, host.IsRecording, host.IsMicMuted);
    }

    // Hotkeys and the tray menu act the same as the buttons in the window.
    private void OnHotkey(HotkeyAction action)
    {
        var host = EngineHost.Current;
        string? error = null;
        switch (action)
        {
            case HotkeyAction.GoLive:
                if (host.IsLive) host.EndStream();
                else error = host.GoLive();
                break;
            case HotkeyAction.Record:
                if (host.IsRecording) host.StopRecording();
                else error = host.StartRecording();
                break;
            case HotkeyAction.MuteMic:
                host.ToggleMicMute();
                Toasts.Show(host.IsMicMuted ? "Mic muted" : "Mic on", "");
                break;
        }
        if (error != null)
            Toasts.Show("OmniCast", error);
    }

    public void ShowMainWindow()
    {
        Window?.DispatcherQueue.TryEnqueue(() => Window.BringToFront());
    }

    private void OnCloseRequested(object? sender, EventArgs e)
    {
        // Closing the window keeps OmniCast in the tray (Settings > App), so a
        // stream or recording isn't cut by accident. Quit from the tray menu.
        if (!_quitting && EngineHost.Current.Settings.CloseToTray)
            Window?.HideToTray();
        else
            Quit();
    }

    public void Quit()
    {
        if (_quitting) return;
        _quitting = true;
        EngineHost.Current.Shutdown();
        Tray?.Dispose();
        Toasts.Unregister();
        Window?.CloseForReal();
        Exit();
    }

    private static void LogCrash(Exception ex)
    {
        try
        {
            Directory.CreateDirectory(EngineHost.LogsDir);
            File.AppendAllText(Path.Combine(EngineHost.LogsDir, "app-errors.txt"), $"{DateTime.Now:s} {ex}\n\n");
        }
        catch { }
    }
}
