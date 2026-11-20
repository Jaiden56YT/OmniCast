using System;
using System.Collections.Generic;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OmniCast.Services;
using Windows.Foundation;
using Windows.System;
using Windows.UI;

namespace OmniCast.Controls;

// Something on a canvas that can be moved and resized in Arrange mode.
// Boxes are in reference pixels: 1920x1080 for 16:9, 1080x1920 for 9:16.
public sealed class ArrangeItem
{
    public string Key = "";
    public string Label = "";
    public Color Color = Colors.White;
    public Func<Box> Get = () => new Box();
    public Action<Box> Set = _ => { };
    public Action? Reset;
    public double Aspect;           // > 0 keeps width/height while resizing
    public double MinW = 60, MinH = 40;
}

// Drawn over a preview while arranging: an outline per item. Drag one to move
// it, drag its corner to resize, arrow keys nudge the selected one (Shift for
// bigger steps, Ctrl+arrows to resize). Changes apply live.
public sealed class ArrangeLayer : Canvas
{
    private readonly int _canvas;
    private readonly List<(ArrangeItem Item, Grid View)> _views = new();
    private ArrangeItem? _selected;
    private Func<List<ArrangeItem>> _source = () => new();
    private readonly TextBlock _hint = new()
    {
        Text = "Drag to move · drag a corner to resize · arrows nudge",
        Foreground = new SolidColorBrush(Colors.White),
        FontSize = 11,
        Opacity = 0.85,
    };

    public ArrangeLayer(int canvas)
    {
        _canvas = canvas;
        Background = new SolidColorBrush(Color.FromArgb(1, 0, 0, 0)); // takes clicks on empty space
        IsTabStop = true;
        SizeChanged += (_, _) => Layout();
        PointerPressed += (_, e) => { if (e.OriginalSource == this) Select(null); Focus(FocusState.Pointer); };
        KeyDown += OnKey;
        PointerMoved += (_, e) => DragMove(e);
        PointerReleased += (_, _) => EndDrag();
        PointerCaptureLost += (_, _) => _dragItem = null;
        AutomationProperties.SetName(this, canvas == 0 ? "Arrange the 16:9 canvas" : "Arrange the 9:16 canvas");
    }

    private double RefW => _canvas == 0 ? 1920 : 1080;
    private double RefH => _canvas == 0 ? 1080 : 1920;

    // Reference pixels to this control's pixels (the canvas is letterboxed in the preview).
    private (double S, double Ox, double Oy) Map()
    {
        double s = Math.Min(ActualWidth / RefW, ActualHeight / RefH);
        return (s, (ActualWidth - RefW * s) / 2, (ActualHeight - RefH * s) / 2);
    }

    public void Show(Func<List<ArrangeItem>> source)
    {
        _source = source;
        Visibility = Visibility.Visible;
        Rebuild();
    }

    public void Hide()
    {
        Visibility = Visibility.Collapsed;
        _selected = null;
        Children.Clear();
        _views.Clear();
    }

    public void Rebuild()
    {
        if (Visibility != Visibility.Visible) return;
        string? keep = _selected?.Key;
        Children.Clear();
        _views.Clear();
        _selected = null;
        foreach (var item in _source())
        {
            var view = MakeView(item);
            _views.Add((item, view));
            Children.Add(view);
            if (item.Key == keep) _selected = item;
        }
        if (_canvas == 0)
        {
            SetLeft(_hint, 10);
            Children.Add(_hint);
        }
        Layout();
    }

    private void Layout()
    {
        var (s, ox, oy) = Map();
        foreach (var (item, view) in _views)
        {
            var b = item.Get();
            SetLeft(view, ox + b.X * s);
            SetTop(view, oy + b.Y * s);
            view.Width = Math.Max(8, b.W * s);
            view.Height = Math.Max(8, b.H * s);
            bool sel = item == _selected;
            var outline = (Rectangle)view.Children[0];
            outline.StrokeThickness = sel ? 2 : 1.5;
            outline.StrokeDashArray = sel ? null : new DoubleCollection { 5, 3 };
            ((FrameworkElement)view.Children[3]).Visibility = sel && item.Reset != null ? Visibility.Visible : Visibility.Collapsed;
            Canvas.SetZIndex(view, sel ? 1 : 0);
        }
        SetTop(_hint, ActualHeight - 22);
    }

