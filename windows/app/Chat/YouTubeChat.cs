using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace OmniCast.Chat;

// YouTube live chat, read the way youtube.com's own chat window does
// (unofficial, no API key or quota): find the channel's live video, open its
// chat page for a continuation token, then poll get_live_chat.
public sealed partial class YouTubeChat
{
    private readonly string _handle;
    private readonly HttpClient _http;
    private readonly Action<ChatMessage> _onMessage;
    private readonly Action<ChatStatus> _onStatus;
    private readonly HashSet<string> _seen = new();

    public YouTubeChat(string handle, HttpClient http, Action<ChatMessage> onMessage, Action<ChatStatus> onStatus)
    {
        _handle = Normalize(handle);
        _http = http;
        _onMessage = onMessage;
        _onStatus = onStatus;
    }

    public static string Normalize(string handle)
    {
        string h = handle.Trim();
        int i = h.IndexOf("youtube.com/", StringComparison.OrdinalIgnoreCase);
        if (i >= 0) h = h[(i + "youtube.com/".Length)..];
        return h.Trim('/').TrimStart('@').Split('/')[0];
    }

    [GeneratedRegex(@"<link rel=""canonical"" href=""https://www\.youtube\.com/watch\?v=([\w-]{11})""")]
    private static partial Regex CanonicalRx();
    [GeneratedRegex(@"""INNERTUBE_CLIENT_VERSION"":""([^""]+)""")]
    private static partial Regex VersionRx();
    [GeneratedRegex(@"""continuation"":""([^""]+)""")]
    private static partial Regex ContinuationRx();
    [GeneratedRegex(@"""INNERTUBE_API_KEY"":""([^""]+)""")]
    private static partial Regex KeyRx();

    public async Task RunAsync(CancellationToken ct)
    {
        _onStatus(new ChatStatus(ChatState.Connecting));
        while (!ct.IsCancellationRequested)
        {
            TimeSpan wait;
            try
            {
                wait = await OnceAsync(ct);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception)
            {
                _onStatus(new ChatStatus(ChatState.Failed, "Couldn't reach YouTube"));
                wait = TimeSpan.FromSeconds(30);
            }
            try { await Task.Delay(wait, ct); } catch (OperationCanceledException) { return; }
        }
    }

