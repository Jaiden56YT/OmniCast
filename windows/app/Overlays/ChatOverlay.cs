using System;
using System.Collections.Generic;
using System.Linq;
using System.Numerics;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Geometry;
using Microsoft.Graphics.Canvas.Text;
using Microsoft.UI.Dispatching;
using OmniCast.Chat;
using OmniCast.Engine;
using OmniCast.Services;
using Windows.Foundation;
using Windows.UI;
using Colors = Microsoft.UI.Colors;

namespace OmniCast.Overlays;

// Draws the merged chat into a transparent PNG at exactly its box size and
// shows it on the canvases: newest line at the bottom, heavy white text with a
// black outline, platform and badge icons, coloured names, inline emotes.
// Redrawn at most every 120 ms, only when something changed.
public sealed class ChatOverlay
{
    public static ChatOverlay Current { get; } = new();

    private static readonly string[] Keys = { "chat-horizontal", "chat-vertical" };
    private DispatcherQueueTimer? _coalesce, _expire;
    private bool _dirty, _drawing;
    private readonly Dictionary<string, CanvasBitmap?> _emotes = new();
    private readonly HashSet<string> _loading = new();

    // Default boxes, in 1920x1080 / 1080x1920 reference pixels.
    public static Box DefaultBox(int canvas) => canvas == 0
        ? new Box { X = 24, Y = 230, W = 470, H = 620 }
        : new Box { X = 40, Y = 1060, W = 660, H = 560 };

    private static ChatSettings S => EngineHost.Current.Settings.Chat;

    public void Start()
    {
        var dq = DispatcherQueue.GetForCurrentThread();
        _coalesce = dq.CreateTimer();
        _coalesce.Interval = TimeSpan.FromMilliseconds(120);
        _coalesce.IsRepeating = false;
        _coalesce.Tick += async (_, _) => await DrawAsync();
        _expire = dq.CreateTimer();
        _expire.Interval = TimeSpan.FromSeconds(1);
        _expire.Tick += (_, _) => { if (S.HideAfter > 0 && ChatHub.Current.Messages.Count > 0) Invalidate(); };
        _expire.Start();
        ChatHub.Current.MessagesChanged += Invalidate;
        EngineHost.Current.EngineStarted += Invalidate;
        Invalidate();
    }

    public void Invalidate()
    {
        _dirty = true;
        if (_coalesce is { IsRunning: false } t) t.Start();
    }

    private async Task DrawAsync()
    {
        if (_drawing) { _coalesce?.Start(); return; }
        _drawing = true;
        try
        {
            while (_dirty)
            {
                _dirty = false;
                for (int canvas = 0; canvas < 2; canvas++)
                    await DrawCanvasAsync(canvas);
            }
        }
        finally { _drawing = false; }
    }

    private async Task DrawCanvasAsync(int canvas)
    {
        var host = EngineHost.Current;
        string key = Keys[canvas];
        if (!host.IsRunning) return;
        bool wanted = S.Visible && (canvas == 0 || S.Vertical);
        var lines = ChatHub.Current.Messages
            .Where(m => S.HideAfter <= 0 || (DateTime.UtcNow - m.Received).TotalSeconds < S.HideAfter)
            .ToList();
        if (!wanted || lines.Count == 0)
        {
            Native.oc_layer_set_opacity(key, 0);
            return;
        }
        var box = (canvas == 0 ? S.WideBox : S.TallBox) ?? DefaultBox(canvas);
        double k = OverlayCanvas.Scale;
        float w = (float)Math.Max(1, Math.Round(box.W * k)), h = (float)Math.Max(1, Math.Round(box.H * k));
        float font = (float)((S.Size switch { "small" => 20, "large" => 31, _ => 25 }) * k);

        using var target = new CanvasRenderTarget(OverlayCanvas.Device, w, h, 96);
        using (var ds = target.CreateDrawingSession())
        {
            ds.Clear(Colors.Transparent);
            ds.TextAntialiasing = CanvasTextAntialiasing.Grayscale;
            float y = h - 6;
            float gap = font * 0.35f;
            for (int i = lines.Count - 1; i >= 0; i--)
            {
                using var layout = Layout(ds, lines[i], font, w - 12, out var inlines);
                float lh = (float)layout.LayoutBounds.Height + 4;
                if (y - lh < 0) break;
                DrawLine(ds, layout, inlines, 6, y - lh, font);
                y -= lh + gap;
            }
        }
        if (await OverlayCanvas.PublishAsync(key, target))
        {
            Native.oc_layer_place(key, canvas, 1, (float)(box.X * k), (float)(box.Y * k), w, h);
            Native.oc_layer_set_opacity(key, 1);
        }
    }

    // ---------------------------------------------------------------- one line

    private const char Obj = '￼'; // stands in for an inline image

