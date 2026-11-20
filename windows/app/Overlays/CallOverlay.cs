using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.UI.Dispatching;
using OmniCast.Discord;
using OmniCast.Engine;
using OmniCast.Services;
using Windows.Foundation;
using Windows.UI;
using Colors = Microsoft.UI.Colors;

namespace OmniCast.Overlays;

// The Discord call's people (their avatars, a green ring when they talk) and
// your PNGtuber (idle and talking images, driven by your mic) on the 16:9
// canvas. Each person is two layers, idle and talking; talking swaps them
// (the talking one sits a little higher, a small bounce). Images are drawn
// once per person and change only when someone joins or their picture does.
public sealed class CallOverlay
{
    public static CallOverlay Current { get; } = new();

    public const string Me = "me";
    private sealed class Person
    {
        public string Id = "";
        public string Image = "";      // what was drawn (avatar URL or file paths), to skip redraws
        public double Aspect = 1;
        public bool Ready, Talking;
    }

    private readonly Dictionary<string, Person> _people = new();
    private DispatcherQueueTimer? _voice;
    private DateTime _lastLoud = DateTime.MinValue;
    private bool _meTalking;

    private static DiscordSettings S => EngineHost.Current.Settings.Discord;

    public bool MeTalking => _meTalking;
    public event Action? MeTalkingChanged;

    public void Start()
    {
        var dq = DispatcherQueue.GetForCurrentThread();
        _voice = dq.CreateTimer();
        _voice.Interval = TimeSpan.FromMilliseconds(1000.0 / 30);
        _voice.Tick += (_, _) => DetectVoice();
        _voice.Start();
        DiscordCall.Current.MembersChanged += Refresh;
        DiscordCall.Current.SpeakingChanged += (id, on) => SetTalking(id, on);
        EngineHost.Current.EngineStarted += () => { _people.Clear(); Refresh(); };
        Refresh();
    }

    // Your PNGtuber talks while the mic is above the threshold (with 0.2 s hang).
    private void DetectVoice()
    {
        var host = EngineHost.Current;
        if (!host.IsRunning || !_people.ContainsKey(Me)) return;
        bool muted = host.Settings.Channels[Native.ChMic].Muted || host.ActiveScene.MuteMic;
        if (!muted && Native.oc_audio_level(Native.ChMic) > S.MeThreshold)
            _lastLoud = DateTime.UtcNow;
        bool talking = (DateTime.UtcNow - _lastLoud).TotalSeconds < 0.2;
        if (talking == _meTalking) return;
        _meTalking = talking;
        SetTalking(Me, talking);
        MeTalkingChanged?.Invoke();
    }

    // Who's drawn: you (with images set), then the call minus yourself.
    public void Refresh()
    {
        if (!EngineHost.Current.IsRunning) return;
        var want = new List<(string Id, string Image)>();
        if (S.MeEnabled && S.MeIdle.Length > 0)
            want.Add((Me, S.MeIdle + "|" + S.MeTalk));
        if (S.Visible)
            foreach (var m in DiscordCall.Current.Members.Where(m => m.Id != DiscordCall.Current.SelfId))
                want.Add((m.Id, m.AvatarUrl + (S.DimQuiet ? "|dim" : "")));

        foreach (var gone in _people.Keys.Where(k => !want.Any(w => w.Id == k)).ToList())
        {
            Native.oc_layer_remove(gone + "-idle");
            Native.oc_layer_remove(gone + "-talk");
            _people.Remove(gone);
        }
        int others = want.Count(w => w.Id != Me), index = 0;
        foreach (var (id, image) in want)
        {
            if (!S.Layouts.ContainsKey(id))
            {
                // Next free slot along the top (you default to the bottom right).
                if (id == Me)
                    S.Layouts[id] = new PersonLayout { X = 1700, Y = 820, Size = 420 };
                else
                {
                    double slot = 1920.0 / Math.Max(others, 4), size = Math.Min(220, slot * 0.9);
                    S.Layouts[id] = new PersonLayout { X = slot * (index + 0.5), Y = size / 2 + 24, Size = size };
                }
                EngineHost.Current.Settings.Save();
            }
            if (id != Me) index++;
            if (!_people.TryGetValue(id, out var p))
                _people[id] = p = new Person { Id = id };
            if (p.Image != image)
            {
                p.Image = image;
                p.Ready = false;
                _ = DrawAsync(p, id == Me ? null : DiscordCall.Current.Members.FirstOrDefault(m => m.Id == id));
            }
            else if (p.Ready)
                Place(p);
        }
    }

    // The PNGtuber's files changed in place: draw them again.
    public void ForgetMe()
    {
        if (_people.TryGetValue(Me, out var p)) p.Image = "";
    }

