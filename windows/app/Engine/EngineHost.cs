using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using OmniCast.Services;

namespace OmniCast.Engine;

public sealed record DeviceItem(string Id, string Name);
public sealed record AppItem(string Exe, string Name, string Path);

public sealed class DestinationStatus
{
    public Native.OutputState State { get; init; }
    public string Message { get; init; } = "";
}

// The app's one connection to OmniCore: starts it, applies settings, and turns
// its callbacks (which arrive on libobs threads) into UI-thread state.
public sealed class EngineHost : INotifyPropertyChanged
{
    public static EngineHost Current { get; } = new();

    public AppSettings Settings { get; } = AppSettings.Load();

    public event PropertyChangedEventHandler? PropertyChanged;
    // Raised after the engine (re)starts, so previews attach again.
    public event Action? EngineStarted;
    // Raised just before the engine stops or restarts, so previews detach.
    public event Action? EngineStopping;
    public event Action<string>? DestinationStatusChanged; // destination Id
    // Something worth a notification: title, body.
    public event Action<string, string>? Notify;

    private DispatcherQueue? _ui;
    private readonly Native.StatusCallback _statusCb;
    private readonly Native.RecordCallback _recordCb;
    private readonly Dictionary<string, DestinationStatus> _status = new();
    private List<string> _liveIds = new(); // destination Id per output index
    private readonly bool[] _recording = new bool[2];

    private EngineHost()
    {
        // Kept in fields so the GC never collects the delegates native code holds.
        _statusCb = OnStatus;
        _recordCb = OnRecord;
    }

    // ---------------------------------------------------------------- state

    private bool _running, _starting, _live, _recordingAny, _micMuted;
    private string _startError = "", _encoderName = "", _gpuName = "";
    private bool _encoderIsGpu;

    public bool IsRunning { get => _running; private set => Set(ref _running, value); }
    public bool IsStarting { get => _starting; private set => Set(ref _starting, value); }
    public bool IsLive { get => _live; private set { if (Set(ref _live, value)) UpdateBusy(); } }
    public bool IsRecording { get => _recordingAny; private set { if (Set(ref _recordingAny, value)) UpdateBusy(); } }
    public bool IsBusy => IsLive || IsRecording;
    public bool IsVirtualCameraOn { get => _vcamOn; private set => Set(ref _vcamOn, value); }
    private bool _vcamOn;
    public bool IsMicMuted { get => _micMuted; private set => Set(ref _micMuted, value); }
    public string StartError { get => _startError; private set => Set(ref _startError, value); }
    public string EncoderName { get => _encoderName; private set => Set(ref _encoderName, value); }
    public string GpuName { get => _gpuName; private set => Set(ref _gpuName, value); }
    public bool EncoderIsGpu { get => _encoderIsGpu; private set => Set(ref _encoderIsGpu, value); }

    public DestinationStatus StatusOf(string id) =>
        _status.TryGetValue(id, out var s) ? s : new DestinationStatus { State = Native.OutputState.Idle };

    public static string AppDir => AppContext.BaseDirectory.TrimEnd('\\');
    public static string ObsConfigDir => Path.Combine(AppSettings.DataDir, "obs");
    public static string LogsDir => Path.Combine(ObsConfigDir, "logs");

    // ---------------------------------------------------------------- start / stop

    public async Task<bool> StartAsync()
    {
        _ui ??= DispatcherQueue.GetForCurrentThread();
        if (IsRunning || IsStarting)
            return IsRunning;
        IsStarting = true;
        StartError = "";
        var video = VideoConfig();
        var err = new byte[512];
        Directory.CreateDirectory(ObsConfigDir);
        // libobs takes a second or two to load its plugins; keep the UI responsive.
        int ok = await Task.Run(() => Native.oc_start(AppDir, ObsConfigDir + "\\", ref video, err, err.Length));
        IsStarting = false;
        if (ok == 0)
        {
            StartError = Native.Err(err);
            return false;
        }
        AfterStart();
        return true;
    }

