using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using OmniCast.Engine;
using OmniCast.Services;

namespace OmniCast.Discord;

public sealed class CallMember
{
    public string Id { get; init; } = "";
    public string Name { get; set; } = "";
    public string AvatarUrl { get; set; } = "";
    public bool Speaking { get; set; }
    public bool Muted { get; set; }
}

// Who's in your Discord voice call and who's talking, from Discord's local
// RPC. Discord only shares voice events with an app the user registers
// (their own Client ID and Secret); they approve it once in Discord.
public sealed class DiscordCall
{
    public static DiscordCall Current { get; } = new();

    private const string SecretName = "discord/secret", TokenName = "discord/token";
    private readonly List<Session> _sessions = new();
    private Session? _active;
    private string? _channelId;
    private CancellationTokenSource? _cts;
    private DispatcherQueue? _ui;
    private bool _authorizing;
    private DispatcherQueueTimer? _retry;

    public string SelfId { get; private set; } = "";
    public string Status { get; private set; } = "Not connected";
    public string ChannelName { get; private set; } = "";
    public bool Connected => _sessions.Any(s => s.Authed);
    public bool InCall => _channelId != null;
    public List<CallMember> Members { get; } = new();

    public event Action? StatusChanged;
    public event Action? MembersChanged;
    public event Action<string, bool>? SpeakingChanged;

    private static DiscordSettings S => EngineHost.Current.Settings.Discord;
    public static bool HasSecret => Credentials.Read(SecretName) is { Length: > 0 };
    public static void SetSecret(string secret)
    {
        if (secret.Length > 0) Credentials.Write(SecretName, secret.Trim());
    }

    public void SignOut()
    {
        Credentials.Delete(TokenName);
        Disconnect();
    }

    private void SetStatus(string s)
    {
        Status = s;
        StatusChanged?.Invoke();
    }

    // ---------------------------------------------------------------- connect

    public void Resume()
    {
        if (S.AutoConnect && S.ClientId.Length > 0) Connect();
    }

    public void Connect()
    {
        _ui ??= DispatcherQueue.GetForCurrentThread();
        S.AutoConnect = true;
        EngineHost.Current.Settings.Save();
        _ = SafeConnectAsync();
    }

    public void Disconnect()
    {
        S.AutoConnect = false;
        EngineHost.Current.Settings.Save();
        _retry?.Stop();
        CloseAll();
        SetStatus("Not connected");
    }

    private void CloseAll()
    {
        _cts?.Cancel();
        foreach (var s in _sessions) s.Ipc.Dispose();
        _sessions.Clear();
        LeaveCall();
    }

    private async Task ConnectAsync()
    {
        CloseAll();
        _cts = new CancellationTokenSource();
        var ct = _cts.Token;
        if (S.ClientId.Length == 0) { SetStatus("Not set up"); return; }
        var pipes = DiscordIpc.Running();
        if (pipes.Length == 0) { SetStatus("Discord isn't running"); ScheduleRetry(); return; }
        SetStatus("Connecting…");
        foreach (int i in pipes)
        {
            var ipc = await DiscordIpc.ConnectAsync(i, ct);
            if (ipc == null) continue;
            var session = new Session(ipc);
            _sessions.Add(session);
            ipc.Message += m => _ui?.TryEnqueue(() => OnMessage(session, m));
            ipc.Closed += reason => _ui?.TryEnqueue(() => OnClosed(session, reason));
            ipc.StartReading(ct);
            await ipc.SendAsync(DiscordIpc.Op.Handshake, Json.Write(new Dictionary<string, object?> { ["v"] = 1, ["client_id"] = S.ClientId }));
        }
        if (_sessions.Count == 0) { SetStatus("Couldn't reach Discord"); ScheduleRetry(); }
    }

    private void ScheduleRetry()
    {
        if (!S.AutoConnect || _ui == null) return;
        _retry ??= _ui.CreateTimer();
        _retry.Interval = TimeSpan.FromSeconds(10);
        _retry.IsRepeating = false;
        _retry.Tick -= RetryTick;
        _retry.Tick += RetryTick;
        _retry.Start();
    }

    private void RetryTick(DispatcherQueueTimer t, object o) => _ = SafeConnectAsync();

