using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Controls;

// One mixer channel: its name, a stereo peak meter, and two levels, each with
// a mute: Stream (the stream and recordings) and Monitor (your headphones).
public sealed class AudioRow : StackPanel
{
    private readonly int _channel;
    private readonly string _name;
    private readonly Fader _stream, _monitor;
    private readonly ScaleTransform[] _meters = new ScaleTransform[2];
    private readonly float[] _shown = { 0, 0 };
    private readonly Rectangle[] _fills = new Rectangle[2];
    private bool _loading = true; // until Load(): controls fire change events while the page is built
    private bool _sceneMuted;

    public int ChannelIndex => _channel;
    public Button? FxButton { get; }

    // glyph is a Segoe Fluent icon; iconPath, when given, is an exe whose icon is shown instead.
    public AudioRow(int channel, string name, string glyph, string? iconPath = null, Action? remove = null, FlyoutBase? fx = null)
    {
        _channel = channel;
        _name = name;
        Spacing = 4;

        var head = new Grid { ColumnSpacing = 8 };
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        FrameworkElement icon = new FontIcon { Glyph = glyph, FontSize = 14 };
        if (!string.IsNullOrEmpty(iconPath))
        {
            var image = new Image { Width = 16, Height = 16 };
            LoadIcon(image, iconPath);
            icon = image;
        }
        icon.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(icon);
        var label = new TextBlock
        {
            Text = name,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(label, 1);
        head.Children.Add(label);
        if (remove != null)
        {
            var x = new Button
            {
                Content = new FontIcon { Glyph = "\uE711", FontSize = 10 },
                Padding = new Thickness(4),
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                BorderThickness = new Thickness(0),
            };
            ToolTipService.SetToolTip(x, "Remove; the app goes back into desktop audio");
            AutomationProperties.SetName(x, $"Remove {name}");
            x.Click += (_, _) => remove();
            Grid.SetColumn(x, 2);
            head.Children.Add(x);
        }
        if (fx != null)
        {
            FxButton = new Button
            {
                Content = new TextBlock { Text = "FX", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Bold },
                Padding = new Thickness(6, 1, 6, 1),
                MinHeight = 0,
                Flyout = fx,
            };
            ToolTipService.SetToolTip(FxButton, "Mic plugins (VST3)");
            AutomationProperties.SetName(FxButton, "Mic plugins");
            Grid.SetColumn(FxButton, 2);
            head.Children.Add(FxButton);
        }
        Children.Add(head);

        var meters = new StackPanel { Spacing = 1 };
        for (int i = 0; i < 2; i++)
        {
            var track = new Grid
            {
                Height = 3,
                CornerRadius = new CornerRadius(1.5),
                Background = (Brush)Application.Current.Resources["ControlStrongFillColorDisabledBrush"],
            };
            // A scale transform on the bar: the cheapest way to animate a meter
            // (no layout pass, composited on the GPU).
            _meters[i] = new ScaleTransform { ScaleX = 0 };
            _fills[i] = new Rectangle
            {
                Fill = (Brush)Application.Current.Resources["MeterBrush"],
                RenderTransform = _meters[i],
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            track.Children.Add(_fills[i]);
            meters.Children.Add(track);
        }
        Children.Add(meters);

        _stream = new Fader("\uE93E", "Stream", name, Apply);
        _monitor = new Fader("\uE7F6", "Monitor", name, Apply);
        Children.Add(_stream);
        Children.Add(_monitor);
    }

    private static async void LoadIcon(Image image, string path)
    {
        try
        {
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            using var thumb = await file.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.SingleItem, 32);
            var bmp = new BitmapImage();
            await bmp.SetSourceAsync(thumb);
            image.Source = bmp;
        }
        catch (Exception)
        {
            // The app moved or was uninstalled: no icon.
        }
    }

    // Fader position 0-100 to gain: cubed, like OBS and the Mac app, so the
    // top of the fader is where the fine control is (50 = -18 dB, 100 = unity).
    public static double ToGain(double v) => Math.Pow(v / 100.0, 3);
    public static double FromGain(double g) => Math.Cbrt(Math.Clamp(g, 0, 1)) * 100.0;

    public void Load()
    {
        var c = EngineHost.Current.Channel(_channel);
        if (c == null) return;
        _loading = true;
        _stream.Set(FromGain(c.Volume), c.Muted);
        _monitor.Set(FromGain(c.Monitor), c.MonitorMuted);
        UpdateMuteLook(c);
        _loading = false;
    }

    // The scene on air mutes this channel (mic only): show it as muted and say why.
    public void SetSceneMuted(bool muted)
    {
        _sceneMuted = muted;
        _stream.SetSceneNote(muted ? $"{_name} is muted by this scene" : null);
        Load();
    }

    private void Apply()
    {
        if (_loading) return;
        var host = EngineHost.Current;
        var c = host.Channel(_channel);
        if (c == null) return;
        c.Volume = ToGain(_stream.Value);
        c.Muted = _stream.Muted;
        c.Monitor = ToGain(_monitor.Value);
        c.MonitorMuted = _monitor.Muted;
        UpdateMuteLook(c);
        host.ApplyChannel(_channel);
        host.Settings.Save();
    }

    private void UpdateMuteLook(ChannelInfo c)
    {
        // Gray meters when the channel is muted everywhere.
        double o = (c.Muted || _sceneMuted) && c.MonitorMuted ? 0.35 : 1;
        _fills[0].Opacity = _fills[1].Opacity = o;
    }

    // ~30 times a second while visible. Falls back smoothly like a real meter.
    public void UpdateMeter()
    {
        if (Visibility != Visibility.Visible) return;
        Native.oc_audio_levels(_channel, out float l, out float r);
        float[] db = { l, r };
        for (int i = 0; i < 2; i++)
        {
            float level = float.IsNegativeInfinity(db[i]) ? 0 : Math.Clamp((db[i] + 60f) / 60f, 0, 1);
            _shown[i] = level > _shown[i] ? level : Math.Max(level, _shown[i] - 0.025f); // ~24 dB/s at 30 Hz
            _meters[i].ScaleX = _shown[i];
        }
    }

    // One level: a small icon, the slider, its dB and a mute toggle.
    private sealed class Fader : Grid
    {
        private readonly Slider _slider;
        private readonly ToggleButton _mute;
        private readonly FontIcon _muteIcon;
        private readonly TextBlock _db;
        private readonly string _what, _channelName;
        private readonly Action _changed;

        public double Value => _slider.Value;
        public bool Muted => _mute.IsChecked == true;

        public Fader(string glyph, string what, string channelName, Action changed)
        {
            _what = what;
            _channelName = channelName;
            _changed = changed;
            ColumnSpacing = 6;
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(52) });
            ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var icon = new FontIcon { Glyph = glyph, FontSize = 11, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
            ToolTipService.SetToolTip(icon, what);
            Children.Add(icon);

            _slider = new Slider { Minimum = 0, Maximum = 100, StepFrequency = 1, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, -6, 0, -6) };
            AutomationProperties.SetName(_slider, $"{channelName} {what.ToLowerInvariant()} level");
            _slider.ThumbToolTipValueConverter = new DbConverter();
            _slider.ValueChanged += (_, _) => { UpdateDb(); _changed(); };
            SetColumn(_slider, 1);
            Children.Add(_slider);

            _db = new TextBlock
            {
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Opacity = 0.7,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            };
            SetColumn(_db, 2);
            Children.Add(_db);

            _muteIcon = new FontIcon { Glyph = "\uE767", FontSize = 12 };
            _mute = new ToggleButton { Content = _muteIcon, Width = 28, Height = 24, Padding = new Thickness(0), VerticalAlignment = VerticalAlignment.Center };
            _mute.Click += (_, _) => { UpdateMute(); _changed(); };
            SetColumn(_mute, 3);
            Children.Add(_mute);
            SetSceneNote(null);
        }