    private void AfterStart()
    {
        Native.oc_set_status_callback(_statusCb);
        Native.oc_set_record_callback(_recordCb);
        EncoderName = Native.Str(Native.oc_encoder_name());
        EncoderIsGpu = Native.oc_encoder_is_gpu() != 0;
        GpuName = Native.Str(Native.oc_gpu_name());
        ApplySources();
        IsRunning = true;
        // The camera stays on across a video settings change.
        if (IsVirtualCameraOn && StartVirtualCamera() != null)
            IsVirtualCameraOn = false;
        EngineStarted?.Invoke();
    }

    public void Shutdown()
    {
        if (!IsRunning)
            return;
        EngineStopping?.Invoke();
        Native.oc_set_status_callback(null);
        Native.oc_set_record_callback(null);
        SaveMicPluginStates();
        Native.oc_shutdown();
        _apps.Clear();
        IsRunning = false;
        IsVirtualCameraOn = false;
        IsLive = false;
        IsRecording = false;
        Native.oc_set_busy(0);
    }

    // Resolution, frame rate and bitrates. Restarts the engine; returns an error or null.
    public async Task<string?> ApplyVideoAsync()
    {
        if (IsBusy)
            return "Stop streaming and recording first.";
        Settings.Save();
        if (!IsRunning)
            return await StartAsync() ? null : StartError;
        EngineStopping?.Invoke();
        IsRunning = false;
        var video = VideoConfig();
        var err = new byte[512];
        IsStarting = true;
        SaveMicPluginStates();
        int ok = await Task.Run(() => Native.oc_reset_video(ref video, err, err.Length));
        IsStarting = false;
        if (ok == 0)
        {
            StartError = Native.Err(err);
            return StartError;
        }
        AfterStart();
        return null;
    }

    private Native.VideoConfig VideoConfig() => new()
    {
        Height = Settings.VideoHeight,
        Fps = Settings.Fps,
        WideKbps = Settings.WideKbps,
        TallKbps = Settings.TallKbps,
    };

    // ---------------------------------------------------------------- sources and scenes

    // Raised when scenes are added, removed, renamed or reordered, or another one goes on air.
    public event Action? ScenesChanged;

    public IReadOnlyList<SceneInfo> Scenes => Settings.Scenes;
    public SceneInfo ActiveScene => Settings.ActiveScene;

    public void ApplySources()
    {
        var s = Settings;
        Native.oc_mic_set_device(s.MicDevice);
        Native.oc_desktop_set_device(s.DesktopDevice);
        foreach (var scene in s.Scenes)
            PushScene(scene);
        Native.oc_scene_activate(ActiveScene.Id, (int)TransitionKind.Cut, 0);
        for (int ch = 0; ch < 3; ch++)
            ApplyChannel(ch);
        ApplyMixer();
        ApplyMicPlugins();
        ApplyCameraBoxes();
        // Saved Discord outputs; a cable that's gone (uninstalled) just stays off.
        Native.oc_discord_output_set(Native.DiscordVoice, s.DiscordVoiceDevice);
        Native.oc_discord_output_set(Native.DiscordStreamAudio, s.DiscordStreamAudioDevice);
    }

    // Plays a mix into a virtual cable ("" = off). Returns whether it's playing.
    // One cable can't carry both: giving it to one output takes it from the other.
    public bool SetDiscordOutput(int output, string deviceId)
    {
        if (output == Native.DiscordVoice)
        {
            Settings.DiscordVoiceDevice = deviceId;
            if (deviceId.Length > 0 && Settings.DiscordStreamAudioDevice == deviceId)
                Settings.DiscordStreamAudioDevice = "";
        }
        else
        {
            Settings.DiscordStreamAudioDevice = deviceId;
            if (deviceId.Length > 0 && Settings.DiscordVoiceDevice == deviceId)
                Settings.DiscordVoiceDevice = "";
        }
        Settings.Save();
        if (output == Native.DiscordStreamAudio && deviceId.Length > 0 && IsRunning)
            AddDiscordIfRunning();
        return IsRunning && Native.oc_discord_output_set(output, deviceId) != 0;
    }

    // ---------------------------------------------------------------- virtual camera

    public static bool VirtualCameraInstalled => Native.oc_vcam_installed() != 0;

