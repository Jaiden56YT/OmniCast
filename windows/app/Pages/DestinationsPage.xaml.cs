using System;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Pages;

public sealed partial class DestinationsPage : Page
{
    private readonly EngineHost _host = EngineHost.Current;
    private DestinationInfo? _editing;
    private bool _platformChangedByUser;

    // Where each platform's server is, and where to find the key. Servers that
    // differ per account (Kick, TikTok, Instagram) are pasted by the user.
    private static readonly (Platform P, string Server, int Canvas, string Help)[] Platforms =
    {
        (Platform.YouTube, "rtmps://a.rtmps.youtube.com:443/live2", 0,
            "YouTube Studio › Create › Go live › Stream: copy the stream key."),
        (Platform.Twitch, "rtmp://live.twitch.tv/app", 0,
            "Twitch: Creator Dashboard › Settings › Stream: copy the primary stream key."),
        (Platform.Kick, "", 0,
            "kick.com › Dashboard › Settings › Stream URL and Key: paste both."),
        (Platform.TikTok, "", 1,
            "TikTok LIVE Studio or LIVE Center (you need access to streaming keys): paste the Server URL and Stream key."),
        (Platform.Instagram, "", 1,
            "Instagram on the web › Create › Live video: paste the Stream URL and Stream key. They change for every live."),
        (Platform.Custom, "", 0,
            "Any RTMP or RTMPS server: paste its URL and stream key."),
    };