    // Finds the live stream and reads its chat until it ends. Returns how long to wait before trying again.
    private async Task<TimeSpan> OnceAsync(CancellationToken ct)
    {
        string page = await GetAsync($"https://www.youtube.com/@{Uri.EscapeDataString(_handle)}/live", ct);
        if (page.Contains("This page isn't available") || page.Contains("404 Not Found"))
        {
            _onStatus(new ChatStatus(ChatState.Failed, $"YouTube channel @{_handle} not found"));
            return TimeSpan.FromSeconds(120);
        }
        var video = CanonicalRx().Match(page);
        if (!video.Success || !(page.Contains("\"isLiveNow\":true") || page.Contains("\"isLive\":true")))
        {
            _onStatus(new ChatStatus(ChatState.WaitingForLive));
            return TimeSpan.FromSeconds(30);
        }

        string chat = await GetAsync($"https://www.youtube.com/live_chat?is_popout=1&v={video.Groups[1].Value}", ct);
        var version = VersionRx().Match(chat);
        var cont = ContinuationRx().Match(chat);
        if (!version.Success || !cont.Success)
        {
            _onStatus(new ChatStatus(ChatState.Failed, "This stream's chat is off or unavailable"));
            return TimeSpan.FromSeconds(30);
        }
        var key = KeyRx().Match(chat);
        string url = "https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?prettyPrint=false" + (key.Success ? "&key=" + key.Groups[1].Value : "");
        string token = cont.Groups[1].Value;
        _onStatus(new ChatStatus(ChatState.Connected));

        while (!ct.IsCancellationRequested)
        {
            string body = $$$"""{"context":{"client":{"clientName":"WEB","clientVersion":"{{{version.Groups[1].Value}}}","hl":"en"}},"continuation":"{{{token}}}"}""";
            using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            AddHeaders(req);
            using var res = await _http.SendAsync(req, ct);
            using var doc = JsonDocument.Parse(await res.Content.ReadAsStringAsync(ct));
            if (!doc.RootElement.TryGetProperty("continuationContents", out var cc) ||
                !cc.TryGetProperty("liveChatContinuation", out var lcc))
                break;
            if (lcc.TryGetProperty("actions", out var actions))
                foreach (var a in actions.EnumerateArray())
                    HandleAction(a);
            double timeoutMs = 2000;
            string? next = null;
            if (lcc.TryGetProperty("continuations", out var conts) && conts.GetArrayLength() > 0)
                foreach (var prop in conts[0].EnumerateObject())
                {
                    if (prop.Value.TryGetProperty("continuation", out var c)) next = c.GetString();
                    if (prop.Value.TryGetProperty("timeoutMs", out var t)) timeoutMs = t.GetDouble();
                    break;
                }
            if (next == null) break;
            token = next;
            await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(timeoutMs / 1000, 1, 8)), ct);
        }
        _onStatus(new ChatStatus(ChatState.WaitingForLive)); // the stream ended
        return TimeSpan.FromSeconds(15);
    }

    private void HandleAction(JsonElement a)
    {
        if (!a.TryGetProperty("addChatItemAction", out var add) || !add.TryGetProperty("item", out var item)) return;
        bool paid = false;
        if (!item.TryGetProperty("liveChatTextMessageRenderer", out var r))
        {
            if (!item.TryGetProperty("liveChatPaidMessageRenderer", out r)) return;
            paid = true;
        }
        string id = r.TryGetProperty("id", out var idEl) ? idEl.GetString() ?? "" : "";
        if (id.Length > 0)
        {
            if (_seen.Count > 2000) _seen.Clear();
            if (!_seen.Add(id)) return;
        }
        string author = r.TryGetProperty("authorName", out var an) && an.TryGetProperty("simpleText", out var st) ? st.GetString() ?? "" : "";
        var parts = new List<ChatPart>();
        if (paid && r.TryGetProperty("purchaseAmountText", out var amt) && amt.TryGetProperty("simpleText", out var amtText))
            parts.Add(new ChatPart($"[{amtText.GetString()}] "));
        if (r.TryGetProperty("message", out var msg) && msg.TryGetProperty("runs", out var runs))
            foreach (var run in runs.EnumerateArray())
            {
                if (run.TryGetProperty("text", out var t))
                    parts.Add(new ChatPart(t.GetString() ?? ""));
                else if (run.TryGetProperty("emoji", out var e))
                {
                    string shortcut = e.TryGetProperty("shortcuts", out var sc) && sc.GetArrayLength() > 0 ? sc[0].GetString() ?? "" : "";
                    bool custom = e.TryGetProperty("isCustomEmoji", out var ic) && ic.ValueKind == JsonValueKind.True;
                    if (custom && e.TryGetProperty("image", out var img) && img.TryGetProperty("thumbnails", out var th) && th.GetArrayLength() > 0)
                        parts.Add(new ChatPart(shortcut, th[th.GetArrayLength() - 1].GetProperty("url").GetString()));
                    else
                        parts.Add(new ChatPart(e.TryGetProperty("emojiId", out var eid) && eid.GetString() is { Length: > 0 } s ? s : shortcut));
                }
            }
        var badges = new List<ChatBadge>();
        if (r.TryGetProperty("authorBadges", out var bs))
            foreach (var b in bs.EnumerateArray())
            {
                if (!b.TryGetProperty("liveChatAuthorBadgeRenderer", out var br)) continue;
                if (br.TryGetProperty("customThumbnail", out _)) { if (!badges.Contains(ChatBadge.Member)) badges.Add(ChatBadge.Member); continue; }
                string type = br.TryGetProperty("icon", out var icon) && icon.TryGetProperty("iconType", out var it) ? it.GetString() ?? "" : "";
                ChatBadge? mapped = type switch { "OWNER" => ChatBadge.Owner, "MODERATOR" => ChatBadge.Moderator, "VERIFIED" => ChatBadge.Verified, _ => null };
                if (mapped is ChatBadge m && !badges.Contains(m)) badges.Add(m);
            }
        _onMessage(new ChatMessage { Id = id.Length > 0 ? id : Guid.NewGuid().ToString(), Platform = ChatPlatform.YouTube, Author = author, Badges = badges, Parts = parts });
    }

    private async Task<string> GetAsync(string url, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        AddHeaders(req);
        using var res = await _http.SendAsync(req, ct);
        return await res.Content.ReadAsStringAsync(ct);
    }

    private static void AddHeaders(HttpRequestMessage req)
    {
        req.Headers.TryAddWithoutValidation("Accept-Language", "en-US,en;q=0.9");
        // Skips the EU cookie-consent page.
        req.Headers.TryAddWithoutValidation("Cookie", "CONSENT=YES+1; SOCS=CAI");
    }
}
