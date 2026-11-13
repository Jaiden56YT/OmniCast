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
        EngineStarted?.Invoke();
    }

    public void Shutdown()
    {
        if (!IsRunning)
            return;
        EngineStopping?.Invoke();
        Native.oc_set_status_callback(null);
        Native.oc_set_record_callback(null);
        Native.oc_shutdown();
        IsRunning = false;
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
    }

    private static void PushScene(SceneInfo s) =>
        Native.SceneSet(s.Id, (int)s.ScreenKind, s.ScreenId, s.CameraId, (int)s.WideLayout, (int)s.CameraCorner, (int)s.TallLayout);

    public void ApplyChannel(int ch)
    {
        var c = Settings.Channels[ch];
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