        public void Set(double value, bool muted)
        {
            _slider.Value = value;
            _mute.IsChecked = muted;
            UpdateDb();
            UpdateMute();
        }

        private string? _note;
        public void SetSceneNote(string? note)
        {
            _note = note;
            UpdateMute();
        }

        private void UpdateDb()
        {
            double g = ToGain(_slider.Value);
            double db = g <= 0 ? double.NegativeInfinity : 20 * Math.Log10(g);
            _db.Text = db < -60 ? "−∞ dB" : $"{db:0.0} dB";
        }

        private void UpdateMute()
        {
            bool m = Muted;
            _muteIcon.Glyph = m ? "\uE74F" : "\uE767";
            _slider.Opacity = m ? 0.4 : 1;
            string tip = _note ?? (m ? $"Unmute in the {_what.ToLowerInvariant()} mix" : $"Mute in the {_what.ToLowerInvariant()} mix");
            ToolTipService.SetToolTip(_mute, tip);
            AutomationProperties.SetName(_mute, $"Mute {_channelName} in the {_what.ToLowerInvariant()} mix");
        }
    }

    private sealed class DbConverter : Microsoft.UI.Xaml.Data.IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, string language)
        {
            double g = ToGain((double)value);
            return g <= 0 ? "Off" : $"{20 * Math.Log10(g):0.0} dB";
        }

        public object ConvertBack(object value, Type targetType, object parameter, string language) => throw new NotSupportedException();
    }
}