    // Shows the UAC prompt to register the camera; true when it's ready.
    public static Task<bool> InstallVirtualCameraAsync() => Task.Run(() => Native.oc_vcam_install() != 0);

    // Starts (or moves) the camera onto the chosen canvas; returns an error or null.
    public string? StartVirtualCamera()
    {
        var err = new byte[256];
        if (Native.oc_vcam_start(Settings.VirtualCameraCanvas, err, err.Length) == 0)
            return Native.Err(err);
        IsVirtualCameraOn = true;
        return null;
    }

    public void StopVirtualCamera()
    {
        Native.oc_vcam_stop();
        IsVirtualCameraOn = false;
    }

    public void SetVirtualCameraCanvas(int canvas)
    {
        Settings.VirtualCameraCanvas = canvas;
        Settings.Save();
        if (IsVirtualCameraOn && StartVirtualCamera() != null)
            IsVirtualCameraOn = false;
    }

    public bool DiscordOutputRunning(int output) => IsRunning && Native.oc_discord_output_running(output) != 0;

    private static void PushScene(SceneInfo s) =>
        Native.SceneSet(s.Id, (int)s.ScreenKind, s.ScreenId, s.CameraId, (int)s.WideLayout, (int)s.CameraCorner, (int)s.TallLayout);

    // ---------------------------------------------------------------- mixer

    // Raised when an app channel is added or removed.
    public event Action? MixerChanged;

    private readonly Dictionary<int, AppChannelInfo> _apps = new();
    public IReadOnlyDictionary<int, AppChannelInfo> AppChannels => _apps;
    public static bool AppAudioSupported => Native.oc_app_audio_supported() != 0;

    private static readonly string[] DiscordExes = { "discord.exe", "discordcanary.exe", "discordptb.exe", "vesktop.exe", "legcord.exe" };

    public ChannelInfo? Channel(int ch) =>
        ch >= 0 && ch < 3 ? Settings.Channels[ch] : _apps.TryGetValue(ch, out var a) ? a : null;

    private void ApplyMixer()
    {
        _apps.Clear();
        Native.oc_monitor_set_device(Settings.MonitorDevice);
        if (AppAudioSupported)
        {
            // Spotify gets a channel once, if it's installed; removing it sticks.
            if (!Settings.AddedSpotify)
            {
                string? spotify = SpotifyPath();
                if (spotify != null)
                {
                    Settings.AddedSpotify = true;
                    if (!Settings.AppChannels.Any(a => a.Exe == "spotify.exe"))
                        Settings.AppChannels.Add(new AppChannelInfo { Exe = "spotify.exe", Name = "Spotify", Path = spotify, MonitorMuted = true });
                    Settings.Save();
                }
            }
            foreach (var app in Settings.AppChannels)
            {
                int ch = Native.oc_app_channel_add(app.Exe);
                if (ch < 0) continue;
                _apps[ch] = app;
                ApplyChannel(ch);
            }
        }
        MixerChanged?.Invoke();
    }

    private static string? SpotifyPath()
    {
        string path = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Spotify", "Spotify.exe");
        if (File.Exists(path)) return path;
        // The Microsoft Store version.
        string apps = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WindowsApps", "Spotify.exe");
        return File.Exists(apps) ? apps : null;
    }

    // Running apps with a window, for the "+" menu (minus ones with a channel).
    public List<AppItem> RunningApps()
    {
        if (!IsRunning) return new();
        try
        {
            string json = Native.TakeString(Native.oc_list("audio_apps"));
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.EnumerateArray()
                .Select(e => new AppItem(e.GetProperty("id").GetString() ?? "", e.GetProperty("name").GetString() ?? "", e.GetProperty("path").GetString() ?? ""))
                .Where(a => !Settings.AppChannels.Any(c => c.Exe == a.Exe))
                .ToList();
        }
        catch (Exception)
        {
            return new();
        }
    }