    public DestinationsPage()
    {
        InitializeComponent();
        _host.DestinationStatusChanged += _ => DispatcherQueue.TryEnqueue(Rebuild);
        _host.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(EngineHost.IsLive)) Rebuild();
        };
        Loaded += (_, _) => Rebuild();
    }

    private void Rebuild()
    {
        List.Children.Clear();
        foreach (var d in _host.Settings.Destinations)
            List.Children.Add(MakeRow(d));
        Empty.Visibility = _host.Settings.Destinations.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private UIElement MakeRow(DestinationInfo d)
    {
        var status = _host.StatusOf(d.Id);
        var card = new Border { Style = (Style)Application.Current.Resources["CardStyle"], Padding = new Thickness(16, 12, 16, 12) };
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        // Platform badge: a coloured initial (no platform logos are bundled).
        var badge = new Border
        {
            Width = 36, Height = 36, CornerRadius = new CornerRadius(18),
            Background = new SolidColorBrush(PlatformColor(d.Platform)),
            Child = new TextBlock
            {
                Text = d.Platform == Platform.Custom ? "R" : d.Platform.ToString()[..1],
                Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
        grid.Children.Add(badge);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = d.Name, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        string canvas = d.Canvas == 1 ? "9:16" : "16:9";
        var (stateText, brushKey) = status.State switch
        {
            Native.OutputState.Connecting => ("Connecting…", "TextFillColorSecondaryBrush"),
            Native.OutputState.Live => ("Live", "SystemFillColorSuccessBrush"),
            Native.OutputState.Reconnecting => ("Reconnecting…", "SystemFillColorCautionBrush"),
            Native.OutputState.Failed => ("Stopped: " + status.Message, "SystemFillColorCriticalBrush"),
            _ => (Credentials.Read(Credentials.StreamKeyName(d.Id)) is { Length: > 0 } ? "Ready" : "No stream key",
                  "TextFillColorSecondaryBrush"),
        };
        text.Children.Add(new TextBlock
        {
            Text = $"{canvas} · {stateText}",
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources[brushKey],
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var toggle = new ToggleSwitch { IsOn = d.Enabled, OnContent = "", OffContent = "", MinWidth = 0, IsEnabled = !_host.IsLive };
        AutomationProperties.SetName(toggle, $"Stream to {d.Name}");
        toggle.Toggled += (_, _) => { d.Enabled = toggle.IsOn; _host.Settings.Save(); };
        Grid.SetColumn(toggle, 2);
        grid.Children.Add(toggle);

        var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 14 }, IsEnabled = !_host.IsLive };
        AutomationProperties.SetName(more, $"More options for {d.Name}");
        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit", Icon = new FontIcon { Glyph = "\uE70F" } };
        edit.Click += async (_, _) => await OpenEditor(d);
        var remove = new MenuFlyoutItem { Text = "Remove", Icon = new FontIcon { Glyph = "\uE74D" } };
        remove.Click += (_, _) =>
        {
            _host.Settings.Destinations.Remove(d);
            Credentials.Delete(Credentials.StreamKeyName(d.Id));
            _host.Settings.Save();
            Rebuild();
        };
        menu.Items.Add(edit);
        menu.Items.Add(remove);
        more.Flyout = menu;
        Grid.SetColumn(more, 3);
        grid.Children.Add(more);

        card.Child = grid;
        return card;
    }

    private static Windows.UI.Color PlatformColor(Platform p) => p switch
    {
        Platform.YouTube => Windows.UI.Color.FromArgb(255, 0xCC, 0x00, 0x00),
        Platform.Twitch => Windows.UI.Color.FromArgb(255, 0x91, 0x46, 0xFF),
        Platform.Kick => Windows.UI.Color.FromArgb(255, 0x2E, 0x9E, 0x2E),
        Platform.TikTok => Windows.UI.Color.FromArgb(255, 0x20, 0x20, 0x20),
        Platform.Instagram => Windows.UI.Color.FromArgb(255, 0xC1, 0x35, 0x84),
        _ => Windows.UI.Color.FromArgb(255, 0x60, 0x60, 0x60),
    };

    // ---------------------------------------------------------------- editor

    private async void Add_Click(object sender, RoutedEventArgs e) => await OpenEditor(null);

    private async System.Threading.Tasks.Task OpenEditor(DestinationInfo? d)
    {
        _editing = d;
        Editor.Title = d == null ? "Add destination" : "Edit destination";
        _platformChangedByUser = false;
        PlatformBox.SelectedIndex = (int)(d?.Platform ?? Platform.YouTube);
        NameBox.Text = d?.Name ?? Platforms[PlatformBox.SelectedIndex].P.ToString();
        ServerBox.Text = d?.Server ?? Platforms[PlatformBox.SelectedIndex].Server;
        KeyBox.Password = d == null ? "" : Credentials.Read(Credentials.StreamKeyName(d.Id)) ?? "";
        CanvasBox.SelectedIndex = d?.Canvas ?? Platforms[PlatformBox.SelectedIndex].Canvas;
        HelpText.Text = Platforms[PlatformBox.SelectedIndex].Help;
        EditorError.Visibility = Visibility.Collapsed;
        _platformChangedByUser = true;
        Editor.XamlRoot = XamlRoot;
        await Editor.ShowAsync();
    }

    private void Platform_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (PlatformBox.SelectedIndex < 0) return;
        var p = Platforms[PlatformBox.SelectedIndex];
        HelpText.Text = p.Help;
        if (!_platformChangedByUser) return;
        // Fill in what the platform decides; keep what the user typed otherwise.
        if (string.IsNullOrWhiteSpace(NameBox.Text) || Platforms.Any(x => x.P.ToString() == NameBox.Text))
            NameBox.Text = p.P == Platform.Custom ? "" : p.P.ToString();
        if (string.IsNullOrWhiteSpace(ServerBox.Text) || Platforms.Any(x => x.Server.Length > 0 && x.Server == ServerBox.Text))
            ServerBox.Text = p.Server;
        CanvasBox.SelectedIndex = p.Canvas;
    }

    private void Editor_Save(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        string server = ServerBox.Text.Trim();
        string error = NameBox.Text.Trim().Length == 0 ? "Give it a name."
            : !(server.StartsWith("rtmp://", StringComparison.OrdinalIgnoreCase) || server.StartsWith("rtmps://", StringComparison.OrdinalIgnoreCase))
                ? "The server should start with rtmp:// or rtmps://."
            : KeyBox.Password.Trim().Length == 0 ? "Paste the stream key."
            : "";
        if (error.Length > 0)
        {
            EditorError.Text = error;
            EditorError.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }

        var d = _editing ?? new DestinationInfo();
        d.Platform = Platforms[Math.Max(0, PlatformBox.SelectedIndex)].P;
        d.Name = NameBox.Text.Trim();
        d.Server = server;
        d.Canvas = Math.Max(0, CanvasBox.SelectedIndex);
        try
        {
            Credentials.Write(Credentials.StreamKeyName(d.Id), KeyBox.Password.Trim());
        }
        catch (Exception ex)
        {
            EditorError.Text = ex.Message;
            EditorError.Visibility = Visibility.Visible;
            args.Cancel = true;
            return;
        }
        KeyBox.Password = "";
        if (_editing == null)
            _host.Settings.Destinations.Add(d);
        _host.Settings.Save();
        Rebuild();
    }
}
