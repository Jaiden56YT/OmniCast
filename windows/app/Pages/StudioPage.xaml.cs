using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OmniCast.Controls;
using OmniCast.Engine;
using OmniCast.Services;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace OmniCast.Pages;

public sealed partial class StudioPage : Page
{
    private readonly EngineHost _host = EngineHost.Current;
    private readonly DispatcherQueueTimer _meterTimer;
    private readonly DispatcherQueueTimer _statsTimer;
    private readonly List<AudioRow> _rows = new();
    private readonly bool[] _attached = new bool[2];
    private bool _loaded, _updating;
    private uint _skippedAtStart, _laggedAtStart;

    public StudioPage()
    {
        InitializeComponent();

        RebuildAudioRows();
        _host.MixerChanged += () => { if (_loaded) RebuildAudioRows(); };

        var dq = DispatcherQueue.GetForCurrentThread();
        _meterTimer = dq.CreateTimer();
        _meterTimer.Interval = TimeSpan.FromMilliseconds(33);
        _meterTimer.Tick += (_, _) => { foreach (var r in _rows) r.UpdateMeter(); };
        _statsTimer = dq.CreateTimer();
        _statsTimer.Interval = TimeSpan.FromSeconds(1);
        _statsTimer.Tick += (_, _) => UpdateStats();

        _host.PropertyChanged += OnHostChanged;
        _host.EngineStarted += OnEngineStarted;
        _host.EngineStopping += DetachPreviews;
        _host.DestinationStatusChanged += _ => UpdateDestinationsLink();
        _host.ScenesChanged += () =>
        {
            if (!_loaded) return;
            RebuildSceneButtons();
            if (_host.IsRunning) LoadSourceLists(); // another scene may be on air now
        };

        Loaded += (_, _) =>
        {
            _loaded = true;
            if (App.Current?.Window is { } w)
                w.ShownChanged += OnShownChanged;
            if (_host.IsRunning && !_attached[0])
                OnEngineStarted();
            RebuildSceneButtons();
            RebuildAudioRows();
            LoadTransition();
            RefreshUi();
            UpdateTimersAndPreviews();
        };
        Unloaded += (_, _) =>
        {
            _loaded = false;
            if (App.Current?.Window is { } w)
                w.ShownChanged -= OnShownChanged;
            UpdateTimersAndPreviews();
        };
    }

    // ---------------------------------------------------------------- engine

    private void OnEngineStarted()
    {
        if (!_loaded) return;
        AttachPreview(Native.Wide, WidePanel);
        AttachPreview(Native.Tall, TallPanel);
        LoadSourceLists();
        RebuildSceneButtons();
        LoadTransition();
        Native.oc_get_stats(out var st);
        _skippedAtStart = st.SkippedWide + st.SkippedTall;
        _laggedAtStart = st.LaggedFrames;
        RefreshUi();
        UpdateTimersAndPreviews();
    }

    private void AttachPreview(int canvas, SwapChainPanel panel)
    {
        if (_attached[canvas] || panel.ActualWidth < 1 || panel.ActualHeight < 1) return;
        IntPtr unk = WinRT.MarshalInspectable<SwapChainPanel>.FromManaged(panel);
        try
        {
            _attached[canvas] = Native.oc_preview_attach(canvas, unk, (float)panel.ActualWidth, (float)panel.ActualHeight,
                panel.CompositionScaleX, panel.CompositionScaleY) != 0;
        }
        finally
        {
            Marshal.Release(unk);
        }
    }

    private void DetachPreviews()
    {
        for (int c = 0; c < 2; c++)
        {
            if (_attached[c]) Native.oc_preview_detach(c);
            _attached[c] = false;
        }
    }

    private void Panel_SizeChanged(object sender, SizeChangedEventArgs e) => ResizePanel((SwapChainPanel)sender);
    private void Panel_ScaleChanged(SwapChainPanel sender, object args) => ResizePanel(sender);

    private void ResizePanel(SwapChainPanel panel)
    {
        int canvas = panel == WidePanel ? Native.Wide : Native.Tall;
        if (!_host.IsRunning) return;
        if (!_attached[canvas])
            AttachPreview(canvas, panel);
        else
            Native.oc_preview_resize(canvas, (float)panel.ActualWidth, (float)panel.ActualHeight, panel.CompositionScaleX, panel.CompositionScaleY);
    }

