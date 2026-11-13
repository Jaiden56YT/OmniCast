using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OmniCast.Services;

public enum Platform { YouTube, Twitch, Kick, TikTok, Instagram, Custom }

// A place to stream to. The stream key isn't here: it's in Windows Credential
// Manager (see Credentials), under the destination's Id.
public sealed class DestinationInfo
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public Platform Platform { get; set; } = Platform.Custom;
    public string Name { get; set; } = "";
    public string Server { get; set; } = "";
    public int Canvas { get; set; } // 0 = 16:9, 1 = 9:16
    public bool Enabled { get; set; } = true;
}

public enum ScreenKind { Display, Window, Game, CaptureCard }
public enum WideLayout { ScreenAndCamera, ScreenOnly, CameraOnly }
public enum CameraCorner { BottomRight, BottomLeft, TopRight, TopLeft }
public enum TallLayout { Split, ScreenOnly, CameraOnly }
public enum TransitionKind { Cut, Fade, FadeToBlack, Slide, Swipe }

// A scene: a preset of what's on screen. Switching scenes switches all of it.
public sealed class SceneInfo
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "Scene";
    public ScreenKind ScreenKind { get; set; } = ScreenKind.Display;
    public string ScreenId { get; set; } = ""; // "" = the main display
    public string CameraId { get; set; } = ""; // "" = no camera
    public WideLayout WideLayout { get; set; } = WideLayout.ScreenAndCamera;
    public CameraCorner CameraCorner { get; set; } = CameraCorner.BottomRight;
    public TallLayout TallLayout { get; set; } = TallLayout.Split;
    // Mutes the mic while this scene is on air (e.g. "Be right back").
    public bool MuteMic { get; set; }

    public SceneInfo Copy(string name) => new()
    {
        Name = name,
        ScreenKind = ScreenKind,
        ScreenId = ScreenId,
        CameraId = CameraId,
        WideLayout = WideLayout,
        CameraCorner = CameraCorner,
        TallLayout = TallLayout,
        MuteMic = MuteMic,
    };
}

public sealed class ChannelInfo
{
    public double Volume { get; set; } = 1.0; // linear, 1 = unity
    public bool Muted { get; set; }
}

// Everything OmniCast remembers, in %LOCALAPPDATA%\OmniCast\settings.json.
// Nothing secret goes in here.
public sealed class AppSettings
{
    // Video. 720p is the default because it's what a low-end PC can always
    // do at 60 fps; 1080p is a switch away.
    public int VideoHeight { get; set; } = 720;
    public int Fps { get; set; } = 60;
    public int WideKbps { get; set; } = 6000;
    public int TallKbps { get; set; } = 6000;

    public List<DestinationInfo> Destinations { get; set; } = new();

    // Recording
    public string RecordFolder { get; set; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "OmniCast");
    public bool RecordWide { get; set; } = true;
    public bool RecordTall { get; set; }
    public bool SplitAudioTracks { get; set; } = true;
    public int RecordQuality { get; set; } = 20;

    // Scenes
    public List<SceneInfo> Scenes { get; set; } = new();
    public string ActiveSceneId { get; set; } = "";
    public TransitionKind Transition { get; set; } = TransitionKind.Fade;
    public int TransitionMs { get; set; } = 300;

    // Before scenes there was one screen and camera; read only to turn them
    // into the first scene (never written again).
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public int? ScreenKind { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? ScreenId { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public string? CameraId { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] public bool? CameraVisible { get; set; }

    // Audio devices
    public string MicDevice { get; set; } = "default";
    public string DesktopDevice { get; set; } = "default";
    // Virtual-cable device ids for the Discord outputs ("" = off).
    public string DiscordVoiceDevice { get; set; } = "";
    public string DiscordStreamAudioDevice { get; set; } = "";
    public ChannelInfo[] Channels { get; set; } = { new(), new(), new() };

    // App
    public bool LivePreview { get; set; } = true;
    public bool CloseToTray { get; set; } = true;
    public bool StartWithWindows { get; set; }

    private static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OmniCast");
    private static readonly string FilePath = Path.Combine(Dir, "settings.json");
    public static string DataDir => Dir;

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var s = JsonSerializer.Deserialize(File.ReadAllText(FilePath), SettingsJson.Default.AppSettings);
                if (s != null)
                {
                    s.Normalize();
                    return s;
                }
            }
        }
        catch (Exception)
        {
            // A damaged file shouldn't stop the app: start from defaults and
            // keep the old one for reference.
            try { File.Copy(FilePath, FilePath + ".bad", true); } catch { }
        }
        var fresh = new AppSettings();
        fresh.Normalize();
        return fresh;
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        string tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, SettingsJson.Default.AppSettings));
        File.Move(tmp, FilePath, true);
    }

    private void Normalize()
    {
        VideoHeight = VideoHeight >= 1080 ? 1080 : 720;
        Fps = Fps == 30 ? 30 : 60;
        WideKbps = Math.Clamp(WideKbps, 500, 51000);
        TallKbps = Math.Clamp(TallKbps, 500, 51000);
        RecordQuality = Math.Clamp(RecordQuality, 1, 51);
        if (Channels == null || Channels.Length < 3)
            Channels = new ChannelInfo[] { new(), new(), new() };
        Destinations ??= new();
        TransitionMs = Math.Clamp(TransitionMs, 50, 5000);
        Scenes ??= new();
        if (Scenes.Count == 0)
        {
            var first = new SceneInfo { Name = "Scene 1" };
            if (ScreenKind is int kind)
            {
                first.ScreenKind = (Services.ScreenKind)Math.Clamp(kind, 0, 3);
                first.ScreenId = ScreenId ?? "";
                first.CameraId = CameraVisible == false ? "" : CameraId ?? "";
            }
            Scenes.Add(first);
        }
        ScreenKind = null;
        ScreenId = null;
        CameraId = null;
        CameraVisible = null;
        if (Scenes.Find(s => s.Id == ActiveSceneId) == null)
            ActiveSceneId = Scenes[0].Id;
    }

    [JsonIgnore] public SceneInfo ActiveScene => Scenes.Find(s => s.Id == ActiveSceneId) ?? Scenes[0];
}

// Compile-time JSON for settings: no reflection, so the app can be trimmed.
[JsonSourceGenerationOptions(WriteIndented = true, UseStringEnumConverter = true)]
[JsonSerializable(typeof(AppSettings))]
internal sealed partial class SettingsJson : JsonSerializerContext
{
}
