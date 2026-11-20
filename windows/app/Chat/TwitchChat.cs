using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace OmniCast.Chat;

// Twitch chat, read anonymously over IRC-over-WebSocket ("justinfan" login):
// no account, no API key.
public sealed class TwitchChat
{
    private readonly string _channel;
    private readonly Action<ChatMessage> _onMessage;
    private readonly Action<ChatStatus> _onStatus;

    public TwitchChat(string channel, Action<ChatMessage> onMessage, Action<ChatStatus> onStatus)
    {
        _channel = Normalize(channel);
        _onMessage = onMessage;
        _onStatus = onStatus;
    }

    public static string Normalize(string channel) =>
        new string(channel.Trim().ToLowerInvariant().Where(c => c != '#' && c != '@' && !char.IsWhiteSpace(c)).ToArray());

    public async Task RunAsync(CancellationToken ct)
    {
        var delay = TimeSpan.FromSeconds(2);
        _onStatus(new ChatStatus(ChatState.Connecting));
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var ws = new ClientWebSocket();
                await ws.ConnectAsync(new Uri("wss://irc-ws.chat.twitch.tv:443"), ct);
                int nick = Random.Shared.Next(10000, 100000);
                foreach (var line in new[] { "CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE", $"NICK justinfan{nick}", $"JOIN #{_channel}" })
                    await SendAsync(ws, line, ct);
                var buf = new byte[16384];
                var text = new StringBuilder();
                while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
                {
                    var r = await ws.ReceiveAsync(buf, ct);
                    if (r.MessageType == WebSocketMessageType.Close) break;
                    text.Append(Encoding.UTF8.GetString(buf, 0, r.Count));
                    if (!r.EndOfMessage) continue;
                    foreach (var line in text.ToString().Split("\r\n", StringSplitOptions.RemoveEmptyEntries))
                    {
                        if (line.StartsWith("PING", StringComparison.Ordinal))
                        {
                            await SendAsync(ws, "PONG" + line[4..], ct);
                            continue;
                        }
                        if (Handle(line))
                            delay = TimeSpan.FromSeconds(2);
                    }
                    text.Clear();
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception) { }
            if (ct.IsCancellationRequested) return;
            _onStatus(new ChatStatus(ChatState.Connecting, "Reconnecting to Twitch…"));
            try { await Task.Delay(delay, ct); } catch (OperationCanceledException) { return; }
            delay = TimeSpan.FromSeconds(Math.Min(delay.TotalSeconds * 2, 60));
        }
    }

    private static Task SendAsync(ClientWebSocket ws, string line, CancellationToken ct) =>
        ws.SendAsync(Encoding.UTF8.GetBytes(line), WebSocketMessageType.Text, true, ct);

    // Returns true when the line says we're in the channel.
    private bool Handle(string line)
    {
        var tags = new Dictionary<string, string>();
        string rest = line;
        if (rest.StartsWith('@'))
        {
            int sp = rest.IndexOf(' ');
            if (sp < 0) return false;
            foreach (var kv in rest[1..sp].Split(';'))
            {
                int eq = kv.IndexOf('=');
                if (eq > 0) tags[kv[..eq]] = Unescape(kv[(eq + 1)..]);
            }
            rest = rest[(sp + 1)..];
        }
        string prefix = "";
        if (rest.StartsWith(':'))
        {
            int sp = rest.IndexOf(' ');
            if (sp < 0) return false;
            prefix = rest[1..sp];
            rest = rest[(sp + 1)..];
        }
        int cmdEnd = rest.IndexOf(' ');
        string command = cmdEnd < 0 ? rest : rest[..cmdEnd];
        if (command is "ROOMSTATE" or "366")
        {
            _onStatus(new ChatStatus(ChatState.Connected));
            return true;
        }
        if (command != "PRIVMSG") return false;
        int colon = rest.IndexOf(" :", StringComparison.Ordinal);
        if (colon < 0) return false;
        string body = rest[(colon + 2)..];
        string login = prefix.Split('!')[0];

        var badges = new List<ChatBadge>();
        if (tags.TryGetValue("badges", out var b))
            foreach (var badge in b.Split(',', StringSplitOptions.RemoveEmptyEntries))
            {
                string name = badge.Split('/')[0];
                ChatBadge? mapped = name switch
                {
                    "broadcaster" => ChatBadge.Owner,
                    "moderator" => ChatBadge.Moderator,
                    "vip" => ChatBadge.Vip,
                    "subscriber" or "founder" => ChatBadge.Member,
                    "partner" => ChatBadge.Verified,
                    _ => null,
                };
                if (mapped is ChatBadge m && !badges.Contains(m)) badges.Add(m);
            }

        _onMessage(new ChatMessage
        {
            Id = tags.GetValueOrDefault("id") ?? Guid.NewGuid().ToString(),
            Platform = ChatPlatform.Twitch,
            Author = tags.GetValueOrDefault("display-name") is { Length: > 0 } dn ? dn : login,
            Color = tags.GetValueOrDefault("color") is { Length: > 0 } c ? c : null,
            Badges = badges,
            Parts = Parts(body, tags.GetValueOrDefault("emotes") ?? ""),
        });
        return false;
    }

    private static string Unescape(string v) =>
        v.Replace("\\s", " ").Replace("\\:", ";").Replace("\\\\", "\\");

    // Emote positions are in Unicode code points (not UTF-16 units).
    private static List<ChatPart> Parts(string text, string emotes)
    {
        var parts = new List<ChatPart>();
        var spans = new List<(int Start, int End, string Id)>();
        foreach (var e in emotes.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            int c = e.IndexOf(':');
            if (c < 0) continue;
            string id = e[..c];
            foreach (var range in e[(c + 1)..].Split(','))
            {
                var se = range.Split('-');
                if (se.Length == 2 && int.TryParse(se[0], out int s) && int.TryParse(se[1], out int en))
                    spans.Add((s, en, id));
            }
        }
        if (spans.Count == 0)
        {
            parts.Add(new ChatPart(text));
            return parts;
        }
        var cps = new List<string>();
        for (int i = 0; i < text.Length;)
        {
            int len = char.IsSurrogatePair(text, i) ? 2 : 1;
            cps.Add(text.Substring(i, len));
            i += len;
        }
        int pos = 0;
        foreach (var (start, end, id) in spans.OrderBy(s => s.Start))
        {
            if (start < pos || end >= cps.Count) continue;
            if (start > pos) parts.Add(new ChatPart(string.Concat(cps.GetRange(pos, start - pos))));
            string covered = string.Concat(cps.GetRange(start, end - start + 1));
            parts.Add(new ChatPart(covered, $"https://static-cdn.jtvnw.net/emoticons/v2/{id}/default/dark/2.0"));
            pos = end + 1;
        }
        if (pos < cps.Count) parts.Add(new ChatPart(string.Concat(cps.GetRange(pos, cps.Count - pos))));
        return parts;
    }
}
