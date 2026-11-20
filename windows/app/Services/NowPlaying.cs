using System;
using System.Linq;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using Windows.Media.Control;
using Windows.Storage.Streams;

namespace OmniCast.Services;

public sealed record Track(string Id, string Title, string Artist, bool Playing, IRandomAccessStreamReference? Art);

// What the chosen music app is playing, from Windows' media controls (the
// same info as the volume flyout): no sign-in, no API key. Spotify is found
// by its app id; [untitled] has no Windows app, so it's whichever browser tab
// is playing.
public sealed class NowPlaying
{
    public static NowPlaying Current { get; } = new();

    private static readonly string[] Browsers = { "chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "arc" };

    private GlobalSystemMediaTransportControlsSessionManager? _mgr;
    private GlobalSystemMediaTransportControlsSession? _session;
    private DispatcherQueue? _ui;

    public Track? Track { get; private set; }
    public event Action<Track?>? Changed;

    public string Source { get; private set; } = "spotify";

    public static bool IsSpotify(string aumid) => aumid.Contains("spotify", StringComparison.OrdinalIgnoreCase);
    public static bool IsBrowser(string aumid) => Browsers.Any(b => aumid.Contains(b, StringComparison.OrdinalIgnoreCase));

    public async Task StartAsync(string source)
    {
        _ui ??= DispatcherQueue.GetForCurrentThread();
        Source = source;
        try
        {
            _mgr ??= await GlobalSystemMediaTransportControlsSessionManager.RequestAsync();
            _mgr.SessionsChanged -= OnSessionsChanged;
            _mgr.SessionsChanged += OnSessionsChanged;
        }
        catch (Exception)
        {
            _mgr = null; // media controls unavailable: no card
        }
        PickSession();
    }

    public void SetSource(string source)
    {
        Source = source;
        PickSession();
    }

    private void OnSessionsChanged(GlobalSystemMediaTransportControlsSessionManager sender, SessionsChangedEventArgs args) =>
        _ui?.TryEnqueue(PickSession);

    private void PickSession()
    {
        var sessions = _mgr?.GetSessions().ToList() ?? new();
        bool Match(GlobalSystemMediaTransportControlsSession s) =>
            Source == "untitled" ? IsBrowser(s.SourceAppUserModelId) : IsSpotify(s.SourceAppUserModelId);
        // Prefer a playing session of the app.
        var pick = sessions.Where(Match)
            .OrderByDescending(s => s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing)
            .FirstOrDefault();
        if (_session != null && (pick == null || _session.SourceAppUserModelId != pick.SourceAppUserModelId))
        {
            _session.MediaPropertiesChanged -= OnMediaChanged;
            _session.PlaybackInfoChanged -= OnPlaybackChanged;
        }
        bool same = _session != null && pick != null && _session.SourceAppUserModelId == pick.SourceAppUserModelId;
        _session = pick;
        if (pick != null && !same)
        {
            pick.MediaPropertiesChanged += OnMediaChanged;
            pick.PlaybackInfoChanged += OnPlaybackChanged;
        }
        _ = ReadAsync();
    }

    private void OnMediaChanged(GlobalSystemMediaTransportControlsSession s, MediaPropertiesChangedEventArgs a) => _ui?.TryEnqueue(() => _ = ReadAsync());
    private void OnPlaybackChanged(GlobalSystemMediaTransportControlsSession s, PlaybackInfoChangedEventArgs a) => _ui?.TryEnqueue(() => _ = ReadAsync());

    private async Task ReadAsync()
    {
        var s = _session;
        Track? t = null;
        if (s != null)
        {
            try
            {
                var props = await s.TryGetMediaPropertiesAsync();
                bool playing = s.GetPlaybackInfo()?.PlaybackStatus == GlobalSystemMediaTransportControlsSessionPlaybackStatus.Playing;
                if (props != null && props.Title.Length > 0)
                    t = new Track($"{props.Title}|{props.Artist}", props.Title, props.Artist, playing, props.Thumbnail);
            }
            catch (Exception) { }
        }
        if (s != _session) return; // switched meanwhile
        bool changed = t?.Id != Track?.Id || t?.Playing != Track?.Playing;
        Track = t;
        if (changed) Changed?.Invoke(t);
    }
}
