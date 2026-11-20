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

public class ChannelInfo
{
    public double Volume { get; set; } = 1.0; // Stream level, linear, 1 = unity
    public bool Muted { get; set; }           // muted on stream and recordings
    public double Monitor { get; set; } = 1.0; // Monitor (headphones) level
    public bool MonitorMuted { get; set; }
}

// Merged chat overlay. Read-only: nothing is ever posted.
public sealed class ChatSettings
{
    public string YouTube { get; set; } = "";  // handle
    public string Twitch { get; set; } = "";   // channel
    public string Kick { get; set; } = "";     // channel
    public long? KickChatroom { get; set; }    // only when Kick blocks the channel lookup
    public List<string> Enabled { get; set; } = new() { "youtube", "twitch", "kick" };
    public bool Visible { get; set; } = true;
    public bool Vertical { get; set; }         // also on 9:16
    public string Size { get; set; } = "medium"; // small, medium, large
    public int HideAfter { get; set; }         // seconds; 0 = never
    public Box? WideBox { get; set; }          // null = default place
    public Box? TallBox { get; set; }
}

// A VST3 effect on the mic (STACKS, Muze, ...), in chain order.
public sealed class MicPlugin
{
    public string Path { get; set; } = "";
    public string Name { get; set; } = "";
    public bool Enabled { get; set; } = true;
    public string State { get; set; } = ""; // the plugin's own settings, base64
}

// Stream-info sign-ins: the Client IDs of the apps the user registered, and who
// signed in. Secrets and tokens are in Windows Credential Manager.
public sealed class AccountsSettings
{
    public Dictionary<string, string> ClientIds { get; set; } = new(); // by platform key
    public Dictionary<string, string> Logins { get; set; } = new();
    public string TwitchUserId { get; set; } = "";
}

public sealed class SavedCategory
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Image { get; set; } = "";
}

// The last title and games set from Stream info.
public sealed class StreamInfoSettings
{
    public string Title { get; set; } = "";
    public List<string> TitleOn { get; set; } = new() { "youtube", "twitch", "kick" };
    public SavedCategory? TwitchGame { get; set; }
    public SavedCategory? KickGame { get; set; }
}

// The music switch and the now-playing card.
public sealed class MusicSettings
{
    public string Source { get; set; } = "spotify"; // spotify, untitled (in a browser)
    public bool CardEnabled { get; set; } = true;
    public string Corner { get; set; } = "bottomLeft"; // topLeft, topRight, bottomLeft, bottomRight
    public bool Vertical { get; set; } = true;          // also on 9:16
}

// The Discord call overlay and your PNGtuber. The Client Secret and Discord's
// sign-in token are in Windows Credential Manager, not here.
public sealed class DiscordSettings
{
    public string ClientId { get; set; } = "";
    public bool AutoConnect { get; set; }
    public bool Visible { get; set; } = true;   // the call's people
    public bool DimQuiet { get; set; } = true;  // dim people who aren't talking
    public Dictionary<string, PersonLayout> Layouts { get; set; } = new(); // by Discord user id, and "me"
    public bool MeEnabled { get; set; } = true;
    public string MeIdle { get; set; } = "";    // your PNGtuber images
    public string MeTalk { get; set; } = "";
    public double MeThreshold { get; set; } = -40; // dBFS: High -50, Medium -40, Low -30
}

// Where a person is drawn on the 16:9 canvas (1920x1080 reference pixels):
// X, Y are the centre, Size the height.
public sealed class PersonLayout
{
    public double X { get; set; } = 960;
    public double Y { get; set; } = 140;
    public double Size { get; set; } = 220;
    public bool Flip { get; set; }
}

// A rectangle in canvas pixels (top-left origin).
public sealed class Box
{
    public double X { get; set; }
    public double Y { get; set; }
    public double W { get; set; }
    public double H { get; set; }
}

// An app with its own mixer channel, found by its exe ("spotify.exe").
public sealed class AppChannelInfo : ChannelInfo
{
    public string Exe { get; set; } = "";
    public string Name { get; set; } = "";
    public string Path { get; set; } = ""; // for its icon; may be gone
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

    // Which canvas the virtual camera shows: 0 = 16:9, 1 = 9:16.
    public int VirtualCameraCanvas { get; set; }
    public ChannelInfo[] Channels { get; set; } = { new(), new(), new() };
    public List<AppChannelInfo> AppChannels { get; set; } = new();
    public string MonitorDevice { get; set; } = ""; // "" = Windows' default output
    public bool AddedSpotify { get; set; }          // Spotify gets a channel once, automatically
    public int MixerVersion { get; set; }
    public ChatSettings Chat { get; set; } = new();
    public MusicSettings Music { get; set; } = new();
    public List<MicPlugin> MicPlugins { get; set; } = new();
    public AccountsSettings Accounts { get; set; } = new();
    public StreamInfoSettings StreamInfo { get; set; } = new();
    public DiscordSettings Discord { get; set; } = new();

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
        AppChannels ??= new();
        Chat ??= new();
        Music ??= new();
        MicPlugins ??= new();
        Accounts ??= new();
        Accounts.ClientIds ??= new();
        Accounts.Logins ??= new();
        StreamInfo ??= new();
        StreamInfo.TitleOn ??= new();
        Discord ??= new();
        Discord.Layouts ??= new();
        Chat.Enabled ??= new();
        if (MixerVersion < 1)
        {
            // You already hear your desktop through the speakers, and most people
            // don't want to hear themselves: both start off in the monitor mix.
            // The capture card starts on (the point is to hear the game).
            Channels[0].MonitorMuted = true;
            Channels[1].MonitorMuted = true;
            MixerVersion = 1;
        }
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