    private async Task SafeConnectAsync()
    {
        try { await ConnectAsync(); }
        catch (Exception e) { SetStatus("Couldn't connect to Discord: " + e.Message); }
    }

    private void OnClosed(Session s, string reason)
    {
        if (!_sessions.Remove(s)) return;
        s.Ipc.Dispose();
        if (_active == s) LeaveCall();
        if (_sessions.Count > 0) return;
        if (reason.Contains("Invalid Client ID", StringComparison.OrdinalIgnoreCase))
        {
            SetStatus("Discord doesn't recognise the Client ID");
            return;
        }
        SetStatus("Lost the connection to Discord");
        ScheduleRetry();
    }

    // ---------------------------------------------------------------- messages

    private sealed class Session
    {
        public readonly DiscordIpc Ipc;
        public readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> Pending = new();
        public bool Authed;
        public Session(DiscordIpc ipc) => Ipc = ipc;
    }

    private static Task<JsonElement> Command(Session s, string cmd, Dictionary<string, object?>? args = null, string? evt = null)
    {
        string nonce = Guid.NewGuid().ToString();
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        s.Pending[nonce] = tcs;
        var payload = new Dictionary<string, object?> { ["cmd"] = cmd, ["args"] = args ?? new Dictionary<string, object?>(), ["nonce"] = nonce };
        if (evt != null) payload["evt"] = evt;
        _ = s.Ipc.SendAsync(DiscordIpc.Op.Frame, Json.Write(payload));
        _ = Task.Delay(TimeSpan.FromMinutes(2)).ContinueWith(_ => { if (s.Pending.TryRemove(nonce, out var t)) t.TrySetCanceled(); });
        return tcs.Task;
    }

    private static bool IsError(JsonElement reply, out int code, out string message)
    {
        code = 0;
        message = "";
        if (!reply.TryGetProperty("evt", out var e) || e.GetString() != "ERROR") return false;
        if (reply.TryGetProperty("data", out var d))
        {
            if (d.TryGetProperty("code", out var c) && c.TryGetInt32(out int ci)) code = ci;
            if (d.TryGetProperty("message", out var m)) message = m.GetString() ?? "";
        }
        return true;
    }

    private void OnMessage(Session s, JsonElement m)
    {
        if (m.TryGetProperty("nonce", out var n) && n.GetString() is string nonce && s.Pending.TryRemove(nonce, out var tcs))
        {
            tcs.TrySetResult(m);
            return;
        }
        string cmd = m.TryGetProperty("cmd", out var c) ? c.GetString() ?? "" : "";
        string evt = m.TryGetProperty("evt", out var e) ? e.GetString() ?? "" : "";
        var data = m.TryGetProperty("data", out var d) ? d : default;
        if (cmd != "DISPATCH") return;
        switch (evt)
        {
            case "READY":
                if (data.TryGetProperty("user", out var u) && u.TryGetProperty("id", out var id)) SelfId = id.GetString() ?? "";
                _ = AuthenticateAsync(s);
                break;
            case "VOICE_CHANNEL_SELECT":
                if (data.TryGetProperty("channel_id", out var ch) && ch.ValueKind == JsonValueKind.String)
                    _ = EnterChannelAsync(s, ch.GetString()!);
                else if (_active == s)
                    LeaveCall();
                break;
            case "VOICE_STATE_CREATE" or "VOICE_STATE_UPDATE" when _active == s:
                Upsert(data);
                MembersChanged?.Invoke();
                break;
            case "VOICE_STATE_DELETE" when _active == s:
                if (data.TryGetProperty("user", out var du) && du.TryGetProperty("id", out var did))
                {
                    Members.RemoveAll(x => x.Id == did.GetString());
                    MembersChanged?.Invoke();
                }
                break;
            case "SPEAKING_START" or "SPEAKING_STOP" when _active == s:
                if (data.TryGetProperty("user_id", out var sid) && sid.GetString() is string who)
                {
                    bool on = evt == "SPEAKING_START";
                    if (Members.FirstOrDefault(x => x.Id == who) is CallMember mem) mem.Speaking = on;
                    SpeakingChanged?.Invoke(who, on);
                }
                break;
        }
    }

    // ---------------------------------------------------------------- sign-in

    private sealed record Token(string Access, string Refresh, long Expires);

