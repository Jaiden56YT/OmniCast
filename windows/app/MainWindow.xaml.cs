using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using OmniCast.Engine;
using OmniCast.Pages;
using Windows.Graphics;

namespace OmniCast;

public sealed partial class MainWindow : Window
{
    public event EventHandler? CloseRequested;
    // True while any part of the window can be seen (not minimised or hidden).
    public event Action<bool>? ShownChanged;

    public bool IsForeground { get; private set; }
    public bool IsShown { get; private set; } = true;
    private bool _closingForReal;

    public MainWindow()
    {
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "OmniCast.ico"));

        // A sensible first size: fits a 1366x768 laptop, centred.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        double scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        int w = Math.Min((int)(1280 * scale), area.Width), h = Math.Min((int)(820 * scale), area.Height);
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h));

        AppWindow.Closing += (_, e) =>
        {
            if (_closingForReal) return;
            e.Cancel = true;
            CloseRequested?.Invoke(this, EventArgs.Empty);
        };
        AppWindow.Changed += (_, e) =>
        {
            if (e.DidPresenterChange || e.DidVisibilityChange || e.DidSizeChange)
                UpdateShown();
        };
        Activated += (_, e) => IsForeground = e.WindowActivationState != WindowActivationState.Deactivated;
        VisibilityChanged += (_, _) => UpdateShown();

        EngineHost.Current.PropertyChanged += OnHostChanged;
        ContentFrame.Navigate(typeof(StudioPage));
    }

    private void UpdateShown()
    {
        bool minimized = AppWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized;
        bool shown = AppWindow.IsVisible && !minimized;
        if (shown != IsShown)
        {
            IsShown = shown;
            ShownChanged?.Invoke(shown);
        }
    }

    private void OnHostChanged(object? sender, PropertyChangedEventArgs e)
    {
        var host = EngineHost.Current;
        if (e.PropertyName == nameof(EngineHost.IsLive))
            LivePill.Visibility = host.IsLive ? Visibility.Visible : Visibility.Collapsed;
        else if (e.PropertyName == nameof(EngineHost.IsRecording))
            RecPill.Visibility = host.IsRecording ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Nav_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        Type page = args.IsSettingsSelected
            ? typeof(SettingsPage)
            : (args.SelectedItem as NavigationViewItem)?.Tag as string == "destinations"
                ? typeof(DestinationsPage)
                : typeof(StudioPage);
        if (ContentFrame.CurrentSourcePageType != page)
            ContentFrame.Navigate(page, null, new SuppressNavigationTransitionInfo());
    }

    public void BringToFront()
    {
        AppWindow.Show();
        if (AppWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized)
            p.Restore();
        Activate();
        SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        UpdateShown();
    }

    public void HideToTray()
    {
        AppWindow.Hide();
        UpdateShown();
    }

    public void CloseForReal()
    {
        _closingForReal = true;
        Close();
    }

    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);
}
