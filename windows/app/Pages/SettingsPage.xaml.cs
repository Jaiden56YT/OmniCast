using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OmniCast.Engine;
using OmniCast.Services;
using Windows.Storage.Pickers;

namespace OmniCast.Pages;

public sealed partial class SettingsPage : Page
{
    private readonly EngineHost _host = EngineHost.Current;
    private bool _loading = true; // until Load(): controls fire change events while the page is built

    public SettingsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Load();
        _host.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(EngineHost.IsBusy) or nameof(EngineHost.IsRunning) or nameof(EngineHost.EncoderName))
                UpdateVideoState();
        };
    }

    private void Load()
    {
        _loading = true;
        var s = _host.Settings;
        ResolutionBox.SelectedIndex = s.VideoHeight >= 1080 ? 1 : 0;
        FpsBox.SelectedIndex = s.Fps == 30 ? 1 : 0;
        WideKbps.Value = s.WideKbps;
        TallKbps.Value = s.TallKbps;

        FolderText.Text = s.RecordFolder;
        RecWide.IsChecked = s.RecordWide;
        RecTall.IsChecked = s.RecordTall;
        SplitAudio.IsOn = s.SplitAudioTracks;
        QualitySlider.Value = s.RecordQuality;

        var mics = _host.List("audio_inputs");
        MicBox.ItemsSource = mics;
        MicBox.SelectedItem = mics.FirstOrDefault(m => m.Id == s.MicDevice) ?? mics.FirstOrDefault();
        var outs = _host.List("audio_outputs");
        DesktopBox.ItemsSource = outs;
        DesktopBox.SelectedItem = outs.FirstOrDefault(m => m.Id == s.DesktopDevice) ?? outs.FirstOrDefault();

        PreviewToggle.IsOn = s.LivePreview;
        TrayToggle.IsOn = s.CloseToTray;
        StartupToggle.IsOn = StartWithWindows.IsOn();
        var conflicts = App.Current?.Tray?.HotkeyConflicts;
        HotkeyConflicts.Text = conflicts is { Count: > 0 }
            ? $"Another app already uses {string.Join(", ", conflicts)}, so OmniCast can't."
            : "";
        HotkeyConflicts.Visibility = HotkeyConflicts.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        var v = Assembly.GetExecutingAssembly().GetName().Version;
        VersionText.Text = $"OmniCast for Windows {v?.Major}.{v?.Minor}.{v?.Build}";
        LoadDiscord();
        _loading = false;
        UpdateVideoState();
    }

    // ---------------------------------------------------------------- video

    private bool VideoDiffers()
    {
        var s = _host.Settings;
        int h = ResolutionBox.SelectedIndex == 1 ? 1080 : 720;
        int fps = FpsBox.SelectedIndex == 1 ? 30 : 60;
        return h != s.VideoHeight || fps != s.Fps || (int)WideKbps.Value != s.WideKbps || (int)TallKbps.Value != s.TallKbps;
    }

    private void UpdateVideoState()
    {
        bool gpu = _host.EncoderIsGpu;
        string enc = _host.EncoderName.Length > 0 ? _host.EncoderName : "starting…";
        string gpuName = _host.GpuName.Length > 0 ? $" on {_host.GpuName}" : "";
        EncoderText.Text = gpu
            ? $"{enc}{gpuName}. Frames never leave the GPU."
            : $"{enc}{gpuName}. This GPU has no video encoder, so encoding runs on the CPU.";
        ResolutionHint.Text = gpu
            ? "Both canvases use this size (9:16 is the same turned on its side). 1080p looks sharper."
            : ResolutionBox.SelectedIndex == 1
                ? "1080p on the CPU uses x264's lighter 'superfast' preset to keep both canvases at full frame rate."
                : "720p is the safe choice for CPU encoding. 1080p works too, with a lighter x264 preset.";
        QualityHint.Text = gpu
            ? "Constant quality, separate from the stream: lower numbers look better and make bigger files. 20 is a good default."
            : "On this PC recordings share the stream's encode (no extra CPU), so they use the stream bitrate.";
        QualitySlider.IsEnabled = gpu;
        ApplyVideo.IsEnabled = _host.IsRunning && !_host.IsBusy && !_host.IsStarting && VideoDiffers();
        ToolTipService.SetToolTip(ApplyVideo, _host.IsBusy ? "Stop streaming and recording first" : null);
    }

    private void Video_Changed(object sender, object e)
    {
        if (!_loading) UpdateVideoState();
    }

    private async void ApplyVideo_Click(object sender, RoutedEventArgs e)
    {
        var s = _host.Settings;
        s.VideoHeight = ResolutionBox.SelectedIndex == 1 ? 1080 : 720;
        s.Fps = FpsBox.SelectedIndex == 1 ? 30 : 60;
        s.WideKbps = double.IsNaN(WideKbps.Value) ? 6000 : (int)WideKbps.Value;
        s.TallKbps = double.IsNaN(TallKbps.Value) ? 6000 : (int)TallKbps.Value;
        ApplyVideo.IsEnabled = false;
        string? error = await _host.ApplyVideoAsync();
        VideoError.Message = error ?? "";
        VideoError.Title = "Couldn't apply the video settings";
        VideoError.IsOpen = error != null;
        UpdateVideoState();
    }

    // ---------------------------------------------------------------- recording

    private void Recording_Changed(object sender, object e)
    {
        if (_loading) return;
        var s = _host.Settings;
        s.RecordWide = RecWide.IsChecked == true;
        s.RecordTall = RecTall.IsChecked == true;
        s.SplitAudioTracks = SplitAudio.IsOn;
        s.RecordQuality = (int)QualitySlider.Value;
        s.Save();
    }

    private async void ChangeFolder_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.VideosLibrary };
        picker.FileTypeFilter.Add("*");
        // Unpackaged apps must tell the picker which window owns it.
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Current!.Window!));
        var folder = await picker.PickSingleFolderAsync();
        if (folder == null) return;
        _host.Settings.RecordFolder = folder.Path;
        _host.Settings.Save();
        FolderText.Text = folder.Path;
    }

    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(_host.Settings.RecordFolder);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_host.Settings.RecordFolder}\"") { UseShellExecute = true });
    }

    // ---------------------------------------------------------------- audio

    private void Audio_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || !_host.IsRunning) return;
        var s = _host.Settings;
        if (ReferenceEquals(sender, MicBox) && MicBox.SelectedItem is DeviceItem mic)
        {
            s.MicDevice = mic.Id;
            Native.oc_mic_set_device(mic.Id);
        }
        else if (ReferenceEquals(sender, DesktopBox) && DesktopBox.SelectedItem is DeviceItem output)
        {
            s.DesktopDevice = output.Id;
            Native.oc_desktop_set_device(output.Id);
        }
        s.Save();
    }

    // ---------------------------------------------------------------- app

    private void App_Changed(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        var s = _host.Settings;
        if (ReferenceEquals(sender, PreviewToggle))
        {
            s.LivePreview = PreviewToggle.IsOn;
            // The Studio page picks this up when it's shown again.
        }
        else if (ReferenceEquals(sender, TrayToggle))
        {
            s.CloseToTray = TrayToggle.IsOn;
        }
        else if (ReferenceEquals(sender, StartupToggle))
        {
            StartWithWindows.Set(StartupToggle.IsOn);
            s.StartWithWindows = StartupToggle.IsOn;
        }
        s.Save();
    }

    // ---------------------------------------------------------------- discord

    private const string VbCablePage = "https://vb-audio.com/Cable/";

    // Fills both pickers with the virtual cables on this PC (plus "Off"), or
    // shows how to get VB-CABLE when there are none.
    private void LoadDiscord()
    {
        bool was = _loading;
        _loading = true;
        var cables = _host.List("loopback_outputs");
        CableMissing.IsOpen = _host.IsRunning && cables.Count == 0;
        foreach (var (box, saved) in new[] { (VoiceBox, _host.Settings.DiscordVoiceDevice), (StreamAudioBox, _host.Settings.DiscordStreamAudioDevice) })
        {
            var items = new System.Collections.Generic.List<DeviceItem> { new("", "Off") };
            items.AddRange(cables);
            box.ItemsSource = items;
            box.SelectedItem = items.FirstOrDefault(i => i.Id == saved) ?? items[0];
            box.IsEnabled = cables.Count > 0;
        }
        _loading = was;
        UpdateDiscordStatus();
    }

    private void UpdateDiscordStatus()
    {
        static string Status(bool on, bool running) => !on ? "" : running ? "● Playing" : "Couldn't open this device";
        VoiceStatus.Text = Status(_host.Settings.DiscordVoiceDevice.Length > 0, _host.DiscordOutputRunning(Native.DiscordVoice));
        StreamAudioStatus.Text = Status(_host.Settings.DiscordStreamAudioDevice.Length > 0, _host.DiscordOutputRunning(Native.DiscordStreamAudio));
        VoiceStatus.Visibility = VoiceStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        StreamAudioStatus.Visibility = StreamAudioStatus.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Discord_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (_loading || !_host.IsRunning) return;
        int output = ReferenceEquals(sender, VoiceBox) ? Native.DiscordVoice : Native.DiscordStreamAudio;
        string id = ((sender as ComboBox)?.SelectedItem as DeviceItem)?.Id ?? "";
        _host.SetDiscordOutput(output, id);
        LoadDiscord(); // the other picker may have given up this cable
    }

    private void GetCable_Click(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(VbCablePage) { UseShellExecute = true });

    private void CheckCable_Click(object sender, RoutedEventArgs e) => LoadDiscord();

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(EngineHost.LogsDir);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{EngineHost.LogsDir}\"") { UseShellExecute = true });
    }
}