    // Keep the 9:16 preview exactly as wide as its height needs.
    private void PreviewRow_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        double tall = Math.Max(80, e.NewSize.Height * 9.0 / 16.0);
        TallColumn.Width = new GridLength(Math.Min(tall, e.NewSize.Width * 0.4));
    }

    private void OnShownChanged(bool shown) => UpdateTimersAndPreviews();

    // Previews, meters and stats only run while you can see them.
    private void UpdateTimersAndPreviews()
    {
        bool visible = _loaded && (App.Current?.Window?.IsShown ?? true);
        bool preview = visible && _host.IsRunning && _host.Settings.LivePreview;
        for (int c = 0; c < 2; c++)
            if (_attached[c]) Native.oc_preview_set_enabled(c, preview ? 1 : 0);
        if (visible && _host.IsRunning) { _meterTimer.Start(); _statsTimer.Start(); }
        else { _meterTimer.Stop(); _statsTimer.Stop(); }
        UpdateOverlay();
    }

    private void UpdateOverlay()
    {
        bool showOverlay = !_host.IsRunning || !_host.Settings.LivePreview;
        PreviewOverlay.Visibility = showOverlay && !EngineError.IsOpen ? Visibility.Visible : Visibility.Collapsed;
        StartingRing.IsActive = _host.IsStarting;
        StartingRing.Visibility = _host.IsStarting ? Visibility.Visible : Visibility.Collapsed;
        OverlayText.Text = _host.IsStarting ? "Starting the engine…"
            : !_host.Settings.LivePreview ? "Live preview is off (Settings › App)"
            : "";
    }

    private async void Retry_Click(object sender, RoutedEventArgs e)
    {
        EngineError.IsOpen = false;
        await _host.StartAsync();
    }

    private void OnHostChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(EngineHost.IsStarting) or nameof(EngineHost.IsRunning) or nameof(EngineHost.StartError))
        {
            EngineError.IsOpen = !_host.IsRunning && !_host.IsStarting && _host.StartError.Length > 0;
            EngineError.Message = _host.StartError;
            UpdateTimersAndPreviews();
        }
        RefreshUi();
    }

    // ---------------------------------------------------------------- UI state

    private void RefreshUi()
    {
        bool running = _host.IsRunning;
        LiveButton.IsEnabled = running;
        RecordButton.IsEnabled = running;
        LiveText.Text = _host.IsLive ? "End stream" : "Go live";
        LiveIcon.Glyph = _host.IsLive ? "\uE71A" : "\uE93E";
        RecordText.Text = _host.IsRecording ? "Stop recording" : "Start recording";
        RecordIcon.Glyph = _host.IsRecording ? "\uE71A" : "\uE7C8";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(LiveButton, LiveText.Text);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(RecordButton, RecordText.Text);
        VcamButton.IsEnabled = running;
        VcamText.Text = _host.IsVirtualCameraOn ? "Stop virtual camera" : "Start virtual camera";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(VcamButton, VcamText.Text);
        VcamWide.IsChecked = _host.Settings.VirtualCameraCanvas == 0;
        VcamTall.IsChecked = _host.Settings.VirtualCameraCanvas == 1;
        WideLabel.Text = "16:9 · YouTube, Twitch, Kick";
        _rows[2].Visibility = running && Native.oc_audio_present(Native.ChCapture) != 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var r in _rows) r.Load();
        AddAppButton.Visibility = running && EngineHost.AppAudioSupported ? Visibility.Visible : Visibility.Collapsed;
        _rows[0].SetSceneMuted(_host.ActiveScene.MuteMic);
        UpdateDestinationsLink();
        UpdateOverlay();
    }

    private void UpdateDestinationsLink()
    {
        var all = _host.Settings.Destinations;
        int on = all.Count(d => d.Enabled);
        if (all.Count == 0)
        {
            DestinationsLink.Content = "Add where to stream ›";
            return;
        }
        if (_host.IsLive)
        {
            int live = all.Count(d => _host.StatusOf(d.Id).State == Native.OutputState.Live);
            DestinationsLink.Content = $"Live on {live} of {on} ›";
        }
        else
        {
            DestinationsLink.Content = $"{on} of {all.Count} destinations on ›";
        }
    }

    private void UpdateStats()
    {
        Native.oc_get_stats(out var st);
        uint skipped = st.SkippedWide + st.SkippedTall - _skippedAtStart;
        uint lagged = st.LaggedFrames - _laggedAtStart;
        string res = $"{_host.Settings.VideoHeight}p{_host.Settings.Fps}";
        StatsText.Text = $"{res} · {_host.EncoderName} · {st.Fps:0} fps · {lagged + skipped} frames dropped · CPU {st.CpuPercent:0}%";
        _rows[2].Visibility = Native.oc_audio_present(Native.ChCapture) != 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowError(string? error)
    {
        ActionError.Text = error ?? "";
        ActionError.Visibility = string.IsNullOrEmpty(error) ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Live_Click(object sender, RoutedEventArgs e)
    {
        if (_host.IsLive) { _host.EndStream(); ShowError(null); }
        else ShowError(_host.GoLive());
    }

    private void Record_Click(object sender, RoutedEventArgs e)
    {
        if (_host.IsRecording) { _host.StopRecording(); ShowError(null); }
        else ShowError(_host.StartRecording());
    }

    private async void Vcam_Click(SplitButton sender, SplitButtonClickEventArgs e)
    {
        if (_host.IsVirtualCameraOn) { _host.StopVirtualCamera(); ShowError(null); RefreshUi(); return; }
        if (!EngineHost.VirtualCameraInstalled)
        {
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "Set up the virtual camera?",
                Content = "Windows needs to register OmniCast's virtual camera once. You'll be asked for permission. " +
                          "Apps will list it as \"OBS Virtual Camera\" (it's the camera OBS uses on Windows).",
                PrimaryButtonText = "Set up",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            if (!await EngineHost.InstallVirtualCameraAsync())
            {
                ShowError("The virtual camera wasn't set up. Windows needs admin permission for it.");
                return;
            }
        }
        ShowError(_host.StartVirtualCamera());
        RefreshUi();
    }

    private void VcamCanvas_Click(object sender, RoutedEventArgs e)
    {
        _host.SetVirtualCameraCanvas(ReferenceEquals(sender, VcamTall) ? 1 : 0);
        RefreshUi();
    }

    // ---------------------------------------------------------------- mixer

    private void RebuildAudioRows()
    {
        _rows.Clear();
        AudioRows.Children.Clear();
        var fx = new MenuFlyout { Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight };
        fx.Opening += (_, _) => BuildFxMenu(fx);
        _rows.Add(new AudioRow(Native.ChMic, "Mic", "\uE720", fx: fx));
        _rows.Add(new AudioRow(Native.ChDesktop, "Desktop audio", "\uE7F5"));
        _rows.Add(new AudioRow(Native.ChCapture, "Capture card", "\uE7F4"));
        foreach (var (ch, app) in _host.AppChannels.OrderBy(a => a.Key))
            _rows.Add(new AudioRow(ch, app.Name, "\uE8FC", app.Path, () => _host.RemoveApp(ch)));
        foreach (var r in _rows)
        {
            AudioRows.Children.Add(r);
            r.Load();
        }
        _rows[0].SetSceneMuted(_host.ActiveScene.MuteMic);
        _rows[2].Visibility = _host.IsRunning && Native.oc_audio_present(Native.ChCapture) != 0 ? Visibility.Visible : Visibility.Collapsed;
        AddAppButton.Visibility = _host.IsRunning && EngineHost.AppAudioSupported ? Visibility.Visible : Visibility.Collapsed;
    }

    // The mic's plugins: each with its editor, an on/off switch and remove; then "Add a plugin".
    private void BuildFxMenu(MenuFlyout menu)
    {
        menu.Items.Clear();
        var plugins = _host.Settings.MicPlugins;
        for (int i = 0; i < plugins.Count; i++)
        {
            int slot = i;
            var p = plugins[i];
            var sub = new MenuFlyoutSubItem { Text = _host.MicPluginFailed(i) ? $"{p.Name} (didn't load)" : p.Name };
            var open = new MenuFlyoutItem { Text = "Open editor", IsEnabled = !_host.MicPluginFailed(i) };
            open.Click += (_, _) => Native.oc_mic_plugin_open_editor(slot);
            var on = new ToggleMenuFlyoutItem { Text = "On", IsChecked = p.Enabled };
            on.Click += (_, _) => _host.SetMicPluginEnabled(slot, on.IsChecked);
            var remove = new MenuFlyoutItem { Text = "Remove" };
            remove.Click += (_, _) => _host.RemoveMicPlugin(slot);
            sub.Items.Add(open);
            sub.Items.Add(on);
            sub.Items.Add(new MenuFlyoutSeparator());
            sub.Items.Add(remove);
            menu.Items.Add(sub);
        }
        if (plugins.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
        var add = new MenuFlyoutSubItem { Text = "Add a plugin", IsEnabled = plugins.Count < EngineHost.MaxMicPlugins && _host.IsRunning };
        var installed = _host.InstalledPlugins();
        // STACKS and Muze first: they're what OmniCast is set up for.
        foreach (var name in new[] { "STACKS", "Muze" })
            if (installed.FirstOrDefault(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) is DeviceItem star)
                add.Items.Add(PluginItem(star));
        if (add.Items.Count > 0) add.Items.Add(new MenuFlyoutSeparator());
        foreach (var p in installed.Where(p => p.Name is not ("STACKS" or "Muze")))
            add.Items.Add(PluginItem(p));
        if (installed.Count == 0) add.Items.Add(new MenuFlyoutItem { Text = "No VST3 plugins installed", IsEnabled = false });
        menu.Items.Add(add);
    }

    private MenuFlyoutItem PluginItem(DeviceItem p)
    {
        var item = new MenuFlyoutItem { Text = p.Name };
        item.Click += (_, _) => ShowError(_host.AddMicPlugin(p));
        return item;
    }

    private async void StreamInfo_Click(object sender, RoutedEventArgs e)
    {
        try { await new StreamInfoDialog(XamlRoot).ShowAsync(); }
        catch (Exception ex)
        {
            ShowError($"Stream info: {ex.Message}");
            System.IO.File.WriteAllText(System.IO.Path.Combine(AppSettings.DataDir, "streaminfo-error.txt"), ex.ToString());
        }
    }

    private void AddAppMenu_Opening(object? sender, object e)
    {
        AddAppMenu.Items.Clear();
        var apps = _host.RunningApps();
        if (apps.Count == 0)
        {
            AddAppMenu.Items.Add(new MenuFlyoutItem { Text = "No other apps running", IsEnabled = false });
            return;
        }
        foreach (var app in apps)
        {
            var item = new MenuFlyoutItem { Text = app.Name };
            ToolTipService.SetToolTip(item, app.Exe);
            item.Click += (_, _) =>
            {
                if (_host.AddApp(app) < 0)
                    ShowError("There's no room for another app channel (13 at most).");
            };
            AddAppMenu.Items.Add(item);
        }
    }

    private void MonitorMenu_Opening(object? sender, object e)
    {
        MonitorMenu.Items.Clear();
        MonitorMenu.Items.Add(new MenuFlyoutItem { Text = "Monitor output", IsEnabled = false });
        var devices = new List<DeviceItem> { new("", "Windows default output") };
        devices.AddRange(_host.List("audio_outputs").Where(d => d.Id != "default"));
        foreach (var d in devices)
        {
            var item = new RadioMenuFlyoutItem { Text = d.Name, GroupName = "monitor", IsChecked = d.Id == _host.Settings.MonitorDevice };
            item.Click += (_, _) => _host.SetMonitorDevice(d.Id);
            MonitorMenu.Items.Add(item);
        }
    }

    private void Destinations_Click(object sender, RoutedEventArgs e)
    {
        if (App.Current?.Window?.Content is FrameworkElement root && root.FindName("Nav") is NavigationView nav)
            nav.SelectedItem = nav.MenuItems.OfType<NavigationViewItem>().First(i => (string)i.Tag == "destinations");
    }

    // ---------------------------------------------------------------- scenes bar

    private void RebuildSceneButtons()
    {
        SceneButtons.Children.Clear();
        _rows[0].SetSceneMuted(_host.ActiveScene.MuteMic);
        var scenes = _host.Scenes;
        for (int i = 0; i < scenes.Count; i++)
        {
            var scene = scenes[i];
            bool onAir = scene.Id == _host.ActiveScene.Id;
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            content.Children.Add(new TextBlock { Text = scene.Name, MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis });
            if (scene.MuteMic)
                content.Children.Add(new FontIcon { Glyph = "\uE74F", FontSize = 11, Opacity = 0.7 }); // muted-mic badge
            var button = new ToggleButton { IsChecked = onAir, MinWidth = 96, Content = content };
            string hotkey = i < 9 ? $" ({"Ctrl+Alt+" + (i + 1)})" : "";
            ToolTipService.SetToolTip(button, $"{scene.Name}{hotkey}. Right-click for options.");
            AutomationProperties.SetName(button, onAir ? $"{scene.Name}, on air" : scene.Name);
            // Clicking a scene puts it on air; the bar is redrawn, so the
            // button's own toggling never sticks.
            button.Click += (_, _) => { _host.SwitchScene(scene.Id); RebuildSceneButtons(); };
            button.ContextFlyout = SceneMenu(scene, i);
            SceneButtons.Children.Add(button);
        }
    }

    private MenuFlyout SceneMenu(SceneInfo scene, int index)
    {
        var menu = new MenuFlyout();
        MenuFlyoutItem Item(string text, string glyph, Action action, bool enabled = true)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph }, IsEnabled = enabled };
            item.Click += (_, _) => action();
            return item;
        }
        bool onAir = scene.Id == _host.ActiveScene.Id;
        menu.Items.Add(Item("Cut to this scene", "\uE7C9", () => { _host.SwitchScene(scene.Id, cut: true); RebuildSceneButtons(); }, !onAir));
        menu.Items.Add(Item("Rename…", "\uE8AC", async () => await RenameScene(scene)));
        menu.Items.Add(Item("Duplicate", "\uE8C8", () => _host.AddScene(scene)));
        var mute = new ToggleMenuFlyoutItem { Text = "Mute mic in this scene", IsChecked = scene.MuteMic, Icon = new FontIcon { Glyph = "\uE720" } };
        mute.Click += (_, _) => { scene.MuteMic = mute.IsChecked; _host.UpdateScene(scene); RebuildSceneButtons(); };
        menu.Items.Add(mute);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Move left", "\uE72B", () => _host.MoveScene(scene, -1), index > 0));
        menu.Items.Add(Item("Move right", "\uE72A", () => _host.MoveScene(scene, +1), index < _host.Scenes.Count - 1));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item(onAir ? "Delete (switch away first)" : "Delete", "\uE74D", () => _host.RemoveScene(scene),
            !onAir && _host.Scenes.Count > 1));
        return menu;
    }

    private async System.Threading.Tasks.Task RenameScene(SceneInfo scene)
    {
        var box = new TextBox { Text = scene.Name };
        box.Loaded += (_, _) => { box.SelectAll(); box.Focus(FocusState.Programmatic); };
        var dialog = new ContentDialog
        {
            Title = "Rename scene",
            Content = box,
            PrimaryButtonText = "Rename",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            _host.RenameScene(scene, box.Text);
    }

    private void AddScene_Click(object sender, RoutedEventArgs e)
    {
        var scene = _host.AddScene();
        _host.SwitchScene(scene.Id);
    }

    private void LoadTransition()
    {
        _updating = true;
        TransitionBox.SelectedIndex = (int)_host.Settings.Transition;
        TransitionMsBox.Value = _host.Settings.TransitionMs;
        TransitionMsBox.IsEnabled = _host.Settings.Transition != TransitionKind.Cut;
        _updating = false;
    }

    private void Transition_Changed(object sender, object e)
    {
        if (_updating || TransitionBox.SelectedIndex < 0) return;
        _host.Settings.Transition = (TransitionKind)TransitionBox.SelectedIndex;
        if (!double.IsNaN(TransitionMsBox.Value))
            _host.Settings.TransitionMs = (int)Math.Clamp(TransitionMsBox.Value, 50, 5000);
        TransitionMsBox.IsEnabled = _host.Settings.Transition != TransitionKind.Cut;
        _host.Settings.Save();
    }

    // ---------------------------------------------------------------- the scene on air

    private static readonly string[] ScreenLists = { "monitors", "windows", "games", "video_devices" };

    // Fills the editor with the on-air scene's preset.
    private void LoadSourceLists()
    {
        _updating = true;
        var scene = _host.ActiveScene;
        SceneHeader.Text = $"Scene: {scene.Name}";
        ScreenKindBox.SelectedIndex = (int)scene.ScreenKind;
        FillScreenItems(scene.ScreenId);

        var cams = new List<DeviceItem> { new("", "No camera") };
        cams.AddRange(_host.List("video_devices"));
        CameraItem.ItemsSource = cams;
        CameraItem.SelectedItem = cams.FirstOrDefault(c => c.Id == scene.CameraId) ?? cams[0];
        WideLayoutBox.SelectedIndex = (int)scene.WideLayout;
        CornerBox.SelectedIndex = (int)scene.CameraCorner;
        TallLayoutBox.SelectedIndex = (int)scene.TallLayout;
        UpdateLayoutEnabled();
        _updating = false;

        // Nothing chosen yet, or the saved window/device is gone: use what the
        // list fell back to (the main display first time), and remember it.
        bool changed = false;
        if (ScreenItem.SelectedItem is DeviceItem screen && screen.Id != scene.ScreenId)
        {
            scene.ScreenId = screen.Id;
            changed = true;
        }
        if (CameraItem.SelectedItem is DeviceItem cam && cam.Id != scene.CameraId)
        {
            scene.CameraId = cam.Id; // the saved camera was unplugged
            changed = true;
        }
        if (changed)
            _host.UpdateScene(scene);
        UpdateCaptureRow();
    }

    private void FillScreenItems(string selectId)
    {
        var items = _host.List(ScreenLists[Math.Max(0, ScreenKindBox.SelectedIndex)]);
        ScreenItem.ItemsSource = items;
        ScreenItem.SelectedItem = items.FirstOrDefault(i => i.Id == selectId) ?? items.FirstOrDefault();
    }

    private void ScreenKind_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updating || !_host.IsRunning) return;
        var scene = _host.ActiveScene;
        _updating = true;
        FillScreenItems(ScreenKindBox.SelectedIndex == (int)scene.ScreenKind ? scene.ScreenId : "");
        _updating = false;
        Scene_Changed(sender, e);
    }

    private void ScreenItem_SelectionChanged(object sender, SelectionChangedEventArgs e) => Scene_Changed(sender, e);

    // Any edit in the card: save it into the on-air scene and apply it live.
    private void Scene_Changed(object sender, object e)
    {
        if (_updating || !_host.IsRunning) return;
        var scene = _host.ActiveScene;
        if (ScreenItem.SelectedItem is DeviceItem item)
        {
            scene.ScreenKind = (ScreenKind)Math.Max(0, ScreenKindBox.SelectedIndex);
            scene.ScreenId = item.Id;
        }
        scene.CameraId = (CameraItem.SelectedItem as DeviceItem)?.Id ?? "";
        scene.WideLayout = (WideLayout)Math.Max(0, WideLayoutBox.SelectedIndex);
        scene.CameraCorner = (CameraCorner)Math.Max(0, CornerBox.SelectedIndex);
        scene.TallLayout = (TallLayout)Math.Max(0, TallLayoutBox.SelectedIndex);
        _host.UpdateScene(scene);
        UpdateLayoutEnabled();
        UpdateCaptureRow();
    }

    // Layouts with a camera need one; the corner only matters for screen + camera.
    private void UpdateLayoutEnabled()
    {
        bool hasCamera = CameraItem.SelectedItem is DeviceItem { Id.Length: > 0 };
        WideLayoutBox.IsEnabled = hasCamera;
        TallLayoutBox.IsEnabled = hasCamera;
        CornerBox.IsEnabled = hasCamera && WideLayoutBox.SelectedIndex == (int)WideLayout.ScreenAndCamera;
    }

    // A capture card brings its own sound channel.
    private void UpdateCaptureRow() =>
        _rows[2].Visibility = _host.IsRunning && Native.oc_audio_present(Native.ChCapture) != 0 ? Visibility.Visible : Visibility.Collapsed;

    private void Refresh_Click(object sender, RoutedEventArgs e)
    {
        if (_host.IsRunning) LoadSourceLists();
    }
}
