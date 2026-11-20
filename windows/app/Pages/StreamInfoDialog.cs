using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OmniCast.Accounts;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Pages;

// Sets the stream title on every connected platform at once, and the game on
// Twitch and Kick. YouTube's category can't be set through its API.
public sealed class StreamInfoDialog
{
    private readonly ContentDialog _d = new();
    public Windows.Foundation.IAsyncOperation<ContentDialogResult> ShowAsync() => _d.ShowAsync();

    private readonly TextBox _title = new() { PlaceholderText = "What are you streaming?", AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, MaxLength = 140 };
    private readonly TextBlock _count = new() { Style = Res<Style>("CaptionTextBlockStyle"), Opacity = 0.7 };
    private readonly Dictionary<string, CheckBox> _on = new();
    private readonly Dictionary<string, TextBlock> _result = new();
    private readonly GamePicker _twitch = new(StreamAccounts.Twitch), _kick = new(StreamAccounts.Kick);
    private static T? Res<T>(string key) where T : class =>
        Application.Current.Resources.TryGetValue(key, out var v) ? v as T : null;

    private static StreamInfoSettings S => EngineHost.Current.Settings.StreamInfo;

    public StreamInfoDialog(XamlRoot xamlRoot)
    {
        _d.XamlRoot = xamlRoot;
        _d.Title = "Stream info";
        _d.PrimaryButtonText = "Update";
        _d.CloseButtonText = "Close";
        _d.DefaultButton = ContentDialogButton.Primary;
        var connected = StreamAccounts.All.Where(a => a.Connected).ToList();
        _d.IsPrimaryButtonEnabled = connected.Count > 0;

        var root = new StackPanel { Spacing = 12, MinWidth = 480 };
        if (connected.Count == 0)
            root.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Title = "Connect your accounts first", Message = "Settings › Accounts has the steps for Twitch, Kick and YouTube." });

        root.Children.Add(new TextBlock { Text = "Title", Style = Res<Style>("BodyStrongTextBlockStyle") });
        _title.Text = S.Title;
        _title.TextChanged += (_, _) => UpdateCount();
        root.Children.Add(_title);
        var toggles = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        foreach (var a in StreamAccounts.All)
        {
            var cb = new CheckBox { Content = a.Name, IsChecked = S.TitleOn.Contains(a.Key), IsEnabled = a.Connected };
            if (!a.Connected) ToolTipService.SetToolTip(cb, $"Connect {a.Name} in Settings › Accounts");
            _on[a.Key] = cb;
            toggles.Children.Add(cb);
        }
        toggles.Children.Add(_count);
        root.Children.Add(toggles);
        UpdateCount();

        var games = new Grid { ColumnSpacing = 16 };
        games.ColumnDefinitions.Add(new ColumnDefinition());
        games.ColumnDefinitions.Add(new ColumnDefinition());
        games.Children.Add(_twitch.View("Twitch game", S.TwitchGame));
        var kickView = _kick.View("Kick game", S.KickGame);
        Grid.SetColumn(kickView, 1);
        games.Children.Add(kickView);
        root.Children.Add(games);

        foreach (var a in StreamAccounts.All.Where(a => a.Connected))
        {
            var t = new TextBlock { Style = Res<Style>("CaptionTextBlockStyle"), TextWrapping = TextWrapping.Wrap };
            _result[a.Key] = t;
            root.Children.Add(t);
        }
        _d.Content = root;
        _d.PrimaryButtonClick += OnUpdate;
        _d.Opened += async (_, _) => await LoadCurrentAsync();
    }

    private void UpdateCount()
    {
        int n = _title.Text.Trim().Length;
        _count.Text = $"{n} characters";
        ToolTipService.SetToolTip(_count, "YouTube allows 100 characters, Twitch 140");
        if (n > 100 && Res<Microsoft.UI.Xaml.Media.Brush>("SystemFillColorCautionBrush") is { } warn) _count.Foreground = warn;
        else _count.ClearValue(TextBlock.ForegroundProperty);
    }

    // The current title (Twitch, then Kick, then YouTube) and games.
    private async Task LoadCurrentAsync()
    {
        string? title = null;
        foreach (var a in new StreamAccount[] { StreamAccounts.Twitch, StreamAccounts.Kick, StreamAccounts.YouTube }.Where(a => a.Connected))
        {
            try
            {
                var info = await a.GetAsync(default);
                if (title == null && info.Title.Length > 0) title = info.Title;
                if (info.Game != null && a == StreamAccounts.Twitch) _twitch.Set(info.Game);
                if (info.Game != null && a == StreamAccounts.Kick) _kick.Set(info.Game);
            }
            catch (Exception ex)
            {
                if (_result.TryGetValue(a.Key, out var r)) r.Text = $"{a.Name}: {ex.Message}";
            }
        }
        if (title != null && _title.Text.Length == 0) _title.Text = title;
    }

    private async void OnUpdate(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true; // stay open to show how each platform went
        var deferral = args.GetDeferral();
        _d.IsPrimaryButtonEnabled = false;
        string title = _title.Text.Trim();
        S.Title = title;
        S.TitleOn = _on.Where(kv => kv.Value.IsChecked == true).Select(kv => kv.Key).ToList();
        S.TwitchGame = _twitch.Saved;
        S.KickGame = _kick.Saved;
        EngineHost.Current.Settings.Save();

        var jobs = StreamAccounts.All.Where(a => a.Connected).Select(async a =>
        {
            string? t = S.TitleOn.Contains(a.Key) && title.Length > 0 ? title : null;
            Category? game = a == StreamAccounts.Twitch ? _twitch.Picked : a == StreamAccounts.Kick ? _kick.Picked : null;
            var r = _result[a.Key];
            if (t == null && game == null) { r.Text = $"{a.Name}: nothing to change"; return; }
            r.Text = $"{a.Name}: updating…";
            try
            {
                await a.UpdateAsync(t, game, default);
                r.Text = $"✓ {a.Name}: updated";
            }
            catch (Exception ex)
            {
                r.Text = $"⚠ {a.Name}: {ex.Message}";
            }
        });
        await Task.WhenAll(jobs);
        _d.IsPrimaryButtonEnabled = true;
        deferral.Complete();
    }

    // A game search box with the current pick.
    private sealed class GamePicker
    {
        private readonly StreamAccount _account;
        private readonly AutoSuggestBox _box = new() { QueryIcon = new SymbolIcon(Symbol.Find) };
        private CancellationTokenSource? _search;
        public Category? Picked { get; private set; }

        public GamePicker(StreamAccount account) => _account = account;

        public SavedCategory? Saved => Picked == null ? null : new SavedCategory { Id = Picked.Id, Name = Picked.Name, Image = Picked.Image };

        public void Set(Category c)
        {
            Picked = c;
            _box.Text = c.Name;
        }

        public FrameworkElement View(string header, SavedCategory? saved)
        {
            _box.Header = header;
            _box.PlaceholderText = _account.Connected ? $"Search {_account.Name} games" : $"Connect {_account.Name} first";
            _box.IsEnabled = _account.Connected;
            _box.DisplayMemberPath = "Name";
            if (saved != null) Set(new Category(saved.Id, saved.Name, saved.Image));
            _box.TextChanged += async (s, e) =>
            {
                if (e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
                _search?.Cancel();
                var cts = _search = new CancellationTokenSource();
                string q = s.Text.Trim();
                if (q.Length < 2) { s.ItemsSource = null; return; }
                try
                {
                    await Task.Delay(300, cts.Token); // wait for typing to pause
                    s.ItemsSource = await _account.SearchAsync(q, cts.Token);
                }
                catch (OperationCanceledException) { }
                catch (Exception) { s.ItemsSource = null; }
            };
            _box.SuggestionChosen += (s, e) => { if (e.SelectedItem is Category c) Set(c); };
            return _box;
        }
    }
}