    private static Token? LoadToken()
    {
        try
        {
            using var doc = JsonDocument.Parse(Credentials.Read(TokenName) ?? "");
            var r = doc.RootElement;
            return new Token(r.GetProperty("access").GetString() ?? "", r.GetProperty("refresh").GetString() ?? "", r.GetProperty("expires").GetInt64());
        }
        catch (Exception) { return null; }
    }

    private static void SaveToken(Token t) =>
        Credentials.Write(TokenName, Json.Write(new Dictionary<string, object?> { ["access"] = t.Access, ["refresh"] = t.Refresh, ["expires"] = t.Expires }));

    private async Task AuthenticateAsync(Session s)
    {
        var token = LoadToken();
        if (token != null && token.Expires - DateTimeOffset.UtcNow.ToUnixTimeSeconds() < 60)
            token = await ExchangeAsync(new() { ["grant_type"] = "refresh_token", ["refresh_token"] = token.Refresh });
        if (token == null)
        {
            if (_authorizing) return; // another session is asking; it'll authenticate everyone
            _authorizing = true;
            SetStatus("Click Authorize in Discord");
            var reply = await Command(s, "AUTHORIZE", new() { ["client_id"] = S.ClientId, ["scopes"] = new[] { "rpc", "rpc.voice.read" } });
            _authorizing = false;
            if (IsError(reply, out int code, out string msg))
            {
                SetStatus(code == 5000 ? "Not approved in Discord" : $"Discord: {msg}");
                return;
            }
            string grant = reply.GetProperty("data").GetProperty("code").GetString() ?? "";
            token = await ExchangeAsync(new() { ["grant_type"] = "authorization_code", ["code"] = grant });
            if (token == null) return;
            foreach (var other in _sessions.Where(x => x != s && !x.Authed).ToList())
                _ = AuthenticateAsync(other);
        }
        var auth = await Command(s, "AUTHENTICATE", new() { ["access_token"] = token.Access });
        if (IsError(auth, out _, out _))
        {
            Credentials.Delete(TokenName);
            _ = AuthenticateAsync(s); // sign in again
            return;
        }
        s.Authed = true;
        if (!InCall) SetStatus("Connected, not in a call");
        await Command(s, "SUBSCRIBE", null, "VOICE_CHANNEL_SELECT");
        var sel = await Command(s, "GET_SELECTED_VOICE_CHANNEL");
        if (sel.TryGetProperty("data", out var ch) && ch.ValueKind == JsonValueKind.Object && ch.TryGetProperty("id", out var cid))
            EnterChannel(s, cid.GetString()!, ch);
    }

    private async Task<Token?> ExchangeAsync(Dictionary<string, string> form)
    {
        string? secret = Credentials.Read(SecretName);
        form["client_id"] = S.ClientId;
        form["client_secret"] = secret ?? "";
        form["redirect_uri"] = "http://localhost";
        try
        {
            using var res = await OmniCast.Chat.ChatHub.Http.PostAsync("https://discord.com/api/oauth2/token", new FormUrlEncodedContent(form));
            string body = await res.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(body);
            var r = doc.RootElement;
            if (!res.IsSuccessStatusCode || !r.TryGetProperty("access_token", out var at) || !r.TryGetProperty("refresh_token", out var rt))
            {
                string why = r.TryGetProperty("error_description", out var ed) ? ed.GetString() ?? "" : r.TryGetProperty("error", out var er) ? er.GetString() ?? "" : $"{(int)res.StatusCode}";
                SetStatus(why.Contains("client", StringComparison.OrdinalIgnoreCase) ? "Check the Client ID and Secret" : $"Discord: {why}");
                return null;
            }
            long expires = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + (r.TryGetProperty("expires_in", out var ei) ? ei.GetInt64() : 604800);
            var t = new Token(at.GetString() ?? "", rt.GetString() ?? "", expires);
            SaveToken(t);
            return t;
        }
        catch (Exception)
        {
            SetStatus("Couldn't reach discord.com to finish signing in");
            return null;
        }
    }

    // ---------------------------------------------------------------- the call

    private static readonly string[] VoiceEvents = { "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE", "SPEAKING_START", "SPEAKING_STOP" };

