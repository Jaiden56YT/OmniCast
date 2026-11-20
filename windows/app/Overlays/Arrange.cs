using System;
using System.Collections.Generic;
using Microsoft.UI.Dispatching;
using OmniCast.Controls;
using OmniCast.Engine;
using OmniCast.Services;
using Windows.UI;

namespace OmniCast.Overlays;

// What can be moved and resized on each canvas in Arrange mode, and how each
// one is stored and applied. Saved half a second after the last change.
public static class Arrange
{
    private static EngineHost Host => EngineHost.Current;
    private static AppSettings S => Host.Settings;
    private static DispatcherQueueTimer? _save;

    private static readonly Color CameraColor = ChatOverlay.Hex("#5C9EFF");
    private static readonly Color ChatColor = ChatOverlay.Hex("#ED458C");
    private static readonly Color CardColor = ChatOverlay.Hex("#1CBA54");
    private static readonly Color MeColor = ChatOverlay.Hex("#FAC240");

    private static void SaveSoon()
    {
        if (_save == null)
        {
            _save = DispatcherQueue.GetForCurrentThread().CreateTimer();
            _save.Interval = TimeSpan.FromMilliseconds(500);
            _save.IsRepeating = false;
            _save.Tick += (_, _) => S.Save();
        }
        _save.Stop();
        _save.Start();
    }

    // The camera's place from the scene's layout (reference pixels), before any arranging.
    private static Box DefaultCamera(int canvas)
    {
        if (canvas == 1) return new Box { X = 0, Y = 960, W = 1080, H = 960 };
        var corner = Host.ActiveScene.CameraCorner;
        bool right = corner is CameraCorner.BottomRight or CameraCorner.TopRight;
        bool bottom = corner is CameraCorner.BottomRight or CameraCorner.BottomLeft;
        double w = 480, h = 270, m = 27;
        return new Box { X = right ? 1920 - w - m : m, Y = bottom ? 1080 - h - m : m, W = w, H = h };
    }

    public static List<ArrangeItem> Items(int canvas)
    {
        var items = new List<ArrangeItem>();
        var scene = Host.ActiveScene;
        bool hasCamera = scene.CameraId.Length > 0;

        // Camera: the 16:9 "screen + camera" layout, the 9:16 split layout.
        if (hasCamera && (canvas == 0 ? scene.WideLayout == WideLayout.ScreenAndCamera : scene.TallLayout == TallLayout.Split))
            items.Add(new ArrangeItem
            {
                Key = "camera",
                Label = "Camera",
                Color = CameraColor,
                Aspect = canvas == 0 ? 16.0 / 9.0 : 0,
                MinW = 80,
                MinH = 60,
                Get = () => (canvas == 0 ? S.CameraWide : S.CameraTall) ?? DefaultCamera(canvas),
                Set = b =>
                {
                    if (canvas == 0) S.CameraWide = b; else S.CameraTall = b;
                    Host.ApplyCameraBoxes();
                    SaveSoon();
                },
                Reset = () =>
                {
                    if (canvas == 0) S.CameraWide = null; else S.CameraTall = null;
                    Host.ApplyCameraBoxes();
                    SaveSoon();
                },
            });

        // Chat (drawn at its box's size, so resizing re-flows it).
        if (S.Chat.Visible && (canvas == 0 || S.Chat.Vertical))
            items.Add(new ArrangeItem
            {
                Key = "chat",
                Label = "Chat",
                Color = ChatColor,
                MinW = 200,
                MinH = 120,
                Get = () => (canvas == 0 ? S.Chat.WideBox : S.Chat.TallBox) ?? ChatOverlay.DefaultBox(canvas),
                Set = b =>
                {
                    if (canvas == 0) S.Chat.WideBox = b; else S.Chat.TallBox = b;
                    ChatOverlay.Current.Invalidate();
                    SaveSoon();
                },
                Reset = () =>
                {
                    if (canvas == 0) S.Chat.WideBox = null; else S.Chat.TallBox = null;
                    ChatOverlay.Current.Invalidate();
                    SaveSoon();
                },
            });

        // Now-playing card.
        if (S.Music.CardEnabled && (canvas == 0 || S.Music.Vertical))
            items.Add(new ArrangeItem
            {
                Key = "card",
                Label = "Now playing",
                Color = CardColor,
                Aspect = NowPlayingCard.Aspect,
                MinW = 200,
                MinH = 48,
                Get = () => NowPlayingCard.Box(canvas),
                Set = b =>
                {
                    if (canvas == 0) S.Music.CardWide = b; else S.Music.CardTall = b;
                    NowPlayingCard.Current.Replace();
                    SaveSoon();
                },
                Reset = () =>
                {
                    if (canvas == 0) S.Music.CardWide = null; else S.Music.CardTall = null;
                    NowPlayingCard.Current.Replace();
                    SaveSoon();
                },
            });

        // Your PNGtuber and the Discord call's people (16:9 only). Stored as
        // their centre and height, so the box keeps the picture's shape.
        if (canvas == 0)
            foreach (var (id, label, aspect) in CallOverlay.Current.Arrangeable())
            {
                string who = id;
                items.Add(new ArrangeItem
                {
                    Key = "person:" + who,
                    Label = label,
                    Color = who == CallOverlay.Me ? MeColor : Microsoft.UI.Colors.White,
                    Aspect = aspect,
                    MinW = 40 * aspect,
                    MinH = 40,
                    Get = () =>
                    {
                        var l = S.Discord.Layouts.TryGetValue(who, out var lay) ? lay : new PersonLayout();
                        double w = l.Size * aspect;
                        return new Box { X = l.X - w / 2, Y = l.Y - l.Size / 2, W = w, H = l.Size };
                    },
                    Set = b =>
                    {
                        var l = S.Discord.Layouts.TryGetValue(who, out var lay) ? lay : new PersonLayout();
                        S.Discord.Layouts[who] = new PersonLayout { X = b.X + b.W / 2, Y = b.Y + b.H / 2, Size = b.H, Flip = l.Flip };
                        CallOverlay.Current.PlaceAll();
                        SaveSoon();
                    },
                    Reset = who == CallOverlay.Me ? () =>
                    {
                        S.Discord.Layouts[who] = new PersonLayout { X = 1700, Y = 820, Size = 420 };
                        CallOverlay.Current.PlaceAll();
                        SaveSoon();
                    } : null,
                });
            }
        return items;
    }
}