    public void ArrangeRow()
    {
        var ids = _people.Keys.Where(k => k != Me).ToList();
        double slot = 1920.0 / Math.Max(ids.Count, 1), size = Math.Min(260, slot * 0.9);
        for (int i = 0; i < ids.Count; i++)
            S.Layouts[ids[i]] = new PersonLayout { X = slot * (i + 0.5), Y = size / 2 + 24, Size = size };
        EngineHost.Current.Settings.Save();
        foreach (var p in _people.Values.Where(p => p.Ready)) Place(p);
    }

    private async Task DrawAsync(Person p, CallMember? member)
    {
        string image = p.Image;
        CanvasRenderTarget? idle = null, talk = null;
        try
        {
            if (p.Id == Me)
            {
                var parts = image.Split('|');
                using var a = await CanvasBitmap.LoadAsync(OverlayCanvas.Device, parts[0]);
                using var b = parts[1].Length > 0 ? await CanvasBitmap.LoadAsync(OverlayCanvas.Device, parts[1]) : null;
                p.Aspect = a.Size.Width / Math.Max(1, a.Size.Height);
                idle = Copy(a);
                talk = Copy(b ?? a);
            }
            else
            {
                byte[] bytes = await OmniCast.Chat.ChatHub.Http.GetByteArrayAsync(image.Split('|')[0]);
                using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
                await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
                stream.Seek(0);
                using var avatar = await CanvasBitmap.LoadAsync(OverlayCanvas.Device, stream);
                p.Aspect = 1;
                idle = Avatar(avatar, talking: false);
                talk = Avatar(avatar, talking: true);
            }
            if (p.Image != image || !_people.ContainsKey(p.Id)) return; // changed or left meanwhile
            if (!await OverlayCanvas.PublishAsync(p.Id + "-idle", idle) || !await OverlayCanvas.PublishAsync(p.Id + "-talk", talk)) return;
            p.Ready = true;
            Place(p);
        }
        catch (Exception)
        {
            // Picture unavailable (offline, file gone): leave them out.
        }
        finally
        {
            idle?.Dispose();
            talk?.Dispose();
        }
    }

    private static CanvasRenderTarget Copy(CanvasBitmap b)
    {
        var t = new CanvasRenderTarget(OverlayCanvas.Device, (float)b.Size.Width, (float)b.Size.Height, 96);
        using var ds = t.CreateDrawingSession();
        ds.Clear(Colors.Transparent);
        ds.DrawImage(b);
        return t;
    }

    // 512x512: the avatar in a circle; dimmed when quiet (if that's on), a green ring when talking.
    private static CanvasRenderTarget Avatar(CanvasBitmap avatar, bool talking)
    {
        var t = new CanvasRenderTarget(OverlayCanvas.Device, 512, 512, 96);
        using var ds = t.CreateDrawingSession();
        ds.Clear(Colors.Transparent);
        var circle = new Rect(24, 24, 464, 464);
        using (var clip = CanvasGeometry.CreateEllipse(ds, 256, 256, 232, 232))
        using (ds.CreateLayer(talking || !S.DimQuiet ? 1f : 0.55f, clip))
            ds.DrawImage(avatar, circle, avatar.Bounds);
        if (talking)
            ds.DrawEllipse(256, 256, 246 - 9, 246 - 9, Color.FromArgb(255, 0x24, 0xA6, 0x59), 18);
        return t;
    }

    private void Place(Person p)
    {
        var l = S.Layouts.TryGetValue(p.Id, out var lay) ? lay : new PersonLayout();
        double k = OverlayCanvas.Scale;
        float h = (float)(l.Size * k), w = (float)(l.Size * p.Aspect * k);
        float x = (float)(l.X * k - w / 2), y = (float)(l.Y * k - h / 2), lift = (float)(l.Size * 0.06 * k);
        Native.oc_layer_place(p.Id + "-idle", 0, 1, x, y, w, h);
        Native.oc_layer_place(p.Id + "-talk", 0, 1, x, y - lift, w, h);
        Native.oc_layer_place(p.Id + "-idle", 1, 0, 0, 0, 1, 1);
        Native.oc_layer_place(p.Id + "-talk", 1, 0, 0, 0, 1, 1);
        Apply(p);
    }

    private void SetTalking(string id, bool on)
    {
        if (!_people.TryGetValue(id, out var p)) return;
        p.Talking = on;
        if (p.Ready) Apply(p);
    }

    private static void Apply(Person p)
    {
        Native.oc_layer_set_opacity(p.Id + "-idle", p.Talking ? 0 : 1);
        Native.oc_layer_set_opacity(p.Id + "-talk", p.Talking ? 1 : 0);
    }
}
