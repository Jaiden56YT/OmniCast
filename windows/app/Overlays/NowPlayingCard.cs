using System;
using System.Numerics;
using System.Threading.Tasks;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI.Dispatching;
using OmniCast.Engine;
using OmniCast.Services;
using Windows.Foundation;
using Windows.UI;
using Colors = Microsoft.UI.Colors;

namespace OmniCast.Overlays;

// The now-playing card: when a song starts in the chosen music app it fades in
// (0.5 s) in a corner, stays 30 s, and fades out. Pausing fades it out.
public sealed class NowPlayingCard
{
    public static NowPlayingCard Current { get; } = new();

    private const string Key = "spotify";
    private const double CardW = 640, CardH = 152; // reference pixels (1080p)
    private DispatcherQueueTimer? _fade, _hold;
    private double _opacity, _target;
    private string? _shownId;
    private bool _wasPlaying;
    private int _generation;

    private static MusicSettings S => EngineHost.Current.Settings.Music;

    public void Start()
    {
        var dq = DispatcherQueue.GetForCurrentThread();
        _fade = dq.CreateTimer();
        _fade.Interval = TimeSpan.FromMilliseconds(1000.0 / 30);
        _fade.Tick += (_, _) => StepFade();
        _hold = dq.CreateTimer();
        _hold.Interval = TimeSpan.FromSeconds(30);
        _hold.IsRepeating = false;
        _hold.Tick += (_, _) => FadeTo(0);
        NowPlaying.Current.Changed += OnTrack;
        EngineHost.Current.EngineStarted += () => { _shownId = null; _opacity = 0; };
        _ = NowPlaying.Current.StartAsync(S.Source);
    }

    private void OnTrack(Track? t)
    {
        bool resumed = t is { Playing: true } && !_wasPlaying;
        _wasPlaying = t?.Playing == true;
        if (!S.CardEnabled) return;
        if (t is not { Playing: true })
        {
            _shownId = null;
            FadeTo(0);
            return;
        }
        if ((t.Id != _shownId || resumed) && t.Title.Length > 0)
            _ = ShowAsync(t);
    }

    // After the music app switches: show its song if one's playing.
    public void SourceChanged()
    {
        _shownId = null;
        NowPlaying.Current.SetSource(S.Source);
    }

    public void SettingsChanged()
    {
        if (!S.CardEnabled) { FadeTo(0); return; }
        if (_opacity > 0 && NowPlaying.Current.Track is Track t) _ = ShowAsync(t);
    }

    // "Preview card": the current song, or a sample.
    public Task PreviewAsync() =>
        ShowAsync(NowPlaying.Current.Track ?? new Track("preview", "Song title goes here", "Artist name", true, null));

