using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OmniCast.Engine;

namespace OmniCast.Controls;

// One mixer channel: mute, name, a stereo peak meter and the stream level.
public sealed class AudioRow : Grid
{
    private readonly int _channel;
    private readonly string _name;
    private readonly ToggleButton _mute;
    private readonly FontIcon _muteIcon;
    private readonly string _glyph;
    private readonly Slider _slider;
    private readonly ScaleTransform[] _meters = new ScaleTransform[2];
    private readonly float[] _shown = { 0, 0 };
    private bool _loading = true; // until Load(): controls fire change events while the page is built

    public AudioRow(int channel, string name, string glyph)
    {
        _channel = channel;
        _name = name;
        _glyph = glyph;
        ColumnSpacing = 10;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });

        _muteIcon = new FontIcon { Glyph = glyph, FontSize = 14 };
        _mute = new ToggleButton { Content = _muteIcon, Width = 36, Height = 32, Padding = new Thickness(0) };
        AutomationProperties.SetName(_mute, $"Mute {name}");
        ToolTipService.SetToolTip(_mute, $"Mute {name}");
        _mute.Click += (_, _) => Apply();
        Children.Add(_mute);

        var middle = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        middle.Children.Add(new TextBlock { Text = name, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
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
            track.Children.Add(new Rectangle
            {
                Fill = (Brush)Application.Current.Resources["MeterBrush"],
                RenderTransform = _meters[i],
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
            middle.Children.Add(track);
        }
        SetColumn(middle, 1);
        Children.Add(middle);

        _slider = new Slider { Minimum = 0, Maximum = 100, StepFrequency = 1, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(_slider, $"{name} stream level");
        _slider.ValueChanged += (_, _) => Apply();
        _slider.ThumbToolTipValueConverter = new DbConverter();
        SetColumn(_slider, 2);
        Children.Add(_slider);
    }

    // Slider 0-100 to gain: squared, so the top half of the fader is where the
    // fine control is (50 = -12 dB, 100 = unity).
    public static double ToGain(double v) => Math.Pow(v / 100.0, 2);
    public static double FromGain(double g) => Math.Sqrt(Math.Clamp(g, 0, 1)) * 100.0;

    public void Load()
    {
        var c = EngineHost.Current.Settings.Channels[_channel];
        _loading = true;
        _slider.Value = FromGain(c.Volume);
        _mute.IsChecked = c.Muted;
        _muteIcon.Glyph = c.Muted || _sceneMuted ? "\uE74F" : _glyph;
        _loading = false;
    }

    private bool _sceneMuted;

    // The scene on air mutes this channel (mic only): show it as muted and say why.
    public void SetSceneMuted(bool muted)
    {
        _sceneMuted = muted;
        var c = EngineHost.Current.Settings.Channels[_channel];
        _muteIcon.Glyph = c.Muted || muted ? "\uE74F" : _glyph;
        ToolTipService.SetToolTip(_mute, muted ? $"{_name} is muted by this scene" : $"Mute {_name}");
    }

    private void Apply()
    {
        if (_loading) return;
        var host = EngineHost.Current;
        var c = host.Settings.Channels[_channel];
        c.Volume = ToGain(_slider.Value);
        c.Muted = _mute.IsChecked == true;
        _muteIcon.Glyph = c.Muted || _sceneMuted ? "\uE74F" : _glyph;
        host.ApplyChannel(_channel);
        host.Settings.Save();
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
            _shown[i] = level > _shown[i] ? level : Math.Max(level, _shown[i] - 0.04f);
            _meters[i].ScaleX = _shown[i];
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
