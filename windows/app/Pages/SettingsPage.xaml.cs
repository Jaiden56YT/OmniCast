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
        LoadChat();
        LoadMusic();
        LoadCall();
        LoadAccounts();
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
        if (StreamAudioStatus.Text.Length > 0 && EngineHost.AppAudioSupported && !_host.HasDiscordChannel)
            StreamAudioStatus.Text += " · Give Discord its own channel (+ in Studio › Audio), or the call will hear itself";
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

    // ---------------------------------------------------------------- chat

    private void LoadChat()
    {
        var c = _host.Settings.Chat;
        YouTubeName.Text = c.YouTube;
        TwitchName.Text = c.Twitch;
        KickName.Text = c.Kick;
        YouTubeOn.IsOn = c.Enabled.Contains("youtube");
        TwitchOn.IsOn = c.Enabled.Contains("twitch");
        KickOn.IsOn = c.Enabled.Contains("kick");
        KickRoom.Text = c.KickChatroom?.ToString() ?? "";
        ChatVisible.IsOn = c.Visible;
        ChatVertical.IsOn = c.Vertical;
        ChatSize.SelectedIndex = c.Size switch { "small" => 0, "large" => 2, _ => 1 };
        ChatHide.SelectedIndex = c.HideAfter switch { 30 => 1, 60 => 2, 120 => 3, _ => 0 };
        if (!_chatHooked)
        {
            _chatHooked = true;
            OmniCast.Chat.ChatHub.Current.StatusChanged += UpdateChatStatus;
        }
        UpdateChatStatus();
    }

    private bool _chatHooked;

    private void UpdateChatStatus()
    {
        var hub = OmniCast.Chat.ChatHub.Current;
        YouTubeStatus.Text = hub.StatusOf(OmniCast.Chat.ChatPlatform.YouTube).Text;
        TwitchStatus.Text = hub.StatusOf(OmniCast.Chat.ChatPlatform.Twitch).Text;
        KickStatus.Text = hub.StatusOf(OmniCast.Chat.ChatPlatform.Kick).Text;
        ChatSummary.Text = hub.Summary + " · Chat is read only: nothing is ever posted. YouTube connects once you go live. Instagram doesn't let apps read live chat.";
    }

    private void ChatSave_Click(object sender, RoutedEventArgs e)
    {
        var c = _host.Settings.Chat;
        c.YouTube = YouTubeName.Text.Trim();
        c.Twitch = TwitchName.Text.Trim();
        c.Kick = KickName.Text.Trim();
        c.KickChatroom = long.TryParse(KickRoom.Text.Trim(), out long room) ? room : null;
        c.Enabled = new();
        if (YouTubeOn.IsOn) c.Enabled.Add("youtube");
        if (TwitchOn.IsOn) c.Enabled.Add("twitch");
        if (KickOn.IsOn) c.Enabled.Add("kick");
        _host.Settings.Save();
        OmniCast.Chat.ChatHub.Current.Restart();
    }

    private void ChatLook_Changed(object sender, object e)
    {
        if (_loading) return;
        var c = _host.Settings.Chat;
        c.Visible = ChatVisible.IsOn;
        c.Vertical = ChatVertical.IsOn;
        c.Size = (ChatSize.SelectedItem as ComboBoxItem)?.Tag as string ?? "medium";
        c.HideAfter = int.TryParse((ChatHide.SelectedItem as ComboBoxItem)?.Tag as string, out int h) ? h : 0;
        _host.Settings.Save();
        OmniCast.Overlays.ChatOverlay.Current.Invalidate();
    }

    private void ChatTest_Click(object sender, RoutedEventArgs e) => OmniCast.Chat.ChatHub.Current.AddTestMessages();

    private void ChatClear_Click(object sender, RoutedEventArgs e) => OmniCast.Chat.ChatHub.Current.Clear();

    // ---------------------------------------------------------------- music

    private void LoadMusic()
    {
        var m = _host.Settings.Music;
        MusicSource.SelectedIndex = m.Source == "untitled" ? 1 : 0;
        CardOn.IsOn = m.CardEnabled;
        CardCorner.SelectedIndex = m.Corner switch { "topLeft" => 0, "topRight" => 1, "bottomRight" => 3, _ => 2 };
        CardVertical.IsOn = m.Vertical;
        FollowOn.IsOn = m.Follow;
        bool autoKey = _host.InstalledPlugins().Any(p => p.Name.Equals("Muze Auto Key", StringComparison.OrdinalIgnoreCase));
        FollowOn.IsEnabled = autoKey || !_host.IsRunning;
        if (!_followHooked)
        {
            _followHooked = true;
            OmniCast.Services.MusicSync.Current.Changed += UpdateFollowStatus;
        }
        UpdateFollowStatus();
        if (!_musicHooked)
        {
            _musicHooked = true;
            NowPlaying.Current.Changed += _ => UpdateMusicStatus();
        }
        UpdateMusicStatus();
    }

    private bool _musicHooked, _followHooked;

    private void UpdateFollowStatus()
    {
        var sync = OmniCast.Services.MusicSync.Current;
        bool installed = !_host.IsRunning || FollowOn.IsEnabled;
        FollowTitle.Text = $"Muze follows {(_host.Settings.Music.Source == "untitled" ? "[untitled]" : "Spotify")}'s key and tempo";
        FollowStatus.Text = installed ? sync.Status : "Needs Muze Auto Key installed";
        if (sync.Locked && Application.Current.Resources.TryGetValue("SystemFillColorSuccessBrush", out var good) && good is Microsoft.UI.Xaml.Media.Brush b)
            FollowStatus.Foreground = b;
        else
            FollowStatus.ClearValue(TextBlock.ForegroundProperty);
    }

    private void Follow_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        _host.Settings.Music.Follow = FollowOn.IsOn;
        _host.Settings.Save();
        OmniCast.Services.MusicSync.Current.Apply();
        UpdateFollowStatus();
    }

    private void UpdateMusicStatus()
    {
        var t = NowPlaying.Current.Track;
        MusicStatus.Text = t is { Playing: true } ? $"♪ {t.Title} · {t.Artist}" : "Nothing playing right now";
    }

    private void Music_Changed(object sender, object e)
    {
        if (_loading) return;
        var m = _host.Settings.Music;
        string source = (MusicSource.SelectedItem as ComboBoxItem)?.Tag as string ?? "spotify";
        m.CardEnabled = CardOn.IsOn;
        m.Corner = (CardCorner.SelectedItem as ComboBoxItem)?.Tag as string ?? "bottomLeft";
        m.Vertical = CardVertical.IsOn;
        if (ReferenceEquals(sender, MusicSource) && source != m.Source)
        {
            _host.SelectMusicApp(source);
            OmniCast.Overlays.NowPlayingCard.Current.SourceChanged();
            OmniCast.Services.MusicSync.Current.SongChanged();
            UpdateFollowStatus();
        }
        _host.Settings.Save();
        OmniCast.Overlays.NowPlayingCard.Current.SettingsChanged();
    }

    private void MusicPreview_Click(object sender, RoutedEventArgs e) => _ = OmniCast.Overlays.NowPlayingCard.Current.PreviewAsync();

    // ---------------------------------------------------------------- discord call

    private bool _callHooked;

    private void LoadCall()
    {
        var d = _host.Settings.Discord;
        CallClientId.Text = d.ClientId;
        CallSecret.PlaceholderText = OmniCast.Discord.DiscordCall.HasSecret ? "Client Secret (saved)" : "Client Secret";
        CallVisible.IsOn = d.Visible;
        CallDim.IsOn = d.DimQuiet;
        MeOn.IsOn = d.MeEnabled;
        MeSensitivity.SelectedIndex = d.MeThreshold <= -45 ? 0 : d.MeThreshold >= -35 ? 2 : 1;
        if (!_callHooked)
        {
            _callHooked = true;
            OmniCast.Discord.DiscordCall.Current.StatusChanged += UpdateCallStatus;
            OmniCast.Discord.DiscordCall.Current.MembersChanged += UpdateCallStatus;
            OmniCast.Overlays.CallOverlay.Current.MeTalkingChanged += UpdateCallStatus;
        }
        UpdateCallStatus();
    }

    private void UpdateCallStatus()
    {
        var call = OmniCast.Discord.DiscordCall.Current;
        CallStatus.Text = call.InCall ? $"{call.Members.Count} in {call.ChannelName}" : call.Status;
        CallConnect.Content = call.Connected ? "Disconnect" : "Connect";
        var d = _host.Settings.Discord;
        MeStatus.Text = d.MeIdle.Length == 0 ? "Pick idle and talking images. It talks when your mic does."
            : OmniCast.Overlays.CallOverlay.Current.MeTalking ? "● Talking" : "PNGtuber · talks with your mic";
    }

    private void CallConnect_Click(object sender, RoutedEventArgs e)
    {
        var call = OmniCast.Discord.DiscordCall.Current;
        if (call.Connected) { call.Disconnect(); return; }
        _host.Settings.Discord.ClientId = CallClientId.Text.Trim();
        OmniCast.Discord.DiscordCall.SetSecret(CallSecret.Password);
        CallSecret.Password = "";
        CallSecret.PlaceholderText = OmniCast.Discord.DiscordCall.HasSecret ? "Client Secret (saved)" : "Client Secret";
        _host.Settings.Save();
        call.Connect();
    }

    private void CallSignOut_Click(object sender, RoutedEventArgs e) => OmniCast.Discord.DiscordCall.Current.SignOut();

    private void CallArrange_Click(object sender, RoutedEventArgs e) => OmniCast.Overlays.CallOverlay.Current.ArrangeRow();

    private void Call_Changed(object sender, object e)
    {
        if (_loading) return;
        var d = _host.Settings.Discord;
        d.Visible = CallVisible.IsOn;
        d.DimQuiet = CallDim.IsOn;
        d.MeEnabled = MeOn.IsOn;
        d.MeThreshold = double.TryParse((MeSensitivity.SelectedItem as ComboBoxItem)?.Tag as string, out double t) ? t : -40;
        _host.Settings.Save();
        OmniCast.Overlays.CallOverlay.Current.Refresh();
        UpdateCallStatus();
    }

    private async void MeIdle_Click(object sender, RoutedEventArgs e) => await PickMeImage(talking: false);
    private async void MeTalk_Click(object sender, RoutedEventArgs e) => await PickMeImage(talking: true);

    // Copies the picked image into OmniCast's overlay folder, so moving the original doesn't break it.
    private async System.Threading.Tasks.Task PickMeImage(bool talking)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
        foreach (var ext in new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp" }) picker.FileTypeFilter.Add(ext);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Current!.Window!));
        var file = await picker.PickSingleFileAsync();
        if (file == null) return;
        string dir = OmniCast.Overlays.OverlayCanvas.Dir;
        Directory.CreateDirectory(dir);
        string dest = Path.Combine(dir, (talking ? "you-talking" : "you-idle") + Path.GetExtension(file.Path).ToLowerInvariant());
        File.Copy(file.Path, dest, true);
        var d = _host.Settings.Discord;
        if (talking) d.MeTalk = dest; else d.MeIdle = dest;
        _host.Settings.Save();
        OmniCast.Overlays.CallOverlay.Current.ForgetMe(); // same path as before: draw it again
        OmniCast.Overlays.CallOverlay.Current.Refresh();
        UpdateCallStatus();
    }

    // ---------------------------------------------------------------- accounts

    private bool _signingIn;

    private (TextBox Id, PasswordBox? Secret, TextBlock Status, Button Connect, Button SignOut) AccountControls(string key) => key switch
    {
        "twitch" => (AccTwitchId, null, AccTwitchStatus, AccTwitchConnect, AccTwitchSignOut),
        "kick" => (AccKickId, AccKickSecret, AccKickStatus, AccKickConnect, AccKickSignOut),
        _ => (AccYouTubeId, AccYouTubeSecret, AccYouTubeStatus, AccYouTubeConnect, AccYouTubeSignOut),
    };

    private static OmniCast.Accounts.StreamAccount Account(string key) =>
        OmniCast.Accounts.StreamAccounts.All.First(a => a.Key == key);

    private void LoadAccounts()
    {
        foreach (var a in OmniCast.Accounts.StreamAccounts.All)
        {
            var c = AccountControls(a.Key);
            c.Id.Text = a.ClientId;
            if (c.Secret != null) c.Secret.PlaceholderText = a.HasSecret ? "Client Secret (saved)" : "Client Secret";
            c.Status.Text = a.Connected ? $"Connected as {a.Login}" : "Not connected";
            c.Connect.Content = a.Connected ? "Reconnect" : "Connect";
            c.Connect.IsEnabled = !_signingIn;
            c.SignOut.Visibility = a.Connected ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private async void AccountConnect_Click(object sender, RoutedEventArgs e)
    {
        string key = (string)((Button)sender).Tag;
        var a = Account(key);
        var c = AccountControls(key);
        a.ClientId = c.Id.Text;
        if (c.Secret != null && c.Secret.Password.Length > 0)
        {
            a.SetSecret(c.Secret.Password);
            c.Secret.Password = "";
        }
        _signingIn = true;
        LoadAccounts();
        c.Status.Text = "Connecting…";
        try
        {
            await a.ConnectAsync(msg => DispatcherQueue.TryEnqueue(() => c.Status.Text = msg), default);
            _signingIn = false;
            LoadAccounts();
        }
        catch (Exception ex)
        {
            _signingIn = false;
            LoadAccounts();
            c.Status.Text = ex is OmniCast.Accounts.AccountException ? ex.Message : $"Couldn't connect: {ex.Message}";
        }
    }

    private void AccountSignOut_Click(object sender, RoutedEventArgs e)
    {
        Account((string)((Button)sender).Tag).SignOut();
        LoadAccounts();
    }

    private void OpenLogs_Click(object sender, RoutedEventArgs e)
    {
        Directory.CreateDirectory(EngineHost.LogsDir);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{EngineHost.LogsDir}\"") { UseShellExecute = true });
    }
}