    // Gives an app its own channel. Returns the channel, or -1 when there's no room.
    public int AddApp(AppItem app)
    {
        if (!IsRunning) return -1;
        int ch = Native.oc_app_channel_add(app.Exe);
        if (ch < 0) return -1;
        // Apps keep playing through your speakers, so the monitor mix starts without them.
        var info = new AppChannelInfo { Exe = app.Exe, Name = app.Name, Path = app.Path, MonitorMuted = true };
        Settings.AppChannels.Add(info);
        Settings.Save();
        _apps[ch] = info;
        ApplyChannel(ch);
        MixerChanged?.Invoke();
        return ch;
    }

    public void RemoveApp(int ch)
    {
        if (!_apps.TryGetValue(ch, out var info)) return;
        Native.oc_app_channel_remove(ch);
        _apps.Remove(ch);
        Settings.AppChannels.Remove(info);
        Settings.Save();
        MixerChanged?.Invoke();
    }

    public void SetMonitorDevice(string id)
    {
        Settings.MonitorDevice = id;
        Settings.Save();
        if (IsRunning) Native.oc_monitor_set_device(id);
    }

    // Discord's audio has to have its own channel when Go Live audio is on, or
    // it's inside desktop audio and the call hears itself.
    private void AddDiscordIfRunning()
    {
        if (!AppAudioSupported || Settings.AppChannels.Any(a => DiscordExes.Contains(a.Exe))) return;
        foreach (var exe in DiscordExes)
        {
            var p = System.Diagnostics.Process.GetProcessesByName(System.IO.Path.GetFileNameWithoutExtension(exe));
            if (p.Length == 0) continue;
            string path = "";
            try { path = p[0].MainModule?.FileName ?? ""; } catch (Exception) { }
            foreach (var proc in p) proc.Dispose();
            AddApp(new AppItem(exe, exe == "discord.exe" ? "Discord" : System.IO.Path.GetFileNameWithoutExtension(exe), path));
            return;
        }
    }

    // The music switch: which app's music is on stream. The other one is
    // muted on stream (if it has a channel); its monitor level is left alone.
    // [untitled] has no Windows app, so it means the browser's channel.
    private static readonly string[] BrowserExes = { "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe", "vivaldi.exe", "arc.exe" };

    public static bool IsBrowserExe(string exe) => BrowserExes.Contains(exe);

    public void SelectMusicApp(string source)
    {
        Settings.Music.Source = source;
        if (IsRunning && source == "spotify" && AppAudioSupported && !Settings.AppChannels.Any(a => a.Exe == "spotify.exe") && SpotifyPath() is string sp)
            AddApp(new AppItem("spotify.exe", "Spotify", sp));
        foreach (var (ch, app) in _apps)
        {
            bool spotify = app.Exe == "spotify.exe", browser = BrowserExes.Contains(app.Exe);
            if (!spotify && !browser) continue;
            app.Muted = source == "spotify" ? browser : spotify;
            ApplyChannel(ch);
        }
        Settings.Save();
        MixerChanged?.Invoke();
    }

    // ---------------------------------------------------------------- mic plugins

    public const int MaxMicPlugins = 4;
    public event Action? MicPluginsChanged;
    private readonly HashSet<int> _pluginFailed = new();

    public bool MicPluginFailed(int slot) => _pluginFailed.Contains(slot);

    private void ApplyMicPlugins()
    {
        _pluginFailed.Clear();
        for (int i = 0; i < MaxMicPlugins; i++)
        {
            var p = i < Settings.MicPlugins.Count ? Settings.MicPlugins[i] : null;
            if (p == null) { Native.oc_mic_plugin_set(i, "", null, 0); continue; }
            if (Native.oc_mic_plugin_set(i, p.Path, null, 0) == 0) { _pluginFailed.Add(i); continue; }
            if (p.State.Length > 0) Native.oc_mic_plugin_set_state(i, p.State);
            Native.oc_mic_plugin_bypass(i, p.Enabled ? 0 : 1);
        }
        MicPluginsChanged?.Invoke();
    }

    // Plugins keep their own settings; they're saved when OmniCast closes or restarts the engine.
    public void SaveMicPluginStates()
    {
        if (!IsRunning) return;
        for (int i = 0; i < Settings.MicPlugins.Count && i < MaxMicPlugins; i++)
        {
            if (_pluginFailed.Contains(i)) continue;
            string state = Native.TakeString(Native.oc_mic_plugin_get_state(i));
            if (state.Length > 0) Settings.MicPlugins[i].State = state;
        }
        Settings.Save();
    }