    private async Task ShowAsync(Track t)
    {
        if (!EngineHost.Current.IsRunning) return;
        int gen = ++_generation;
        _shownId = t.Id;
        CanvasBitmap? art = null;
        if (t.Art != null)
        {
            try
            {
                using var stream = await t.Art.OpenReadAsync();
                art = await CanvasBitmap.LoadAsync(OverlayCanvas.Device, stream);
            }
            catch (Exception) { }
        }
        if (gen != _generation) return; // a newer song meanwhile
        double k = OverlayCanvas.Scale;
        float w = (float)Math.Round(CardW * k), h = (float)Math.Round(CardH * k);
        using var target = new CanvasRenderTarget(OverlayCanvas.Device, w, h, 96);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Colors.Transparent);
            ds.Transform = Matrix3x2.CreateScale((float)k);
            Draw(ds, t, art);
        }
        art?.Dispose();
        if (gen != _generation || !await OverlayCanvas.PublishAsync(Key, target)) return;
        Place(w, h);
        FadeTo(1);
        _hold?.Stop();
        _hold?.Start();
    }

    private void Place(float w, float h)
    {
        double k = OverlayCanvas.Scale;
        bool left = S.Corner is "topLeft" or "bottomLeft", top = S.Corner is "topLeft" or "topRight";
        // 16:9: 40 px from the corner. 9:16: centred, at the top or just above the camera half.
        Native.oc_layer_place(Key, 0, 1, (float)((left ? 40 : 1920 - CardW - 40) * k), (float)((top ? 40 : 1080 - CardH - 40) * k), w, h);
        Native.oc_layer_place(Key, 1, S.Vertical ? 1 : 0, (float)((1080 - CardW) / 2 * k), (float)((top ? 48 : 960 - CardH - 32) * k), w, h);
    }

    private void FadeTo(double target)
    {
        _target = target;
        if (target <= 0) _hold?.Stop();
        if (_fade is { IsRunning: false } f) f.Start();
    }

    private void StepFade()
    {
        double step = 1.0 / 15;
        _opacity = _target > _opacity ? Math.Min(_target, _opacity + step) : Math.Max(_target, _opacity - step);
        double o = _opacity * _opacity * (3 - 2 * _opacity); // smoothstep
        if (EngineHost.Current.IsRunning) Native.oc_layer_set_opacity(Key, (float)o);
        if (Math.Abs(_opacity - _target) < 1e-6) _fade?.Stop();
    }

    // ---------------------------------------------------------------- the card (1x reference units)

    private static void Draw(CanvasDrawingSession ds, Track t, CanvasBitmap? art)
    {
        var accent = S.Source == "untitled" ? Color.FromArgb(255, 0xEB, 0xEB, 0xEB) : Color.FromArgb(255, 0x1C, 0xBA, 0x54);
        var card = new Rect(1, 1, CardW - 2, CardH - 2);
        ds.FillRoundedRectangle(card, 26, 26, Color.FromArgb(209, 15, 15, 15));
        ds.DrawRoundedRectangle(card, 26, 26, Color.FromArgb(26, 255, 255, 255), 1.5f);

        var artRect = new Rect(16, 16, 120, 120);
        using (var clip = CanvasGeometry.CreateRoundedRectangle(ds, artRect, 16, 16))
        using (ds.CreateLayer(1, clip))
        {
            if (art != null)
                ds.DrawImage(art, artRect, art.Bounds);
            else
            {
                ds.FillRectangle(artRect, Color.FromArgb(255, 0x2E, 0x2E, 0x2E));
                using var note = new CanvasTextFormat { FontFamily = "Segoe UI", FontSize = 54, HorizontalAlignment = CanvasHorizontalAlignment.Center, VerticalAlignment = CanvasVerticalAlignment.Center };
                ds.DrawText("♪", artRect, Color.FromArgb(128, 255, 255, 255), note);
            }
        }

        // Equalizer mark and "Now playing".
        float[] heights = { 10, 16, 12 };
        for (int i = 0; i < 3; i++)
            ds.FillRoundedRectangle(new Rect(158 + i * 6, 46 - heights[i], 3.5, heights[i]), 1.75f, 1.75f, accent);
        using (var label = new CanvasTextFormat { FontFamily = "Segoe UI Variable Text", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, FontSize = 17 })
            ds.DrawText("Now playing", 184, 26, accent, label);

        using (var title = new CanvasTextFormat
        {
            FontFamily = "Segoe UI Variable Display", FontWeight = Microsoft.UI.Text.FontWeights.Bold, FontSize = 32,
            WordWrapping = CanvasWordWrapping.NoWrap, TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        })
        {
            title.TrimmingSign = CanvasTrimmingSign.Ellipsis;
            ds.DrawText(t.Title, new Rect(158, 50, 458, 44), Colors.White, title);
        }
        using (var artist = new CanvasTextFormat
        {
            FontFamily = "Segoe UI Variable Text", FontWeight = Microsoft.UI.Text.FontWeights.Medium, FontSize = 22,
            WordWrapping = CanvasWordWrapping.NoWrap, TrimmingGranularity = CanvasTextTrimmingGranularity.Character,
        })
        {
            artist.TrimmingSign = CanvasTrimmingSign.Ellipsis;
            ds.DrawText(t.Artist, new Rect(158, 98, 458, 30), Color.FromArgb(158, 255, 255, 255), artist);
        }
    }
}