    private CanvasTextLayout Layout(CanvasDrawingSession ds, ChatMessage m, float font, float width, out List<(int Index, InlineImage Image)> inlines)
    {
        var list = new List<(int Index, InlineImage Image)>();
        inlines = list;
        var sb = new StringBuilder();
        var brushes = new List<(int Start, int Len, Color Color)>();
        void Add(InlineImage img)
        {
            list.Add((sb.Length, img));
            sb.Append(Obj);
        }

        Add(new InlineImage(InlineKind.Platform, m.Platform, null, null, font * 0.95f * (m.Platform == ChatPlatform.YouTube ? 1.4f : 1f), font * 0.95f));
        sb.Append(' ');
        foreach (var b in m.Badges)
        {
            Add(new InlineImage(InlineKind.Badge, m.Platform, b, null, font * 0.9f, font * 0.9f));
            sb.Append(' ');
        }
        int nameStart = sb.Length;
        sb.Append(m.Author);
        brushes.Add((nameStart, m.Author.Length, NameColor(m)));
        sb.Append("  ");
        foreach (var p in m.Parts)
        {
            if (p.EmoteUrl != null && Emote(p.EmoteUrl) is CanvasBitmap bmp)
            {
                float eh = font * 1.25f;
                float ew = eh * (float)(bmp.Size.Width / Math.Max(1, bmp.Size.Height));
                Add(new InlineImage(InlineKind.Emote, m.Platform, null, bmp, ew, eh));
            }
            else
            {
                sb.Append(p.Text);
            }
        }

        var format = new CanvasTextFormat
        {
            FontFamily = "Segoe UI Black",
            FontWeight = Microsoft.UI.Text.FontWeights.Black,
            FontSize = font,
            WordWrapping = CanvasWordWrapping.Wrap,
            LineSpacingMode = CanvasLineSpacingMode.Proportional,
            LineSpacing = 0.95f,
        };
        var layout = new CanvasTextLayout(ds, sb.ToString(), format, width, 10000);
        layout.Options = CanvasDrawTextOptions.EnableColorFont;
        foreach (var (start, len, color) in brushes)
            layout.SetColor(start, len, color);
        foreach (var (index, img) in inlines)
            layout.SetInlineObject(index, 1, img);
        return layout;
    }

    // First the outline (each glyph's shape stroked in black), then the text
    // itself in colour (with colour emoji), then the icons and emotes.
    private static void DrawLine(CanvasDrawingSession ds, CanvasTextLayout layout, List<(int Index, InlineImage Image)> inlines, float x, float y, float font)
    {
        var outline = new OutlineRenderer(ds, font * 0.17f * 2);
        layout.DrawToTextRenderer(outline, x, y);
        ds.DrawTextLayout(layout, x, y, Colors.White);
        foreach (var (point, img) in outline.Inlines)
            img.DrawAt(ds, point);
    }

    private sealed class OutlineRenderer : ICanvasTextRenderer
    {
        private readonly CanvasDrawingSession _ds;
        private readonly float _stroke;
        private readonly CanvasStrokeStyle _style = new() { LineJoin = CanvasLineJoin.Round };
        public readonly List<(Vector2 Point, InlineImage Image)> Inlines = new();

        public OutlineRenderer(CanvasDrawingSession ds, float stroke)
        {
            _ds = ds;
            _stroke = stroke;
        }

        public float Dpi => 96;
        public bool PixelSnappingDisabled => true;
        public Matrix3x2 Transform => Matrix3x2.Identity;

        public void DrawGlyphRun(Vector2 point, CanvasFontFace fontFace, float fontSize, CanvasGlyph[] glyphs, bool isSideways, uint bidiLevel,
            object brush, CanvasTextMeasuringMode measuringMode, string localeName, string textString, int[] clusterMapIndices,
            uint characterIndex, CanvasGlyphOrientation glyphOrientation)
        {
            using var geo = CanvasGeometry.CreateGlyphRun(_ds, point, fontFace, fontSize, glyphs, isSideways, bidiLevel, measuringMode, glyphOrientation);
            _ds.DrawGeometry(geo, Colors.Black, _stroke, _style);
        }

        public void DrawInlineObject(Vector2 point, ICanvasTextInlineObject inlineObject, bool isSideways, bool isRightToLeft, object brush,
            CanvasGlyphOrientation glyphOrientation)
        {
            if (inlineObject is InlineImage img)
                Inlines.Add((point, img));
        }

        public void DrawStrikethrough(Vector2 point, float strikethroughWidth, float strikethroughThickness, float strikethroughOffset,
            CanvasTextDirection textDirection, object brush, CanvasTextMeasuringMode textMeasuringMode, string localeName, CanvasGlyphOrientation glyphOrientation) { }