    public List<DeviceItem> InstalledPlugins() => List("vst3")
        .GroupBy(p => p.Name, StringComparer.OrdinalIgnoreCase).Select(g => g.First())
        .OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToList();

    public string? AddMicPlugin(DeviceItem plugin)
    {
        if (Settings.MicPlugins.Count >= MaxMicPlugins) return "The mic can have 4 plugins at most.";
        SaveMicPluginStates();
        int slot = Settings.MicPlugins.Count;
        var err = new byte[256];
        if (Native.oc_mic_plugin_set(slot, plugin.Id, err, err.Length) == 0)
            return $"{plugin.Name} didn't load: {Native.Err(err)}";
        Settings.MicPlugins.Add(new MicPlugin { Path = plugin.Id, Name = plugin.Name });
        Settings.Save();
        MicPluginsChanged?.Invoke();
        return null;
    }

    public void RemoveMicPlugin(int slot)
    {
        if (slot < 0 || slot >= Settings.MicPlugins.Count) return;
        SaveMicPluginStates();
        Settings.MicPlugins.RemoveAt(slot);
        Settings.Save();
        ApplyMicPlugins(); // later plugins move up a slot
    }

    public void SetMicPluginEnabled(int slot, bool on)
    {
        if (slot < 0 || slot >= Settings.MicPlugins.Count) return;
        Settings.MicPlugins[slot].Enabled = on;
        Settings.Save();
        Native.oc_mic_plugin_bypass(slot, on ? 0 : 1);
    }

    // The camera where the user arranged it (or the layout's place).
    public void ApplyCameraBoxes()
    {
        if (!IsRunning) return;
        double k = Settings.VideoHeight / 1080.0;
        for (int c = 0; c < 2; c++)
        {
            var b = c == 0 ? Settings.CameraWide : Settings.CameraTall;
            if (b == null) Native.oc_camera_box(c, 0, 0, 0, 0);
            else Native.oc_camera_box(c, (float)(b.X * k), (float)(b.Y * k), (float)(b.W * k), (float)(b.H * k));
        }
    }

    public bool HasDiscordChannel => Settings.AppChannels.Any(a => DiscordExes.Contains(a.Exe));

    public void ApplyChannel(int ch)
    {
        var c = Channel(ch);
        if (c == null) return;
        Native.oc_monitor_set(ch, (float)c.Monitor, c.MonitorMuted ? 1 : 0);
        bool muted = c.Muted;
        // A scene can mute the mic while it's on air ("Be right back").
        if (ch == Native.ChMic)
        {
            muted |= ActiveScene.MuteMic;
            IsMicMuted = c.Muted;
        }
        Native.oc_audio_set(ch, (float)c.Volume, muted ? 1 : 0);
    }

    public void ToggleMicMute()
    {
        var mic = Settings.Channels[Native.ChMic];
        mic.Muted = !mic.Muted;
        ApplyChannel(Native.ChMic);
        Settings.Save();
    }

    // Puts a scene on air with the chosen transition.
    public void SwitchScene(string id, bool cut = false)
    {
        var scene = Settings.Scenes.Find(s => s.Id == id);
        if (scene == null) return;
        bool changed = Settings.ActiveSceneId != id;
        Settings.ActiveSceneId = id;
        Settings.Save();
        if (IsRunning)
        {
            Native.oc_scene_activate(id, cut ? (int)TransitionKind.Cut : (int)Settings.Transition, Settings.TransitionMs);
            ApplyChannel(Native.ChMic);
        }
        if (changed)
            ScenesChanged?.Invoke();
    }

    public void SwitchSceneByNumber(int number)
    {
        if (number >= 1 && number <= Settings.Scenes.Count)
            SwitchScene(Settings.Scenes[number - 1].Id);
    }

    // Saves a scene's preset and applies it (live, if it's on air).
    public void UpdateScene(SceneInfo scene)
    {
        Settings.Save();
        if (!IsRunning) return;
        PushScene(scene);
        if (scene.Id == Settings.ActiveSceneId)
            ApplyChannel(Native.ChMic);
    }