    private async Task EnterChannelAsync(Session s, string channelId)
    {
        var reply = await Command(s, "GET_CHANNEL", new() { ["channel_id"] = channelId });
        if (reply.TryGetProperty("data", out var ch) && ch.ValueKind == JsonValueKind.Object)
            EnterChannel(s, channelId, ch);
    }

    private void EnterChannel(Session s, string channelId, JsonElement channel)
    {
        if (_active != null && (_active != s || _channelId != channelId))
            LeaveCall();
        _active = s;
        _channelId = channelId;
        ChannelName = channel.TryGetProperty("name", out var n) && n.GetString() is { Length: > 0 } name ? name : "Voice call";
        foreach (var ev in VoiceEvents)
            _ = Command(s, "SUBSCRIBE", new() { ["channel_id"] = channelId }, ev);
        Members.Clear();
        if (channel.TryGetProperty("voice_states", out var vs))
            foreach (var v in vs.EnumerateArray()) Upsert(v);
        SetStatus($"Connected · {ChannelName}");
        MembersChanged?.Invoke();
    }

    private void LeaveCall()
    {
        if (_active != null && _channelId != null)
            foreach (var ev in VoiceEvents)
                _ = Command(_active, "UNSUBSCRIBE", new() { ["channel_id"] = _channelId }, ev);
        _active = null;
        _channelId = null;
        ChannelName = "";
        Members.Clear();
        if (Connected) SetStatus("Connected, not in a call");
        MembersChanged?.Invoke();
    }

    private void Upsert(JsonElement v)
    {
        if (!v.TryGetProperty("user", out var u) || !u.TryGetProperty("id", out var idEl)) return;
        string id = idEl.GetString() ?? "";
        string Str(JsonElement e, string k) => e.TryGetProperty(k, out var x) && x.ValueKind == JsonValueKind.String ? x.GetString() ?? "" : "";
        string name = Str(v, "nick") is { Length: > 0 } nick ? nick : Str(u, "global_name") is { Length: > 0 } g ? g : Str(u, "username") is { Length: > 0 } un ? un : "Someone";
        string hash = Str(u, "avatar");
        string avatar = hash.Length > 0
            ? $"https://cdn.discordapp.com/avatars/{id}/{hash}.png?size=256"
            : $"https://cdn.discordapp.com/embed/avatars/{(ulong.TryParse(id, out ulong n) ? (n >> 22) % 6 : 0)}.png";
        var state = v.TryGetProperty("voice_state", out var vsEl) ? vsEl : default;
        bool Flag(string k) => state.ValueKind == JsonValueKind.Object && state.TryGetProperty(k, out var f) && f.ValueKind == JsonValueKind.True;
        var m = Members.FirstOrDefault(x => x.Id == id);
        if (m == null) Members.Add(m = new CallMember { Id = id });
        m.Name = name;
        m.AvatarUrl = avatar;
        m.Muted = Flag("self_mute") || Flag("mute") || Flag("suppress");
    }
}

// Small JSON writer for RPC payloads (no reflection, so it survives trimming):
// strings, numbers, bools, null, string arrays and nested dictionaries.
internal static class Json
{
    public static string Write(Dictionary<string, object?> obj)
    {
        using var ms = new System.IO.MemoryStream();
        using (var w = new Utf8JsonWriter(ms)) Value(w, obj);
        return System.Text.Encoding.UTF8.GetString(ms.ToArray());
    }

    private static void Value(Utf8JsonWriter w, object? v)
    {
        switch (v)
        {
            case null: w.WriteNullValue(); break;
            case string s: w.WriteStringValue(s); break;
            case bool b: w.WriteBooleanValue(b); break;
            case int i: w.WriteNumberValue(i); break;
            case long l: w.WriteNumberValue(l); break;
            case double d: w.WriteNumberValue(d); break;
            case string[] arr:
                w.WriteStartArray();
                foreach (var a in arr) w.WriteStringValue(a);
                w.WriteEndArray();
                break;
            case Dictionary<string, object?> dict:
                w.WriteStartObject();
                foreach (var (k, val) in dict) { w.WritePropertyName(k); Value(w, val); }
                w.WriteEndObject();
                break;
            default: w.WriteStringValue(v.ToString()); break;
        }
    }
}
