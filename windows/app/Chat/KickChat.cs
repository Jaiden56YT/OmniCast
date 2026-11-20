using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OmniCast.Chat;

// Kick chat, read the way kick.com's own web page does (unofficial): a guest
// token for Kick's Centrifugo chat server, then the chatroom's channel.
public sealed partial class KickChat
{
    private readonly string _slug;
    private readonly long? _chatroomOverride;
    private readonly HttpClient _http;
    private readonly Action<ChatMessage> _onMessage;
    private readonly Action<ChatStatus> _onStatus;

    public KickChat(string channel, long? chatroom, HttpClient http, Action<ChatMessage> onMessage, Action<ChatStatus> onStatus)
    {
        _slug = new string(channel.Trim().ToLowerInvariant().Where(c => c != '@' && !char.IsWhiteSpace(c)).ToArray());
        _chatroomOverride = chatroom;
        _http = http;
        _onMessage = onMessage;
        _onStatus = onStatus;
    }

    private sealed class Fatal : Exception
    {
        public Fatal(string message) : base(message) { }
    }

    public async Task RunAsync(CancellationToken ct)
    {
        _onStatus(new ChatStatus(ChatState.Connecting));
        long chatroom, channel;
        try
        {
            (chatroom, channel) = await LookupAsync(ct);
        }
        catch (Fatal f)
        {
            _onStatus(new ChatStatus(ChatState.Failed, f.Message));
            return;
        }
        catch (OperationCanceledException) { return; }
        catch (Exception)
        {
            _onStatus(new ChatStatus(ChatState.Failed, "Couldn't reach Kick"));
            return;
        }

        var delay = TimeSpan.FromSeconds(2);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (await SessionAsync(chatroom, channel, ct))
                    delay = TimeSpan.FromSeconds(2);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception) { }
            if (ct.IsCancellationRequested) return;
            _onStatus(new ChatStatus(ChatState.Connecting, "Reconnecting to Kick…"));
            try { await Task.Delay(delay, ct); } catch (OperationCanceledException) { return; }
            delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 60));
        }
    }

    private async Task<(long Chatroom, long Channel)> LookupAsync(CancellationToken ct)
    {
        if (_chatroomOverride is long id)
            return (id, id);
        using var req = new HttpRequestMessage(HttpMethod.Get, $"https://kick.com/api/v2/channels/{Uri.EscapeDataString(_slug)}");
        req.Headers.Accept.ParseAdd("application/json");
        using var res = await _http.SendAsync(req, ct);
        if (res.StatusCode == HttpStatusCode.NotFound)
            throw new Fatal("Kick channel not found");
        if (!res.IsSuccessStatusCode)
            throw new Fatal($"Kick blocked the lookup ({(int)res.StatusCode}). Paste the chatroom ID in Settings.");
        string body = await res.Content.ReadAsStringAsync(ct);
        JsonDocument doc;
        try { doc = JsonDocument.Parse(body); }
        catch (JsonException)
        {
            // Kick's JSON sometimes carries raw control characters.
            doc = JsonDocument.Parse(new string(body.Where(c => c >= 0x20 || c == '\n').ToArray()));
        }
        using (doc)
        {
            var root = doc.RootElement;
            if (!root.TryGetProperty("chatroom", out var room) || !room.TryGetProperty("id", out var rid))
                throw new Fatal($"Kick blocked the lookup. Paste the chatroom ID in Settings.");
            long channel = root.TryGetProperty("id", out var cid) ? cid.GetInt64() : rid.GetInt64();
            return (rid.GetInt64(), channel);
        }
    }

    // One connection. Returns true once it was subscribed (so the backoff resets).
    private async Task<bool> SessionAsync(long chatroom, long channel, CancellationToken ct)
    {
        string client = Guid.NewGuid().ToString().ToLowerInvariant();
        string url = "wss://realtime.us-east-1.platform.kick.com/connection/websocket";
        string conn = $$$"""{"client":{"id":"{{{client}}}","type":"web"},"capabilities":{"accepted_providers":[{"provider":"centrifugo"}]}}""";
        using (var r = await PostJsonAsync($"https://web.kick.com/api/v1/realtime/channels/{channel}/chat/connection", conn, ct))
        {
            if (r != null && r.RootElement.TryGetProperty("data", out var data) && data.TryGetProperty("connections", out var cs))
                foreach (var c in cs.EnumerateArray())
                    if (c.TryGetProperty("provider", out var p) && p.GetString() == "centrifugo" &&
                        c.TryGetProperty("credentials", out var cred) && cred.TryGetProperty("url", out var u) && u.GetString() is { Length: > 0 } s)
                        url = s;
        }
        string? token = null;
        using (var r = await PostJsonAsync("https://web.kick.com/api/v1/realtime/auth/connection", $$$"""{"client_id":"{{{client}}}"}""", ct))
            if (r != null && r.RootElement.TryGetProperty("data", out var data) && data.TryGetProperty("token", out var t))
                token = t.GetString();
        if (string.IsNullOrEmpty(token))
        {
            _onStatus(new ChatStatus(ChatState.Failed, "Kick didn't hand out a chat token"));
            return false;
        }

        using var ws = new ClientWebSocket();
        ws.Options.SetRequestHeader("User-Agent", ChatPlatforms.UserAgent);
        ws.Options.SetRequestHeader("Origin", "https://kick.com");
        await ws.ConnectAsync(new Uri(url), ct);
        await SendAsync(ws, $$$"""{"id":1,"connect":{"token":"{{{token}}}","name":"js"}}""", ct);
        await SendAsync(ws, $$$"""{"id":2,"subscribe":{"channel":"chatrooms.{{{chatroom}}}.v2"}}""", ct);

        bool subscribed = false;
        DateTime? renewAt = null;
        var buf = new byte[65536];
        var text = new StringBuilder();
        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            if (renewAt is DateTime when && DateTime.UtcNow >= when)
                return subscribed; // a fresh token before this one runs out
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(60));
            var r = await ws.ReceiveAsync(buf, timeout.Token);
            if (r.MessageType == WebSocketMessageType.Close) break;
            text.Append(Encoding.UTF8.GetString(buf, 0, r.Count));
            if (!r.EndOfMessage) continue;
            foreach (var frame in text.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries))
            {
                if (frame.Trim() == "{}")
                {
                    await SendAsync(ws, "{}", ct); // ping
                    continue;
                }
                using var doc = JsonDocument.Parse(frame);
                var root = doc.RootElement;
                if (root.TryGetProperty("error", out _))
                {
                    _onStatus(new ChatStatus(ChatState.Failed, "Kick chat refused the connection"));
                    return subscribed;
                }
                if (root.TryGetProperty("connect", out var c) && c.TryGetProperty("ttl", out var ttl) && ttl.GetInt32() > 120)
                    renewAt = DateTime.UtcNow.AddSeconds(ttl.GetInt32() - 60);
                if (root.TryGetProperty("subscribe", out _) && root.TryGetProperty("id", out var id) && id.GetInt32() == 2)
                {
                    subscribed = true;
                    _onStatus(new ChatStatus(ChatState.Connected));
                }
                if (root.TryGetProperty("push", out var push) && push.TryGetProperty("pub", out var pub) && pub.TryGetProperty("data", out var data))
                    HandleEvent(data);
            }
            text.Clear();
        }
        return subscribed;
    }

    private void HandleEvent(JsonElement data)
    {
        if (!data.TryGetProperty("event", out var ev) || ev.GetString() != "App\\Events\\ChatMessageEvent") return;
        if (!data.TryGetProperty("data", out var inner) || inner.ValueKind != JsonValueKind.String) return;
        using var doc = JsonDocument.Parse(inner.GetString() ?? "{}");
        var m = doc.RootElement;
        var sender = m.TryGetProperty("sender", out var s) ? s : default;
        string author = sender.ValueKind == JsonValueKind.Object && sender.TryGetProperty("username", out var u) ? u.GetString() ?? "" : "";
        string? color = null;
        var badges = new List<ChatBadge>();
        if (sender.ValueKind == JsonValueKind.Object && sender.TryGetProperty("identity", out var idn))
        {
            if (idn.TryGetProperty("color", out var col) && col.GetString() is { Length: > 0 } cs) color = cs;
            if (idn.TryGetProperty("badges", out var bs) && bs.ValueKind == JsonValueKind.Array)
                foreach (var b in bs.EnumerateArray())
                {
                    ChatBadge? mapped = (b.TryGetProperty("type", out var t) ? t.GetString() : "") switch
                    {
                        "broadcaster" => ChatBadge.Owner,
                        "moderator" => ChatBadge.Moderator,
                        "vip" => ChatBadge.Vip,
                        "subscriber" or "founder" or "og" => ChatBadge.Member,
                        "verified" => ChatBadge.Verified,
                        _ => null,
                    };
                    if (mapped is ChatBadge mb && !badges.Contains(mb)) badges.Add(mb);
                }
        }
        string content = m.TryGetProperty("content", out var ct2) ? ct2.GetString() ?? "" : "";
        _onMessage(new ChatMessage
        {
            Id = m.TryGetProperty("id", out var mid) ? mid.ToString() : Guid.NewGuid().ToString(),
            Platform = ChatPlatform.Kick,
            Author = author,
            Color = color,
            Badges = badges,
            Parts = Parts(content),
        });
    }

    [GeneratedRegex(@"\[emote:(\d+):([^\]]*)\]")]
    private static partial Regex EmoteRx();

    private static List<ChatPart> Parts(string content)
    {
        var parts = new List<ChatPart>();
        int pos = 0;
        foreach (Match m in EmoteRx().Matches(content))
        {
            if (m.Index > pos) parts.Add(new ChatPart(content[pos..m.Index]));
            parts.Add(new ChatPart(m.Groups[2].Value, $"https://files.kick.com/emotes/{m.Groups[1].Value}/fullsize"));
            pos = m.Index + m.Length;
        }
        if (pos < content.Length) parts.Add(new ChatPart(content[pos..]));
        return parts;
    }

    private async Task<JsonDocument?> PostJsonAsync(string url, string json, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        req.Headers.Accept.ParseAdd("application/json");
        using var res = await _http.SendAsync(req, ct);
        if (!res.IsSuccessStatusCode) return null;
        try { return JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct)); }
        catch (JsonException) { return null; }
    }

    private static Task SendAsync(ClientWebSocket ws, string json, CancellationToken ct) =>
        ws.SendAsync(Encoding.UTF8.GetBytes(json), WebSocketMessageType.Text, true, ct);
}