    public SceneInfo AddScene(SceneInfo? copyOf = null)
    {
        string name = UniqueName(copyOf != null ? copyOf.Name + " copy" : $"Scene {Settings.Scenes.Count + 1}");
        var scene = copyOf?.Copy(name) ?? ActiveScene.Copy(name);
        if (copyOf == null)
        {
            // A new scene starts from the current one's sources, so it's
            // ready to tweak rather than empty.
            scene.MuteMic = false;
        }
        Settings.Scenes.Add(scene);
        Settings.Save();
        if (IsRunning) PushScene(scene);
        ScenesChanged?.Invoke();
        return scene;
    }

    public void RenameScene(SceneInfo scene, string name)
    {
        name = name.Trim();
        if (name.Length == 0) return;
        scene.Name = name;
        Settings.Save();
        ScenesChanged?.Invoke();
    }

    // The scene on air can't be removed, and there's always at least one.
    public bool RemoveScene(SceneInfo scene)
    {
        if (Settings.Scenes.Count <= 1 || scene.Id == Settings.ActiveSceneId) return false;
        if (IsRunning && Native.oc_scene_remove(scene.Id) == 0) return false;
        Settings.Scenes.Remove(scene);
        Settings.Save();
        ScenesChanged?.Invoke();
        return true;
    }

    public void MoveScene(SceneInfo scene, int delta)
    {
        int i = Settings.Scenes.IndexOf(scene), j = i + delta;
        if (i < 0 || j < 0 || j >= Settings.Scenes.Count) return;
        Settings.Scenes.RemoveAt(i);
        Settings.Scenes.Insert(j, scene);
        Settings.Save();
        ScenesChanged?.Invoke();
    }

    private string UniqueName(string name)
    {
        string candidate = name;
        for (int n = 2; Settings.Scenes.Exists(s => s.Name.Equals(candidate, StringComparison.OrdinalIgnoreCase)); n++)
            candidate = $"{name} {n}";
        return candidate;
    }


    public List<DeviceItem> List(string what)
    {
        if (!IsRunning)
            return new();
        try
        {
            string json = Native.TakeString(Native.oc_list(what));
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.EnumerateArray()
                .Select(e => new DeviceItem(e.GetProperty("id").GetString() ?? "", e.GetProperty("name").GetString() ?? ""))
                .ToList();
        }
        catch (Exception)
        {
            return new();
        }
    }

    // ---------------------------------------------------------------- streaming

    // Returns an error to show, or null.
    public string? GoLive()
    {
        if (!IsRunning) return "The engine isn't running.";
        if (IsLive) return null;
        var dests = Settings.Destinations.Where(d => d.Enabled).ToList();
        if (dests.Count == 0)
            return "Turn on at least one destination first (Destinations).";

        var missing = new List<string>();
        var native = new Native.Destination[dests.Count];
        try
        {
            for (int i = 0; i < dests.Count; i++)
            {
                string? key = Credentials.Read(Credentials.StreamKeyName(dests[i].Id));
                if (string.IsNullOrEmpty(key) || string.IsNullOrWhiteSpace(dests[i].Server))
                    missing.Add(dests[i].Name);
                native[i] = new Native.Destination
                {
                    Name = Marshal.StringToCoTaskMemUTF8(dests[i].Name),
                    Server = Marshal.StringToCoTaskMemUTF8(dests[i].Server.Trim()),
                    Key = Marshal.StringToCoTaskMemUTF8(key ?? ""),
                    Canvas = dests[i].Canvas,
                };
            }
            if (missing.Count > 0)
                return $"Add a server and stream key for: {string.Join(", ", missing)}.";

            _liveIds = dests.Select(d => d.Id).ToList();
            foreach (var id in _liveIds)
                SetStatus(id, Native.OutputState.Connecting, "");
            var err = new byte[512];
            if (Native.oc_stream_start(native, native.Length, err, err.Length) == 0)
            {
                foreach (var id in _liveIds)
                    if (StatusOf(id).State == Native.OutputState.Connecting)
                        SetStatus(id, Native.OutputState.Idle, "");
                return Native.Err(err);
            }
            IsLive = true;
            return null;
        }
        finally
        {
            foreach (var d in native)
            {
                Marshal.FreeCoTaskMem(d.Name);
                Marshal.FreeCoTaskMem(d.Server);
                if (d.Key != IntPtr.Zero)
                {
                    // Wipe the key before freeing it.
                    int len = 0;
                    while (Marshal.ReadByte(d.Key, len) != 0) len++;
                    for (int j = 0; j < len; j++) Marshal.WriteByte(d.Key, j, 0);
                    Marshal.FreeCoTaskMem(d.Key);
                }
            }
        }
    }

