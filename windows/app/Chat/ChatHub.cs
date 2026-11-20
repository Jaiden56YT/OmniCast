using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Chat;

// Reads Twitch, Kick and YouTube chat at once and merges them, newest last
// (the 50 newest are kept). Read only: nothing is ever posted.
public sealed class ChatHub
{
    public static ChatHub Current { get; } = new();

    public const int MaxMessages = 50;

    private readonly List<ChatMessage> _messages = new();
    private readonly HashSet<(ChatPlatform, string)> _ids = new();
    private readonly Dictionary<ChatPlatform, ChatStatus> _status = new();
    private CancellationTokenSource? _cts;
    private DispatcherQueue? _ui;

    public static readonly HttpClient Http = CreateHttp();

    public IReadOnlyList<ChatMessage> Messages => _messages;
    public event Action? MessagesChanged;
    public event Action? StatusChanged;

    private static HttpClient CreateHttp()
    {
        // Cookies are sent by hand (YouTube's consent cookie), so the handler mustn't manage them.
        var handler = new SocketsHttpHandler { UseCookies = false, AutomaticDecompression = DecompressionMethods.All };
        var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd(ChatPlatforms.UserAgent);
        return http;
    }

    public ChatStatus StatusOf(ChatPlatform p) => _status.TryGetValue(p, out var s) ? s : ChatStatus.Off;

    // "Twitch, Kick · YouTube waiting for live", or "Not connected".
    public string Summary
    {
        get
        {
            var all = Enum.GetValues<ChatPlatform>();
            var connected = all.Where(p => StatusOf(p).State == ChatState.Connected).Select(ChatPlatforms.Name).ToList();
            var parts = new List<string>();
            if (connected.Count > 0) parts.Add(string.Join(", ", connected));
            parts.AddRange(all.Where(p => StatusOf(p).State == ChatState.WaitingForLive).Select(p => $"{ChatPlatforms.Name(p)} waiting for live"));
            parts.AddRange(all.Where(p => StatusOf(p).State == ChatState.Failed).Select(p => $"{ChatPlatforms.Name(p)} failed"));
            return parts.Count > 0 ? string.Join(" · ", parts) : "Not connected";
        }
    }

    public bool AnyConnected => Enum.GetValues<ChatPlatform>().Any(p => StatusOf(p).State == ChatState.Connected);

    // (Re)starts every reader from the saved settings.
    public void Restart()
    {
        _ui ??= DispatcherQueue.GetForCurrentThread();
        _cts?.Cancel();
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        var s = EngineHost.Current.Settings.Chat;
        _status.Clear();
        bool On(string key) => s.Enabled.Contains(key);

        if (On("twitch") && TwitchChat.Normalize(s.Twitch).Length > 0)
            _ = Task.Run(() => new TwitchChat(s.Twitch, Add, st => SetStatus(ChatPlatform.Twitch, st)).RunAsync(ct));
        if (On("kick") && (s.Kick.Trim().Length > 0 || s.KickChatroom != null))
            _ = Task.Run(() => new KickChat(s.Kick, s.KickChatroom, Http, Add, st => SetStatus(ChatPlatform.Kick, st)).RunAsync(ct));
        if (On("youtube") && YouTubeChat.Normalize(s.YouTube).Length > 0)
            _ = Task.Run(() => new YouTubeChat(s.YouTube, Http, Add, st => SetStatus(ChatPlatform.YouTube, st)).RunAsync(ct));
        StatusChanged?.Invoke();
    }

    public void Stop()
    {
        _cts?.Cancel();
        _cts = null;
    }

    private void SetStatus(ChatPlatform p, ChatStatus s) => _ui?.TryEnqueue(() =>
    {
        _status[p] = s;
        StatusChanged?.Invoke();
    });

    private void Add(ChatMessage m) => _ui?.TryEnqueue(() => AddOnUi(m));

    private void AddOnUi(ChatMessage m)
    {
        if (!_ids.Add((m.Platform, m.Id))) return;
        _messages.Add(m);
        while (_messages.Count > MaxMessages)
        {
            var old = _messages[0];
            _messages.RemoveAt(0);
            _ids.Remove((old.Platform, old.Id));
        }
        MessagesChanged?.Invoke();
    }

    public void Clear()
    {
        _messages.Clear();
        _ids.Clear();
        MessagesChanged?.Invoke();
    }

    // Sample lines, to see the look and placement without being live.
    public void AddTestMessages()
    {
        _ui ??= DispatcherQueue.GetForCurrentThread();
        var samples = new (ChatPlatform P, string Author, string? Color, ChatBadge? Badge, string Text)[]
        {
            (ChatPlatform.YouTube, "deku_vt", null, null, "eepers time"),
            (ChatPlatform.Twitch, "Mr_Seasalt", "#FF4F9A", ChatBadge.Member, "It's been 9 hours and 20 minutes 😭"),
            (ChatPlatform.Kick, "ItsSoraval", "#53FC18", null, "I DONT HAVE THAT DUDE"),
            (ChatPlatform.YouTube, "BrandonSaber", null, ChatBadge.Moderator, "wait you mean 1400 right?"),
            (ChatPlatform.Twitch, "T3mpex", "#9B7BFF", ChatBadge.Vip, "I gotta see the concept skins before I attempt getting this token"),
            (ChatPlatform.YouTube, "YourChannel", null, ChatBadge.Owner, "yo welcome in everybody"),
        };
        foreach (var s in samples)
            AddOnUi(new ChatMessage
            {
                Id = Guid.NewGuid().ToString(),
                Platform = s.P,
                Author = s.Author,
                Color = s.Color,
                Badges = s.Badge is ChatBadge b ? new() { b } : new(),
                Parts = new() { new ChatPart(s.Text) },
            });
    }
}