    private Grid MakeView(ArrangeItem item)
    {
        var view = new Grid();
        var brush = new SolidColorBrush(item.Color);
        view.Children.Add(new Rectangle
        {
            Stroke = brush,
            Fill = new SolidColorBrush(Color.FromArgb(24, item.Color.R, item.Color.G, item.Color.B)),
            RadiusX = 4,
            RadiusY = 4,
        });
        var label = new Border
        {
            Background = brush,
            CornerRadius = new CornerRadius(3),
            Padding = new Thickness(5, 1, 5, 1),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -20, 0, 0),
            Child = new TextBlock { Text = item.Label, FontSize = 11, Foreground = new SolidColorBrush(Colors.Black) },
        };
        view.Children.Add(label);
        var handle = new Ellipse
        {
            Width = 14,
            Height = 14,
            Fill = brush,
            Stroke = new SolidColorBrush(Colors.Black),
            StrokeThickness = 1,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, -7, -7),
        };
        ToolTipService.SetToolTip(handle, "Drag to resize");
        view.Children.Add(handle);
        var reset = new HyperlinkButton
        {
            Content = "Reset",
            FontSize = 11,
            Padding = new Thickness(4, 0, 4, 0),
            Foreground = brush,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -22, 0, 0),
            Visibility = Visibility.Collapsed,
        };
        reset.Click += (_, _) => { item.Reset?.Invoke(); Layout(); };
        view.Children.Add(reset);
        AutomationProperties.SetName(view, item.Label);

        // Drag the body to move, the handle to resize. The layer follows the
        // pointer once a drag starts (it captures it), so fast moves don't lose it.
        view.PointerPressed += (_, e) => BeginDrag(item, e, resize: false);
        handle.PointerPressed += (_, e) => BeginDrag(item, e, resize: true);
        view.PointerEntered += (_, _) => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeAll);
        handle.PointerEntered += (_, _) => ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeNorthwestSoutheast);
        view.PointerExited += (_, _) => ProtectedCursor = null;
        return view;
    }

    private ArrangeItem? _dragItem;
    private bool _resizing;
    private Point _dragStart;
    private Box _dragBox = new();

    private void BeginDrag(ArrangeItem item, PointerRoutedEventArgs e, bool resize)
    {
        Select(item);
        _dragItem = item;
        _resizing = resize;
        _dragStart = e.GetCurrentPoint(this).Position;
        _dragBox = Copy(item.Get());
        CapturePointer(e.Pointer);
        Focus(FocusState.Pointer);
        e.Handled = true;
    }

    private void DragMove(PointerRoutedEventArgs e)
    {
        if (_dragItem == null) return;
        var (sc, _, _) = Map();
        var p = e.GetCurrentPoint(this).Position;
        double dx = (p.X - _dragStart.X) / sc, dy = (p.Y - _dragStart.Y) / sc;
        var b = Copy(_dragBox);
        if (_resizing)
        {
            b.W = Math.Max(_dragItem.MinW, _dragBox.W + dx);
            b.H = _dragItem.Aspect > 0 ? b.W / _dragItem.Aspect : Math.Max(_dragItem.MinH, _dragBox.H + dy);
        }
        else
        {
            b.X = _dragBox.X + dx;
            b.Y = _dragBox.Y + dy;
        }
        Apply(_dragItem, b);
        e.Handled = true;
    }

    private void EndDrag()
    {
        _dragItem = null;
        ReleasePointerCaptures();
    }

    private static Box Copy(Box b) => new() { X = b.X, Y = b.Y, W = b.W, H = b.H };

    // Keeps a box on the canvas (at least half of it visible) and not too small.
    private void Apply(ArrangeItem item, Box b)
    {
        b.W = Math.Clamp(b.W, item.MinW, RefW);
        b.H = Math.Clamp(b.H, item.MinH, RefH);
        b.X = Math.Clamp(b.X, -b.W / 2, RefW - b.W / 2);
        b.Y = Math.Clamp(b.Y, -b.H / 2, RefH - b.H / 2);
        item.Set(b);
        Layout();
    }

    private void Select(ArrangeItem? item)
    {
        _selected = item;
        Layout();
    }

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (_selected == null) return;
        bool shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        bool ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        double step = shift ? 40 : 8;
        var b = Copy(_selected.Get());
        switch (e.Key)
        {
            case VirtualKey.Left when ctrl: b.W -= step; break;
            case VirtualKey.Right when ctrl: b.W += step; break;
            case VirtualKey.Up when ctrl: b.H -= step; break;
            case VirtualKey.Down when ctrl: b.H += step; break;
            case VirtualKey.Left: b.X -= step; break;
            case VirtualKey.Right: b.X += step; break;
            case VirtualKey.Up: b.Y -= step; break;
            case VirtualKey.Down: b.Y += step; break;
            case VirtualKey.Escape: Select(null); e.Handled = true; return;
            default: return;
        }
        if (_selected.Aspect > 0 && ctrl) b.H = b.W / _selected.Aspect;
        Apply(_selected, b);
        e.Handled = true;
    }
}