    public void EndStream()
    {
        if (!IsLive) return;
        Native.oc_stream_stop();
    }

    private void OnStatus(int index, int state, IntPtr message)
    {
        string msg = Native.Str(message);
        _ui?.TryEnqueue(() =>
        {
            if (index < 0 || index >= _liveIds.Count) return;
            string id = _liveIds[index];
            var prev = StatusOf(id).State;
            var s = (Native.OutputState)state;
            SetStatus(id, s, msg);
            string name = Settings.Destinations.FirstOrDefault(d => d.Id == id)?.Name ?? "A destination";
            if (s == Native.OutputState.Reconnecting && prev != s)
                Notify?.Invoke($"{name} disconnected", "Reconnecting…");
            else if (s == Native.OutputState.Live && prev == Native.OutputState.Reconnecting)
                Notify?.Invoke($"{name} is back", "Reconnected.");
            else if (s == Native.OutputState.Failed)
                Notify?.Invoke($"{name} stopped", msg.Length > 0 ? msg : "The stream stopped.");
            IsLive = _liveIds.Any(i => StatusOf(i).State is Native.OutputState.Connecting or Native.OutputState.Live or Native.OutputState.Reconnecting);
        });
    }

    private void SetStatus(string id, Native.OutputState state, string message)
    {
        _status[id] = new DestinationStatus { State = state, Message = message };
        DestinationStatusChanged?.Invoke(id);
    }

    // ---------------------------------------------------------------- recording

    public string? StartRecording()
    {
        if (!IsRunning) return "The engine isn't running.";
        if (IsRecording) return null;
        var s = Settings;
        if (!s.RecordWide && !s.RecordTall)
            return "Choose 16:9, 9:16 or both under Settings > Recording.";
        IntPtr folder = Marshal.StringToCoTaskMemUTF8(s.RecordFolder);
        try
        {
            var cfg = new Native.RecordConfig
            {
                Folder = folder,
                Wide = s.RecordWide ? 1 : 0,
                Tall = s.RecordTall ? 1 : 0,
                SplitAudio = s.SplitAudioTracks ? 1 : 0,
                Quality = s.RecordQuality,
            };
            var err = new byte[512];
            if (Native.oc_record_start(ref cfg, err, err.Length) == 0)
                return Native.Err(err);
            IsRecording = true;
            return null;
        }
        finally
        {
            Marshal.FreeCoTaskMem(folder);
        }
    }

    public void StopRecording()
    {
        if (IsRecording)
            Native.oc_record_stop();
    }

    public string RecordingPath(int canvas) => Native.Str(Native.oc_record_path(canvas));

    private void OnRecord(int canvas, int active, IntPtr message)
    {
        string msg = Native.Str(message);
        _ui?.TryEnqueue(() =>
        {
            if (canvas is < 0 or > 1) return;
            _recording[canvas] = active != 0;
            if (active == 0 && msg.Length > 0)
                Notify?.Invoke("Recording stopped", msg);
            IsRecording = _recording[0] || _recording[1];
        });
    }

    // ---------------------------------------------------------------- helpers

    private void UpdateBusy()
    {
        // Keep the PC awake and the engine at Above Normal priority while live
        // or recording (per-thread, so it's always called from the UI thread).
        if (IsRunning)
            Native.oc_set_busy(IsBusy ? 1 : 0);
        OnPropertyChanged(nameof(IsBusy));
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged(string? name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