        public void DrawUnderline(Vector2 point, float underlineWidth, float underlineThickness, float underlineOffset, float runHeight,
            CanvasTextDirection textDirection, object brush, CanvasTextMeasuringMode textMeasuringMode, string localeName, CanvasGlyphOrientation glyphOrientation) { }
    }

    // ---------------------------------------------------------------- colours

    private static readonly Color[] Palette =
    {
        Hex("#A78BFA"), Hex("#D46BFF"), Hex("#FF8FD0"), Hex("#6E8BFF"), Hex("#4ED1A1"), Hex("#FF7A59"),
    };

    public static Color Hex(string s)
    {
        s = s.TrimStart('#');
        if (s.Length != 6 || !uint.TryParse(s, System.Globalization.NumberStyles.HexNumber, null, out uint v))
            return Colors.White;
        return Color.FromArgb(255, (byte)(v >> 16), (byte)(v >> 8), (byte)v);
    }

    private static Color NameColor(ChatMessage m)
    {
        if (m.Badges.Contains(ChatBadge.Owner)) return Hex("#B794FF");
        if (m.Color is { Length: > 0 } c)
        {
            var col = Hex(c);
            double brightness = Math.Max(col.R, Math.Max(col.G, col.B)) / 255.0;
            if (brightness < 0.55) // too dark on a stream: lift it toward white
                col = Color.FromArgb(255, (byte)(col.R + (255 - col.R) * 0.45), (byte)(col.G + (255 - col.G) * 0.45), (byte)(col.B + (255 - col.B) * 0.45));
            return col;
        }
        uint h = 5381;
        foreach (byte b in Encoding.UTF8.GetBytes(m.Author)) h = unchecked(h * 33 + b);
        return Palette[h % (uint)Palette.Length];
    }

    // ---------------------------------------------------------------- emotes

    // The emote's image, or null while it downloads (the text shows meanwhile,
    // and the chat redraws once it arrives).
    private CanvasBitmap? Emote(string url)
    {
        if (_emotes.TryGetValue(url, out var bmp)) return bmp;
        if (_loading.Add(url)) _ = LoadEmoteAsync(url);
        return null;
    }

    private async Task LoadEmoteAsync(string url)
    {
        CanvasBitmap? bmp = null;
        try
        {
            byte[] bytes = await ChatHub.Http.GetByteArrayAsync(url);
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            await stream.WriteAsync(System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsBuffer(bytes));
            stream.Seek(0);
            bmp = await CanvasBitmap.LoadAsync(OverlayCanvas.Device, stream);
        }
        catch (Exception) { }
        _emotes[url] = bmp;
        _loading.Remove(url);
        if (_emotes.Count > 500) _emotes.Clear();
        if (bmp != null) Invalidate();
    }

    // ---------------------------------------------------------------- icons and emotes in the text

    private enum InlineKind { Platform, Badge, Emote }

    private sealed class InlineImage : ICanvasTextInlineObject
    {
        private readonly InlineKind _kind;
        private readonly ChatPlatform _platform;
        private readonly ChatBadge? _badge;
        private readonly CanvasBitmap? _bitmap;
        private readonly float _w, _h;

        public InlineImage(InlineKind kind, ChatPlatform platform, ChatBadge? badge, CanvasBitmap? bitmap, float w, float h)
        {
            _kind = kind;
            _platform = platform;
            _badge = badge;
            _bitmap = bitmap;
            _w = w;
            _h = h;
        }

        public Size Size => new(_w, _h);
        public Rect DrawBounds => new(0, 0, _w, _h);
        // Centred on the text: the baseline sits a little below the middle.
        public float Baseline => _h * 0.8f;
        public bool SupportsSideways => false;
        public CanvasLineBreakCondition BreakBefore => CanvasLineBreakCondition.Neutral;
        public CanvasLineBreakCondition BreakAfter => CanvasLineBreakCondition.Neutral;

        // DrawTextLayout calls this; the images are drawn afterwards instead (DrawAt).
        public void Draw(ICanvasTextRenderer textRenderer, Vector2 point, bool isSideways, bool isRightToLeft, object brush) { }

        public void DrawAt(CanvasDrawingSession ds, Vector2 p)
        {
            var r = new Rect(p.X, p.Y, _w, _h);
            switch (_kind)
            {
                case InlineKind.Emote when _bitmap != null:
                    ds.DrawImage(_bitmap, r);
                    break;
                case InlineKind.Platform:
                    DrawPlatform(ds, r);
                    break;
                case InlineKind.Badge:
                    DrawBadge(ds, r);
                    break;
            }
        }

        private void DrawPlatform(CanvasDrawingSession ds, Rect r)
        {
            float h = (float)r.Height;
            var inner = new Rect(r.X + 1.5, r.Y + 1.5, r.Width - 3, r.Height - 3);
            Color fill = _platform switch { ChatPlatform.YouTube => Hex("#FF0033"), ChatPlatform.Twitch => Hex("#9146FF"), _ => Hex("#53FC18") };
            ds.FillRoundedRectangle(inner, 0.26f * h, 0.26f * h, fill);
            ds.DrawRoundedRectangle(inner, 0.26f * h, 0.26f * h, Colors.Black, 2.5f);
            float mx = (float)(r.X + r.Width / 2), my = (float)(r.Y + r.Height / 2);
            switch (_platform)
            {
                case ChatPlatform.YouTube:
                    using (var tri = CanvasGeometry.CreatePolygon(ds, new[]
                    {
                        new Vector2(mx - 0.18f * h, my - 0.22f * h), new Vector2(mx - 0.18f * h, my + 0.22f * h), new Vector2(mx + 0.24f * h, my),
                    }))
                        ds.FillGeometry(tri, Colors.White);
                    break;
                case ChatPlatform.Twitch:
                {
                    float x0 = (float)r.X + 0.22f * h, y0 = (float)r.Y + h - 0.30f * h - 0.44f * h;
                    ds.FillRectangle(x0, y0, 0.52f * h, 0.44f * h, Colors.White);
                    foreach (float bx in new[] { 0.38f, 0.56f })
                        ds.FillRectangle((float)r.X + bx * h - 0.04f * h, (float)r.Y + h - 0.42f * h - 0.2f * h, 0.07f * h, 0.2f * h, fill);
                    break;
                }
                default:
                    using (var f = new CanvasTextFormat { FontFamily = "Segoe UI Black", FontWeight = Microsoft.UI.Text.FontWeights.Black, FontSize = 0.72f * h, HorizontalAlignment = CanvasHorizontalAlignment.Center, VerticalAlignment = CanvasVerticalAlignment.Center })
                        ds.DrawText("K", r, Colors.Black, f);
                    break;
            }
        }

        private void DrawBadge(CanvasDrawingSession ds, Rect r)
        {
            float s = (float)r.Height;
            float x = (float)r.X, y = (float)r.Y;
            Vector2 P(float u, float v) => new(x + u * s, y + v * s);
            Vector2[] shape;
            Color color;
            switch (_badge)
            {
                case ChatBadge.Owner: // crown
                    color = Hex("#FFD54A");
                    shape = new[] { P(0.08f, 0.82f), P(0.08f, 0.28f), P(0.32f, 0.52f), P(0.5f, 0.18f), P(0.68f, 0.52f), P(0.92f, 0.28f), P(0.92f, 0.82f) };
                    break;
                case ChatBadge.Moderator: // sword
                    color = Hex("#6E8BFF");
                    shape = new[] { P(0.82f, 0.08f), P(0.92f, 0.18f), P(0.42f, 0.68f), P(0.5f, 0.8f), P(0.4f, 0.9f), P(0.3f, 0.78f), P(0.16f, 0.92f), P(0.08f, 0.84f), P(0.22f, 0.7f), P(0.1f, 0.6f), P(0.2f, 0.5f), P(0.32f, 0.58f) };
                    break;
                case ChatBadge.Vip: // diamond
                    color = Hex("#FF5FD2");
                    shape = new[] { P(0.5f, 0.08f), P(0.92f, 0.5f), P(0.5f, 0.92f), P(0.08f, 0.5f) };
                    break;
                case ChatBadge.Member: // star
                {
                    color = Hex("#B58CFF");
                    var pts = new List<Vector2>();
                    for (int i = 0; i < 10; i++)
                    {
                        double a = -Math.PI / 2 + i * Math.PI / 5;
                        float rad = i % 2 == 0 ? 0.46f : 0.2f;
                        pts.Add(P(0.5f + rad * (float)Math.Cos(a), 0.54f + rad * (float)Math.Sin(a)));
                    }
                    shape = pts.ToArray();
                    break;
                }
                default: // verified: a check in a circle
                    color = Hex("#E6E6E6");
                    ds.FillCircle(P(0.5f, 0.5f), 0.44f * s, Colors.Black);
                    ds.FillCircle(P(0.5f, 0.5f), 0.4f * s, color);
                    using (var path = new CanvasPathBuilder(ds))
                    {
                        path.BeginFigure(P(0.28f, 0.5f));
                        path.AddLine(P(0.44f, 0.66f));
                        path.AddLine(P(0.74f, 0.34f));
                        path.EndFigure(CanvasFigureLoop.Open);
                        using var g = CanvasGeometry.CreatePath(path);
                        ds.DrawGeometry(g, Colors.Black, 0.12f * s);
                    }
                    return;
            }
            using var geo = CanvasGeometry.CreatePolygon(ds, shape);
            ds.DrawGeometry(geo, Colors.Black, 3f);
            ds.FillGeometry(geo, color);
        }
    }
}
